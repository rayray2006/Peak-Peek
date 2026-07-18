import ARKit
import AVFoundation
import simd

/// Drift-free attitude for the camera (AR) modes.
///
/// ARKit world tracking runs visual-inertial odometry — camera features fused
/// with the IMU — so rotation stays pinned to the scene WHILE the phone moves,
/// which is exactly where the CoreMotion gyro+compass attitude drifted (it only
/// settled once the phone was still and the magnetometer caught up). ARKit owns
/// the camera, so this tracker also delivers the frames the AR modes display;
/// the old AVCapture pipeline stays in the Coordinator behind
/// `useARKitCameraTracking` for an easy revert.
///
/// Conventions: the app's world is ENU (x=east, y=north, z=up) and the render
/// basis is device-body axes mapped into it (see DeviceAttitude). ARKit's world
/// (with `.gravity` alignment) is y-up with an ARBITRARY horizontal heading, so
/// the yaw is anchored ONCE per session against CoreMotion's true-north
/// attitude (`referenceYaw`) the first time tracking reaches `.normal`; VIO
/// keeps it stable from then on. Until that moment `basis` stays nil and the
/// caller keeps using CoreMotion — the handoff is seamless because the yaw is
/// aligned to CoreMotion at the instant of the swap.
///
/// ⚠️ Axis signs (camera→device mapping, buffer orientation) cannot be
/// validated in the simulator — ARKit doesn't run there. Verify on a device
/// before trusting; do not flip signs to match theory (see DeviceAttitude).
final class ARAttitudeTracker: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    /// Device attitude in ENU, nil until the one-time yaw alignment lands.
    private(set) var basis: DeviceAttitude.Basis?

    /// Supplies CoreMotion's current true-north azimuth (radians, atan2(E, N))
    /// for the one-time alignment; return nil while unavailable.
    var referenceYaw: () -> Float? = { nil }
    /// Every ARKit frame's camera image (landscape sensor orientation, same as
    /// the AVCapture buffers) — display + photo capture. Main thread.
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    /// Camera geometry from ARKit intrinsics, once per session: (horizontal
    /// long-edge FOV in degrees, long px, short px). Feeds the AR projection.
    var onCameraInfo: (Float, Int, Int) -> Void = { _, _, _ in }

    private let session = ARSession()
    private var azOffset: Float?
    private var reportedInfo = false
    private var running = false
    /// run()/pause() happen here, not on main: the FIRST session.run pays
    /// ARKit's daemon + VIO + camera bring-up (hundreds of ms), which froze the
    /// UI for the whole 3D→AR switch. Serial, so a quick start→stop→start stays
    /// ordered; delegate callbacks remain on main (delegateQueue untouched).
    private let sessionQueue = DispatchQueue(label: "com.peakpeek.arsession")

    func start() {
        guard Self.isSupported, !running else { return }
        running = true
        azOffset = nil
        basis = nil
        reportedInfo = false
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity          // yaw anchored by US, not the compass
        config.planeDetection = []
        session.delegate = self                   // callbacks on main
        sessionQueue.async { [session] in
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func stop() {
        guard running else { return }
        running = false
        sessionQueue.async { [session] in session.pause() }
        basis = nil
        azOffset = nil
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        if !reportedInfo {
            // Horizontal FOV across the long (landscape) edge from the pinhole
            // intrinsics — the same figure the AVCapture path read from the
            // active format, but exact for the frames ARKit delivers.
            let fx = frame.camera.intrinsics[0][0]
            let w = Float(frame.camera.imageResolution.width)
            let h = Float(frame.camera.imageResolution.height)
            if fx > 1, w > 1 {
                onCameraInfo(2 * atan(w / (2 * fx)) * 180 / .pi, Int(w), Int(h))
                reportedInfo = true
            }
        }

        // Camera axes in ARKit world (columns), remapped to DEVICE body axes:
        // camera x runs along the device long axis toward the home button
        // (= −device-top), camera y is screen-up in landscape-right
        // (= +device-right), camera z = device z (toward the viewer).
        let m = frame.camera.transform
        let cx = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let cy = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let cz = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let devRight = cy, devTop = -cx, devToViewer = cz

        // ARKit world → pseudo-ENU (heading arbitrary): E₀=x, N₀=−z, U=y.
        func enu0(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, -v.z, v.y) }
        var right = enu0(devRight)
        var up = enu0(devTop)
        var forward = -enu0(devToViewer)

        if azOffset == nil {
            // One-time yaw anchor, only once VIO has settled and CoreMotion has
            // a heading: rotate ARKit's arbitrary heading onto true north.
            if case .normal = frame.camera.trackingState, let cmYaw = referenceYaw() {
                let v = abs(forward.z) < 0.95 ? forward : up   // yaw source at steep pitch
                let len = simd_length(SIMD2(v.x, v.y))
                if len > 1e-4 { azOffset = cmYaw - atan2(v.x, v.y) }
            }
        }
        if let d = azOffset {
            right = Self.rotateAz(right, d)
            up = Self.rotateAz(up, d)
            forward = Self.rotateAz(forward, d)
            basis = DeviceAttitude.Basis(forward: forward, right: right, up: up)
        }
        onFrame(frame.capturedImage)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Backgrounding interrupts the session and the VIO world can resume
        // ROTATED. Drop the yaw anchor: CoreMotion bridges (basis nil) until a
        // fresh anchor lands against the current compass heading.
        basis = nil
        azOffset = nil
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Drop back to CoreMotion (basis nil) rather than freezing on a stale
        // attitude; frames stop too, leaving the last displayed image.
        basis = nil
        azOffset = nil
        NSLog("ARKit session failed: %@", error.localizedDescription)
    }

    /// Adds `d` to the azimuth of `v` (ENU; azimuth = atan2(E, N), clockwise
    /// from north).
    private static func rotateAz(_ v: SIMD3<Float>, _ d: Float) -> SIMD3<Float> {
        let c = cos(d), s = sin(d)
        return SIMD3(v.x * c + v.y * s, v.y * c - v.x * s, v.z)
    }
}

/// Displays the ARKit camera frames (the AVCaptureVideoPreviewLayer can't — the
/// capture session is ARKit's). AVSampleBufferDisplayLayer converts the YCbCr
/// buffers in hardware; the container lays it out with the same counter-rotation
/// as the preview layer, plus the sensor's 90° (the buffers are landscape).
final class ARCameraDisplayLayer: AVSampleBufferDisplayLayer {
    private var formatDesc: CMVideoFormatDescription?

    func enqueue(pixelBuffer: CVPixelBuffer) {
        // Cache the format description across frames of the same dimensions.
        if formatDesc.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
            formatDesc = fd
        }
        guard let fd = formatDesc else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: fd,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        // Immediate display: we always show the newest frame, no timeline.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if status == .failed { flush() }
        enqueue(sample)
    }
}
