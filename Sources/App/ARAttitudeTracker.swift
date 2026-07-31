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

    // MARK: Yaw-anchor robustness
    //
    // The anchor used to be a SINGLE CoreMotion sample at the first `.normal`
    // frame, and was never revisited. Two real-world failures:
    // - Backgrounding drops the anchor; the re-anchor's one compass read can
    //   be degrees off (or mid-recalibration garbage) — the whole view (and
    //   the user's hand-tuned trim on top of it) lands rotated.
    // - Fast device rotation blurs the camera; VIO tracking goes `.limited`
    //   and can recover with its world yawed a few degrees. A fixed anchor
    //   makes that slip PERMANENT.
    // So: anchor only on a STABLE compass (≥1 s of samples agreeing within
    // 3°, circular mean), and afterwards run a watchdog — a sustained, firm
    // disagreement between the anchored yaw and a stable compass slews the
    // anchor closed at 2°/s. The user's drag calibration is applied by the
    // Coordinator ON TOP of this and measures the COMPASS's own error, so it
    // stays valid across every re-anchor and correction.

    /// Anchor-delta samples (compassYaw − vioYaw) while unanchored.
    private var anchorSamples: [(t: TimeInterval, d: Float)] = []
    /// Divergence samples (compassYaw − anchoredYaw) while anchored.
    private var divergenceSamples: [(t: TimeInterval, d: Float)] = []
    /// Watchdog hysteresis: currently slewing the anchor closed.
    private var slewing = false
    private var lastFrameTime: TimeInterval = 0

    /// Circular mean of angles (radians). Zero-safe: returns 0 for empty input.
    static func circularMean(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return 0 }
        var s: Float = 0, c: Float = 0
        for x in xs { s += sin(x); c += cos(x) }
        return atan2(s, c)
    }

    /// Largest absolute wrapped deviation from `mean` (radians).
    static func circularSpread(_ xs: [Float], about mean: Float) -> Float {
        xs.map { abs(Self.wrappedAngle($0 - mean)) }.max() ?? 0
    }

    /// Wrap to (−π, π].
    static func wrappedAngle(_ a: Float) -> Float {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x <= -.pi { x += 2 * .pi }
        return x
    }
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
        anchorSamples.removeAll()
        divergenceSamples.removeAll()
        slewing = false
        lastFrameTime = 0
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity          // yaw anchored by US, not the compass
        config.planeDetection = []
        // Blown-out skies at sunrise/sunset: ARKit's default video format is
        // SDR — auto-exposure holds for the (dark) terrain and the bright
        // background clips hard. Prefer an HDR-capable format (nearest in
        // resolution to the default, so tracking cost stays comparable) and
        // allow HDR delivery; intrinsics/FOV adapt automatically since we
        // read them per-session from the delivered frames.
        if !config.videoFormat.isVideoHDRSupported {
            let want = config.videoFormat.imageResolution.width
            if let hdr = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter({ $0.isVideoHDRSupported })
                .min(by: { abs($0.imageResolution.width - want)
                         < abs($1.imageResolution.width - want) }) {
                config.videoFormat = hdr
            }
        }
        config.videoHDRAllowed = config.videoFormat.isVideoHDRSupported
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

        let now = frame.timestamp
        let dt = lastFrameTime > 0 ? Float(min(0.25, now - lastFrameTime)) : 0
        lastFrameTime = now
        // VIO yaw in the un-anchored frame (yaw source flips to `up` at steep
        // pitch, same as the original one-shot anchor).
        let yawSource = abs(forward.z) < 0.95 ? forward : up
        let yawLen = simd_length(SIMD2(yawSource.x, yawSource.y))
        let vioYaw: Float? = yawLen > 1e-4 ? atan2(yawSource.x, yawSource.y) : nil

        if azOffset == nil {
            // Anchor on a STABLE compass: ≥1 s of (compass − VIO) deltas that
            // agree within 3°, anchored at their circular mean. The delta is
            // the buffered quantity (not the raw heading) so panning the phone
            // while the buffer fills doesn't smear it. Fallback: after 5 s of
            // steady disagreement (magnetic mess), take the mean anyway —
            // never strand the AR view on CoreMotion forever.
            if case .normal = frame.camera.trackingState,
               let cmYaw = referenceYaw(), let vioYaw {
                anchorSamples.append((now, Self.wrappedAngle(cmYaw - vioYaw)))
                anchorSamples.removeAll { now - $0.t > 1.5 }
                let ds = anchorSamples.map(\.d)
                let mean = Self.circularMean(ds)
                let span = now - (anchorSamples.first?.t ?? now)
                if span >= 1.0, Self.circularSpread(ds, about: mean) <= 3 * .pi / 180 {
                    azOffset = mean
                } else if span >= 5.0 {
                    azOffset = mean
                }
                if azOffset != nil {
                    anchorSamples.removeAll()
                    divergenceSamples.removeAll()
                    slewing = false
                }
            }
        } else if case .normal = frame.camera.trackingState,
                  let cmYaw = referenceYaw(), let vioYaw, let anchor = azOffset {
            // Watchdog: a STABLE compass firmly disagreeing with the anchored
            // yaw for ≥2 s means either VIO slipped (fast rotation) or the
            // anchor itself was bad — slew it closed at 2°/s (invisible, and
            // the drag trim on top stays valid). Hysteresis: keep slewing
            // until the residual is under 1.5°.
            let d = Self.wrappedAngle(cmYaw - (vioYaw + anchor))
            divergenceSamples.append((now, d))
            divergenceSamples.removeAll { now - $0.t > 2.5 }
            let ds = divergenceSamples.map(\.d)
            let mean = Self.circularMean(ds)
            let span = now - (divergenceSamples.first?.t ?? now)
            let stable = span >= 2.0 && Self.circularSpread(ds, about: mean) <= 3 * .pi / 180
            if stable, abs(mean) > 6 * .pi / 180 { slewing = true }
            if slewing {
                if abs(mean) < 1.5 * .pi / 180 { slewing = false }
                else if stable, dt > 0 {
                    let rate: Float = 2 * .pi / 180              // 2°/s
                    let step = max(-rate * dt, min(rate * dt, mean))
                    azOffset = anchor + step
                }
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
        // fresh STABLE anchor lands (see didUpdate) — the stability gate is
        // what makes reopen land on the same alignment the user left.
        basis = nil
        azOffset = nil
        anchorSamples.removeAll()
        divergenceSamples.removeAll()
        slewing = false
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Drop back to CoreMotion (basis nil) rather than freezing on a stale
        // attitude; frames stop too, leaving the last displayed image.
        basis = nil
        azOffset = nil
        anchorSamples.removeAll()
        divergenceSamples.removeAll()
        slewing = false
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
