import SwiftUI
import MetalKit
import simd
import CoreMotion
import CoreLocation
@preconcurrency import AVFoundation
import Photos

/// SwiftUI wrapper around an `MTKView` that renders the raymarched terrain and
/// lets the user look around by turning the phone (full device attitude, incl.
/// roll), pinch to zoom. On hardware without an IMU (simulator / macOS harness)
/// it falls back to touch-drag panning.
///
/// The viewpoint is fixed (PeakVisor-style): only the camera orientation/FOV
/// change — except when the `PanoramaViewModel` hands it a new `viewpoint`, which
/// refetches the DEM and re-bakes the surroundings. The eye stands at the EXACT
/// viewpoint coordinate (no summit snap) at ground + 1.6 m. Vertical exaggeration
/// feeds the renderer's `heightScale`. Load progress and the resolved eye
/// elevation are reported back to the model.
/// What the canvas shows: opaque 3D relief, AR relief over camera, or AR white
/// edges over camera passthrough.
enum TerrainViewMode: CaseIterable, Equatable {
    case threeD
    case arRelief
    case arEdges
    case arLabels

    var title: String {
        switch self {
        case .threeD: return "3D"
        case .arRelief: return "AR"
        case .arEdges: return "Edges"
        case .arLabels: return "Points"
        }
    }

    var systemImage: String {
        switch self {
        case .threeD: return "mountain.2"
        case .arRelief: return "camera.viewfinder"
        case .arEdges: return "scribble.variable"
        case .arLabels: return "mappin.and.ellipse"
        }
    }

    var next: TerrainViewMode {
        switch self {
        case .threeD: return .arRelief
        case .arRelief: return .arEdges
        case .arEdges: return .arLabels
        case .arLabels: return .threeD
        }
    }

    var usesCamera: Bool { self != .threeD }
}

struct TerrainMetalView: UIViewRepresentable {
    var viewpoint: PanoramaViewModel.Viewpoint?
    var exaggeration: Double = 1.0
    /// Date used to place the sun/moon/stars/Milky Way (scrubbed via Time controls).
    var displayDate: Date = Date()
    /// Display mode: 3D relief, AR relief, or AR edges.
    var mode: TerrainViewMode = .threeD
    /// Manual alignment: look around by dragging instead of moving the phone.
    var manualAlignment: Bool = false
    /// Peak/lake label density (Labels menu item: All / Sparse / Saved / None).
    var labelDensity: LabelDensity = .all
    /// Saved-list membership for the Saved density (green/orange label tints).
    var climbedPeakIDs: Set<String> = []
    var bookmarkedPeakIDs: Set<String> = []
    /// Named peaks to label (projected onto the rendered terrain).
    var peaks: [Peak] = []
    /// Named lakes/reservoirs to label (blue water labels at surface elevation).
    var lakes: [Peak] = []
    /// Currently selected peak (highlighted; also shown as an accent direction marker when
    /// off-view), and the tap callback (nil = a tap that hit no label).
    var selectedPeak: AnnotatedPeak?
    var onSelectPeak: (Peak?) -> Void = { _ in }
    /// Fired whenever label anchors are rebuilt: the ids of every feature with a
    /// clear line of sight from the current viewpoint (peaks + lakes). Anything
    /// absent is occluded by terrain, out of range, or behind the horizon.
    var onVisibleFeatures: (Set<String>) -> Void = { _ in }
    var onStatus: (PanoramaViewModel.Status) -> Void = { _ in }
    var onEyeElevation: (Double?) -> Void = { _ in }
    /// Live heading (degrees, 0 = N) and zoom factor (×), throttled, for the HUD.
    var onHeading: (Double) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    /// Fired when the view force-switches to manual (no IMU) so the HUD can match.
    var onForceManual: () -> Void = { }
    /// Incremented by the HUD's "Recenter" button to clear the AR drag calibration.
    var arRecenterToken: Int = 0
    /// Fired when an AR drag calibration becomes active / is cleared (drives the HUD).
    var onARAdjustedChanged: (Bool) -> Void = { _ in }
    /// Incremented by the HUD's shutter button to capture a photo of the view.
    var captureToken: Int = 0
    /// Fired when a capture finishes (true = saved) — drives the shutter flash.
    var onPhotoCaptured: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus, onEyeElevation: onEyeElevation,
                    onHeading: onHeading, onZoom: onZoom, onForceManual: onForceManual)
    }

    func makeUIView(context: Context) -> TerrainContainerView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = TerrainRenderer.colorFormat
        view.framebufferOnly = true
        view.isPaused = true                 // draw on demand (fixed viewpoint)
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        context.coordinator.configure(view: view)

        // Device orientation drives looking around; pinch zooms. Touch-drag is a
        // fallback only where there's no IMU (simulator / macOS).
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        // Pan is always available now (manual-alignment look-around); it only moves
        // the view when manual alignment is on, or as the no-IMU fallback.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let container = TerrainContainerView(metalView: view)
        container.previewLayer.session = context.coordinator.session
        context.coordinator.container = container
        return container
    }

    static func dismantleUIView(_ uiView: TerrainContainerView, coordinator: Coordinator) {
        coordinator.stopMotion()
        coordinator.stopCamera()
    }

    func updateUIView(_ uiView: TerrainContainerView, context: Context) {
        context.coordinator.onStatus = onStatus
        context.coordinator.onEyeElevation = onEyeElevation
        context.coordinator.onHeading = onHeading
        context.coordinator.onZoom = onZoom
        context.coordinator.onForceManual = onForceManual
        context.coordinator.onARAdjustedChanged = onARAdjustedChanged
        context.coordinator.setExaggeration(Float(exaggeration))
        context.coordinator.setDisplayDate(displayDate)
        context.coordinator.setManualAlignment(manualAlignment)
        context.coordinator.setMode(mode)
        context.coordinator.setARRecenterToken(arRecenterToken)
        context.coordinator.onPhotoCaptured = onPhotoCaptured
        context.coordinator.setCaptureToken(captureToken)
        context.coordinator.setPeaks(peaks)
        context.coordinator.setLakes(lakes)
        context.coordinator.setLabelDensity(labelDensity)
        context.coordinator.setSavedPeaks(climbed: climbedPeakIDs, bookmarked: bookmarkedPeakIDs)
        context.coordinator.onSelectPeak = onSelectPeak
        context.coordinator.onVisibleFeatures = onVisibleFeatures
        context.coordinator.setSelectedPeak(selectedPeak)
        if let vp = viewpoint {
            context.coordinator.requestViewpoint(lat: vp.latitude, lon: vp.longitude,
                                                 snapToSummit: vp.snapToSummit)
        }
    }

    /// Hosts the live-camera preview layer behind the terrain `MTKView`. In 3D mode
    /// the preview is hidden and the metal view is opaque; in AR mode the preview
    /// shows and the metal view goes transparent so terrain composites over it.
    final class TerrainContainerView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        /// ARKit-path camera display (the preview layer can't show ARKit's
        /// frames — ARKit owns the capture session). Same slot behind the metal
        /// view; only one of the two is ever unhidden.
        let arDisplayLayer = ARCameraDisplayLayer()
        let metalView: MTKView
        let skyArc = SkyArcOverlayView()
        let labelOverlay = PeakLabelOverlayView()
        let compassZoom = CompassZoomOverlayView()

        init(metalView: MTKView) {
            self.metalView = metalView
            super.init(frame: .zero)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.isHidden = true
            layer.addSublayer(previewLayer)
            arDisplayLayer.videoGravity = .resizeAspectFill
            arDisplayLayer.isHidden = true
            layer.addSublayer(arDisplayLayer)
            addSubview(metalView)
            addSubview(skyArc)               // sky under the labels
            addSubview(labelOverlay)         // labels on top of the terrain
            addSubview(compassZoom)          // compass + zoom on top
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        /// Counter-rotation that pins the RENDER SUBVIEWS (metal, sky, labels,
        /// camera preview) to the device-portrait frame the attitude mapping was
        /// verified in, while the window rotates natively around them. Done HERE,
        /// in the same layout transaction as the system rotation (interface
        /// orientation read straight off the window scene) — driving it from
        /// SwiftUI state lagged the transition and made the terrain visibly swing.
        /// The compass is NOT counter-rotated: it follows the window like the rest
        /// of the chrome.
        override func layoutSubviews() {
            super.layoutSubviews()
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let counterAngle: CGFloat
            switch orientation {
            case .landscapeLeft: counterAngle = .pi / 2
            case .landscapeRight: counterAngle = -.pi / 2
            case .portraitUpsideDown: counterAngle = .pi
            default: counterAngle = 0
            }
            let landscape = orientation.isLandscape
            // Device-portrait-shaped bounds for the render stack.
            let devBounds = landscape
                ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
                : CGRect(origin: .zero, size: bounds.size)
            let mid = CGPoint(x: bounds.midX, y: bounds.midY)
            for v in [metalView, skyArc, labelOverlay] {
                v.transform = .identity
                v.bounds = devBounds
                v.center = mid
                v.transform = CGAffineTransform(rotationAngle: counterAngle)
            }
            previewLayer.setAffineTransform(.identity)
            previewLayer.bounds = devBounds
            previewLayer.position = mid
            previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: counterAngle))
            // ARKit buffers are LANDSCAPE (no connection to rotate them), so the
            // display layer gets landscape bounds and an extra 90° on top of the
            // counter-rotation; aspect-fill then covers the portrait rect.
            arDisplayLayer.setAffineTransform(.identity)
            arDisplayLayer.bounds = CGRect(x: 0, y: 0,
                                           width: devBounds.height, height: devBounds.width)
            arDisplayLayer.position = mid
            arDisplayLayer.setAffineTransform(CGAffineTransform(rotationAngle: counterAngle + .pi / 2))
            compassZoom.transform = .identity
            compassZoom.frame = bounds                 // window-following chrome
            if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90    // lock preview to portrait
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, CLLocationManagerDelegate {
        private var renderer: TerrainRenderer?
        private var demTexture: MTLTexture?
        private var dem: DEMTile?
        /// Coarse, wide-coverage far tile (≈120 km). Renders + labels distant ranges
        /// the high-res near tile (≈40 km, native ~30 m) doesn't reach.
        private var demFarTexture: MTLTexture?
        private var demFar: DEMTile?

        /// Near (high-res) and far (coarse) DEM fetch radii + grid caps.
        private static let nearRadius = 40_000.0, farRadius = 120_000.0
        private static let nearMaxGrid = 9000, farMaxGrid = 4096
        private weak var view: MTKView?
        var onStatus: (PanoramaViewModel.Status) -> Void
        var onEyeElevation: (Double?) -> Void
        var onHeading: (Double) -> Void = { _ in }
        var onZoom: (Double) -> Void = { _ in }
        var onForceManual: () -> Void = { }

        // Camera state.
        private var camElev: Float = 2700
        private var groundElev: Float = 0
        private var refLat = 48.50
        private var refLon = -121.08

        // Sky: the instant the sun/moon/stars are placed at, and the terrain skyline
        // profile cached from the last viewpoint (time-independent, so scrubbing time
        // re-lights the sky without recomputing the expensive horizon).
        private var displayDate = Date()
        private var cachedHorizon: [Float]?
        /// Real sun direction (ENU) at `displayDate`, for the dynamic sky colour.
        private var skySunENU = SIMD3<Float>(0, 0, 1)
        private var azimuth: Float = 215
        private var pitch: Float = -3
        private var fov: Float = 60
        private var exaggeration: Float = 1

        // Gesture bookkeeping.
        private var panStartAz: Float = 0
        private var panStartPitch: Float = 0
        private var pinchStartFov: Float = 60

        // Device-motion look-around. `deviceBasis` is the smoothed camera basis
        // from the latest attitude sample; nil until the first sample arrives (or
        // forever, on hardware without an IMU — then we fall back to az/pitch).
        private let motionManager = CMMotionManager()
        /// A dedicated, LOW-POWER location feed used ONLY so CoreMotion's
        /// `.xTrueNorthZVertical` reference frame can compute magnetic declination —
        /// true-north attitude requires an active location, and the viewpoint's own GPS
        /// stops in manual/teleported modes. Without this the compass silently degrades
        /// to MAGNETIC north (off by the local declination — why it disagreed with maps).
        /// Kilometre accuracy is plenty: declination varies over ~degrees of latitude.
        private let headingLocation = CLLocationManager()
        /// Motion is delivered OFF the main thread so a busy render never delays a
        /// sample; the render loop pulls the freshest attitude itself (see `draw`).
        private let motionQueue: OperationQueue = {
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 1
            q.qualityOfService = .userInteractive
            return q
        }()
        private var deviceBasis: DeviceAttitude.Basis?
        /// True once motion updates are running in the `.xTrueNorthZVertical` frame.
        /// At cold start there's no location fix, so true-north referencing is
        /// unavailable and CoreMotion SILENTLY delivers magnetic-north attitude (no
        /// error) — matching the Compass app but off from real maps by the local
        /// declination. We start on the best available frame and upgrade to true north
        /// in `didUpdateLocations`, once a fix lets CoreMotion know the declination.
        private var motionUsesTrueNorth = false
        private var smoothedOrientation: simd_quatf?
        /// Timestamp of the last attitude pulled in `draw`, for framerate-independent
        /// smoothing (the slerp factor is derived from the real frame dt).
        private var lastMotionSampleTime: CFTimeInterval = 0
        var motionAvailable: Bool { motionManager.isDeviceMotionAvailable }
        /// True when the live device attitude (not gestures) should drive the camera:
        /// any AR mode, or 3D with device look-around on. Drives continuous rendering.
        private var motionDrivesCamera: Bool {
            motionAvailable && (mode.usesCamera || !manualAlignment)
        }

        // Display mode + AR camera.
        let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.example.PeakPeek.ar.session")
        /// Detects the first delivered camera frame so the AR reveal waits until the
        /// preview is actually streaming (no black gap). See `setMode`/`revealCamera`.
        private let videoOutput = AVCaptureVideoDataOutput()
        private let videoOutQueue = DispatchQueue(label: "com.example.PeakPeek.ar.frames")
        /// True between "entered an AR mode from 3D" and "first camera frame arrived";
        /// while true the metal view stays opaque + renders 3D so nothing flashes black.
        private var awaitingFirstFrame = false
        /// True once the camera preview is revealed (metal view made transparent).
        private var cameraRevealed = false
        /// Real back-camera intrinsics, captured when the session configures, so the
        /// AR overlay is projected at the SAME field of view the camera sees — without
        /// this the overlay scale differs from the world and labels slide as you tilt.
        /// `cameraLongFOVDeg` = `videoFieldOfView` (horizontal angle across the long /
        /// landscape edge); `cameraFormatLong/Short` = the format's pixel dimensions.
        private var cameraLongFOVDeg: Float = 0
        private var cameraFormatLong: Int = 0
        private var cameraFormatShort: Int = 0

        /// Compile-time switch: ARKit VIO drives attitude + camera frames in the
        /// AR modes (drift-free rotation while moving). Flip to false to restore
        /// the AVCapture + CoreMotion path unchanged — everything below keeps
        /// both wired.
        static let useARKitCameraTracking = true
        private var usesARKitCamera: Bool {
            Self.useARKitCameraTracking && ARAttitudeTracker.isSupported
        }
        private lazy var arTracker: ARAttitudeTracker = {
            let t = ARAttitudeTracker()
            t.referenceYaw = { [weak self] in
                // CoreMotion's true-north azimuth, for the one-time yaw anchor.
                guard let m = self?.motionManager.deviceMotion?.attitude.rotationMatrix
                else { return nil }
                let b = DeviceAttitude.cameraBasis(
                    m11: m.m11, m12: m.m12, m13: m.m13,
                    m21: m.m21, m22: m.m22, m23: m.m23,
                    m31: m.m31, m32: m.m32, m33: m.m33)
                let v = abs(b.forward.z) < 0.95 ? b.forward : b.up
                let len = simd_length(SIMD2(v.x, v.y))
                guard len > 1e-4 else { return nil }
                return atan2(v.x, v.y)
            }
            t.onFrame = { [weak self] pb in
                guard let self else { return }
                self.pixelBufferLock.lock()
                self.latestPixelBuffer = pb        // photo capture, same as AVCapture
                self.pixelBufferLock.unlock()
                self.container?.arDisplayLayer.enqueue(pixelBuffer: pb)
                if self.awaitingFirstFrame { self.revealCamera() }
            }
            t.onCameraInfo = { [weak self] fovDeg, long, short in
                self?.cameraLongFOVDeg = fovDeg
                self?.cameraFormatLong = long
                self?.cameraFormatShort = short
            }
            return t
        }()

        weak var container: TerrainContainerView?
        private var mode: TerrainViewMode = .threeD
        private var manualAlignment = false
        private var didForceManual = false

        // AR manual adjustment: a YAW-ONLY calibration offset (degrees) the user
        // drags onto the live device tracking to pin the overlay onto the real
        // mountains when the compass heading is slightly off. Yaw is the only axis
        // that needs it: heading comes from the (weak) magnetometer, while pitch is
        // gravity-anchored to <1° — and a second drag axis made converging on a
        // horizontal alignment harder. Persists across viewpoints; cleared by
        // `recenterAR()`.
        private var arYawOffsetDeg: Double = 0
        private var arRecenterToken = 0
        /// Reports whether a non-zero AR adjustment is currently applied (drives the
        /// "Recenter" button + orange menu icon).
        var onARAdjustedChanged: (Bool) -> Void = { _ in }
        private var lastReportedARAdjusted = false

        // Peak labels.
        private var peaks: [Peak] = []
        private var lakes: [Peak] = []
        private var labelGeneration = 0
        var onSelectPeak: (Peak?) -> Void = { _ in }
        var onVisibleFeatures: (Set<String>) -> Void = { _ in }
        private var selectedPeakID: String?

        // HUD reporting throttle (heading/zoom).
        private var lastHeadingReport: CFTimeInterval = 0
        private var lastHeading: Double = .nan
        private var lastZoom: Double = .nan

        // Viewpoint bookkeeping.
        private var lastRequested: (lat: Double, lon: Double)?
        /// Set by "Stand here": once the DEM is in, move the eye to the true summit.
        private var pendingSummitSnap = false
        private var isReloading = false
        /// The latest viewpoint requested while a reload was in flight; run when
        /// the current bake settles instead of being silently dropped.
        private var queuedRequest: (lat: Double, lon: Double, snap: Bool)?

        /// Every reload exit path funnels here so a queued mid-bake move is
        /// never lost (main thread only, like all reload state).
        private func finishReload() {
            isReloading = false
            if let q = queuedRequest {
                queuedRequest = nil
                requestViewpoint(lat: q.lat, lon: q.lon, snapToSummit: q.snap)
            }
        }
        /// DEM-tile download progress for the "Loading tiles X of Y" readout. Touched
        /// only on the main thread (reset before the fetch, incremented from the
        /// per-tile callback), so no locking is needed.
        /// Unified load-progress units for the "Loading terrain · N%" readout: each
        /// degree tile is one unit per phase (download, then decode/stitch), so the
        /// percentage tracks the whole assembly, not just the network. Main-thread
        /// only (reset before the fetch, ticked from the per-tile callbacks).
        private var loadUnitsDone = 0
        private var loadUnitsTotal = 0
        /// Download + stitch span 0…loadShare of the readout; the bake then
        /// sweeps loadShare…0.95 on its per-band completions (see
        /// `bakeProgressive`), holds at 0.95 while the labels land, and `.ready`
        /// closes it out.
        private static let loadShare = 0.85
        /// Bumped per bake request; a completing bake whose token is stale (a newer
        /// viewpoint/exaggeration was requested) is discarded instead of installed.
        private var bakeGeneration = 0
        /// A panorama has been installed at least once (re-bakes keep showing it).
        private var panoInstalled = false
        /// A re-bake of an already-visible scene is in flight: the old panorama
        /// (and its matching labels) stay up until the new full-res image lands.
        private var rebakePending = false
        /// Atomic scene swap for re-bakes: the new panorama and its label anchors
        /// are computed CONCURRENTLY and install TOGETHER in one main-thread turn
        /// (whichever finishes first waits for the other) — old labels can never
        /// linger over the new terrain, nor new labels float over the old.
        private var pendingPanoTex: MTLTexture?
        private var pendingAnchors: ([PeakLabelOverlayView.Anchor], Set<String>)?
        private var pendingOnReady: (() -> Void)?

        private func maybeCompleteSwap() {
            guard let tex = pendingPanoTex,
                  let (anchors, visibleIDs) = pendingAnchors,
                  let renderer else { return }
            pendingPanoTex = nil
            pendingAnchors = nil
            rebakePending = false
            renderer.installPanorama(tex)
            container?.labelOverlay.anchors = anchors
            onVisibleFeatures(visibleIDs)
            view?.setNeedsDisplay()
            pendingOnReady?()
            pendingOnReady = nil
        }
        private var bundledTileCache: DEMTile?

        init(onStatus: @escaping (PanoramaViewModel.Status) -> Void,
             onEyeElevation: @escaping (Double?) -> Void,
             onHeading: @escaping (Double) -> Void,
             onZoom: @escaping (Double) -> Void,
             onForceManual: @escaping () -> Void) {
            self.onStatus = onStatus
            self.onEyeElevation = onEyeElevation
            self.onHeading = onHeading
            self.onZoom = onZoom
            self.onForceManual = onForceManual
            super.init()
            // A bake whose GPU work was aborted (app backgrounded mid-bake) is
            // retried the moment the app is active again — otherwise the view
            // stayed a blue sky-only screen until the next manual teleport.
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Set when a bake failed (aborted command buffer); cleared by the retry.
        private var needsRebakeOnActivate = false

        @objc private func appDidBecomeActive() {
            guard needsRebakeOnActivate else { return }
            needsRebakeOnActivate = false
            guard dem != nil else { return }
            bakeProgressive(progressFrom: 0) { [weak self] in
                guard let self else { return }
                self.report(.ready)
                self.finishReload()
            }
        }

        // Panorama bake resolutions. The quick pass paints a usable image almost
        // immediately; the full pass swaps in the crisp version moments later.
        private static let quickPanoramaWidth = 2048
        /// Higher = more visible DEM detail when zoomed (the bake, not the DEM, was
        /// the limiter at 8192 ≈ 22.7 px/°). 12288 ≈ 34 px/° (~200 MB textures) on
        /// roomy devices; small-RAM devices stay on the proven 8192.
        ///
        /// MUST clamp to the platform's Metal max 2D texture size: real iOS GPUs allow
        /// 16384, but the **Simulator caps at 8192** (a >8192 descriptor fails
        /// validation and crashes). So the hi-res bake only runs on hardware — it
        /// can't be exercised in the Simulator.
        private static let fullPanoramaWidth: Int = {
            #if targetEnvironment(simulator)
            let maxTexture = 8192
            #else
            let maxTexture = 16384
            #endif
            let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let desired = gb >= 5.5 ? 12288 : 8192
            return min(desired, maxTexture)
        }()

        func configure(view: MTKView) {
            self.view = view
            guard let device = view.device else { return }
            do {
                renderer = try TerrainRenderer(device: device)
            } catch {
                NSLog("TerrainRenderer init failed: \(error)")
                report(.failed("Renderer unavailable on this device."))
                return
            }
            // Debug: aim the manual-mode view (sim has no IMU) for deterministic
            // screenshots, e.g. `-az 154 -pitch 6`.
            let args = ProcessInfo.processInfo.arguments
            // Debug: pretend the camera delivered (sim has none) so the AR passes
            // (edges/relief) render over black — for overlay-density screenshots.
            if args.contains("-revealCamera") { cameraRevealed = true }
            if let i = args.firstIndex(of: "-az"), i + 1 < args.count, let a = Float(args[i + 1]) { azimuth = a }
            if let i = args.firstIndex(of: "-pitch"), i + 1 < args.count, let p = Float(args[i + 1]) { pitch = p }
            if let i = args.firstIndex(of: "-fov"), i + 1 < args.count, let f = Float(args[i + 1]) { fov = f }
            startMotion()
            syncRenderLoop()
            // No auto-load: the view model drives the first viewpoint (GPS/demo)
            // via updateUIView → requestViewpoint.
        }

        // MARK: Device motion

        /// Stream device attitude and drive the camera from it. Prefers true-north
        /// referencing so the heading lines up with the panorama's real azimuths,
        /// falling back to magnetic north if true north is unavailable.
        private func startMotion() {
            guard motionManager.isDeviceMotionAvailable else { return }
            // Keep a coarse location alive so CoreMotion can reference TRUE north (it
            // needs a fix to know declination); without it the attitude yaw is magnetic.
            // Debug: -noLocationPrompt skips the request so simulator screenshot runs
            // aren't blocked by the permission dialog (no IMU there anyway).
            guard !ProcessInfo.processInfo.arguments.contains("-noLocationPrompt") else { return }
            headingLocation.delegate = self
            headingLocation.desiredAccuracy = kCLLocationAccuracyKilometer
            headingLocation.requestWhenInUseAuthorization()
            headingLocation.startUpdatingLocation()
            // Sample as fast as the device allows; the render loop pulls the latest at
            // draw time, so a high sensor rate just means a fresher pull every frame.
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            // Start on the best frame available RIGHT NOW so look-around is live
            // immediately. True north needs a location fix (for declination), which
            // usually isn't ready at launch — `didUpdateLocations` upgrades us once it
            // is. Starting `.xTrueNorthZVertical` here would silently run as magnetic.
            let available = CMMotionManager.availableAttitudeReferenceFrames()
            let initial: CMAttitudeReferenceFrame =
                available.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical
                : available.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical
                : .xArbitraryZVertical
            beginMotionUpdates(frame: initial)
        }

        /// Start streaming on a BACKGROUND queue. The handler does no per-frame work —
        /// it only falls back to magnetic north if true north is unavailable. The
        /// framework keeps `motionManager.deviceMotion` current; `draw` reads it.
        private func beginMotionUpdates(frame: CMAttitudeReferenceFrame) {
            if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
            motionUsesTrueNorth = (frame == .xTrueNorthZVertical)
            motionManager.startDeviceMotionUpdates(using: frame, to: motionQueue) { [weak self] _, error in
                guard let self, error != nil, frame == .xTrueNorthZVertical else { return }
                DispatchQueue.main.async { self.beginMotionUpdates(frame: .xMagneticNorthZVertical) }
            }
        }

        /// Pull the FRESHEST attitude and convert it to the camera basis, right before
        /// the frame that uses it — so rendering latency never makes the view trail the
        /// phone. A framerate-independent low-pass (time constant `tau`) absorbs sensor
        /// micro-jitter without lagging: the slerp factor scales with the real frame dt,
        /// so it behaves the same at 60 or 120 Hz and converges in ~2–3 frames.
        private func sampleDeviceBasis() {
            // Camera modes on the ARKit path use the VIO attitude once its yaw
            // anchor has landed (drift-free while moving); before that — and in
            // 3D mode, and on the AVCapture path — CoreMotion as ever. The two
            // agree in yaw at the moment of handoff (see ARAttitudeTracker), so
            // the swap is invisible and the slerp below smooths any residue.
            let basis: DeviceAttitude.Basis
            if mode.usesCamera, usesARKitCamera, let arBasis = arTracker.basis {
                basis = arBasis
            } else {
                guard let m = motionManager.deviceMotion?.attitude.rotationMatrix else { return }
                basis = DeviceAttitude.cameraBasis(
                    m11: m.m11, m12: m.m12, m13: m.m13,
                    m21: m.m21, m22: m.m22, m23: m.m23,
                    m31: m.m31, m32: m.m32, m33: m.m33)
            }

            // Build a proper (det +1) rotation for slerp: columns (right, up,
            // -forward) are right-handed; forward = -col2 afterwards.
            let rot = simd_float3x3(basis.right, basis.up, -basis.forward)
            var target = simd_quatf(rot)
            let now = CACurrentMediaTime()
            if let current = smoothedOrientation, lastMotionSampleTime > 0 {
                if simd_dot(current.vector, target.vector) < 0 {
                    target = simd_quatf(vector: -target.vector)   // shortest path
                }
                let dt = Float(min(0.1, max(0.0001, now - lastMotionSampleTime)))
                let tau: Float = 0.02                              // ~20 ms — snappy, jitter-free
                let alpha = 1 - exp(-dt / tau)
                target = simd_normalize(simd_slerp(current, target, alpha))
            }
            lastMotionSampleTime = now
            smoothedOrientation = target

            let r = simd_float3x3(target)
            deviceBasis = DeviceAttitude.Basis(
                forward: -r.columns.2, right: r.columns.0, up: r.columns.1)
        }

        /// Continuous rendering while the device attitude drives the camera (so `draw`
        /// pulls a fresh sample every vsync); on-demand otherwise to save power.
        func syncRenderLoop() {
            guard let v = view else { return }
            let live = motionDrivesCamera
            v.isPaused = !live
            v.enableSetNeedsDisplay = !live
            if live { v.setNeedsDisplay() }                       // kick the first frame
        }

        func stopMotion() {
            motionManager.stopDeviceMotionUpdates()
        }

        /// Location is used ONLY to give CoreMotion a declination fix for true north; we
        /// don't consume the coordinates here (the viewpoint's own GPS lives in the model).
        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
            default: break
            }
        }

        /// A real fix means CoreMotion now knows the local magnetic declination, so the
        /// `.xTrueNorthZVertical` frame becomes available. Upgrade to it ONCE — until we
        /// do, attitude yaw is magnetic north (matches the Compass app but off from maps
        /// by the declination). Once running on true north CoreMotion keeps declination
        /// current from ongoing fixes, so this only has to fire on the first fix.
        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard !motionUsesTrueNorth,
                  motionManager.isDeviceMotionAvailable,
                  CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
            else { return }
            beginMotionUpdates(frame: .xTrueNorthZVertical)
        }

        // MARK: AR camera

        /// Switch display mode (3D / AR relief / AR edges / AR points). Camera turns
        /// on for the AR modes; the metal view goes non-opaque so terrain (or just the
        /// label overlay) composites over the preview. The bake + look-around are
        /// identical across modes.
        ///
        /// Smooth 3D→AR (no black flash): entering an AR mode from 3D keeps the metal
        /// view OPAQUE and rendering the 3D scene until the camera delivers its first
        /// frame; only then (`revealCamera`) is the view made transparent. Without
        /// this, the view turns transparent immediately while the camera is still
        /// warming up, so the sky briefly shows black.
        func setMode(_ newMode: TerrainViewMode) {
            guard newMode != mode else { return }
            let wasCamera = mode.usesCamera
            mode = newMode
            defer { syncRenderLoop() }             // mode change can flip motion-driven
            let usesCamera = newMode.usesCamera
            // Sun/moon arcs only belong to the terrain views; "Points" is camera + peaks.
            container?.skyArc.isHidden = (newMode == .arLabels)

            if usesCamera {
                // ARKit path shows its own display layer; AVCapture the preview.
                (usesARKitCamera ? container?.arDisplayLayer : container?.previewLayer)?
                    .isHidden = false             // sits behind the metal view
                if wasCamera {
                    // AR↔AR: camera already streaming + view already transparent.
                    view?.setNeedsDisplay()
                } else {
                    // 3D→AR: hold the opaque 3D view until the first frame lands.
                    awaitingFirstFrame = true
                    cameraRevealed = false
                    setMetalOpaque(true)
                    if usesARKitCamera { arTracker.start() } else { startCamera() }
                    // Safety net: reveal even if no frame callback arrives (camera
                    // permission denied, etc.) so AR is never stuck on the 3D view.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.awaitingFirstFrame, self.mode.usesCamera else { return }
                        self.revealCamera()
                    }
                }
            } else {
                // AR→3D: opaque immediately (renders the sky — no gap), drop the camera.
                awaitingFirstFrame = false
                cameraRevealed = false
                container?.previewLayer.isHidden = true
                container?.arDisplayLayer.isHidden = true
                setMetalOpaque(true)
                if wasCamera {
                    if usesARKitCamera { arTracker.stop() } else { stopCamera() }
                }
                view?.setNeedsDisplay()
            }
        }

        /// Make the metal view opaque (3D, black backstop) or transparent (AR, camera
        /// shows through).
        private func setMetalOpaque(_ opaque: Bool) {
            guard let v = view else { return }
            v.isOpaque = opaque
            v.backgroundColor = opaque ? .black : .clear
            (v.layer as? CAMetalLayer)?.isOpaque = opaque
        }

        /// Called once the camera is delivering frames: flip the metal view transparent
        /// so the (already-streaming) preview shows. Smooth — no black gap.
        private func revealCamera() {
            guard mode.usesCamera, !cameraRevealed else { return }
            cameraRevealed = true
            awaitingFirstFrame = false
            setMetalOpaque(false)
            view?.setNeedsDisplay()
        }

        // Every camera frame: retain the newest pixel buffer (photo capture composites
        // it); the first frame also reveals the preview.
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                pixelBufferLock.lock()
                latestPixelBuffer = pb
                pixelBufferLock.unlock()
            }
            guard awaitingFirstFrame else { return }
            DispatchQueue.main.async { [weak self] in self?.revealCamera() }
        }

        // MARK: Photo capture

        /// Newest camera frame, retained for photo capture (written on the video
        /// queue, read on main at capture time).
        private var latestPixelBuffer: CVPixelBuffer?
        private let pixelBufferLock = NSLock()
        private static let ciContext = CIContext()
        /// Reports capture success (drives the HUD shutter flash).
        var onPhotoCaptured: (Bool) -> Void = { _ in }
        private var captureRequestToken = 0

        /// RootScreen bumps a token to request a capture (one-way action input,
        /// same pattern as the AR recenter button).
        func setCaptureToken(_ token: Int) {
            guard token != captureRequestToken else { return }
            captureRequestToken = token
            capturePhoto()
        }

        /// Capture what the user currently sees and save it to the photo library:
        /// the metal render (opaque terrain in 3D; transparent relief/edges in AR)
        /// composited over the live camera frame (AR modes), with the sky + label
        /// overlays drawn on top. The metal pass is RE-RENDERED offscreen with the
        /// same uniforms `draw` would build — presented drawables can't be read back.
        private func capturePhoto() {
            guard let v = view, let renderer, let container else { onPhotoCaptured(false); return }
            let w = Int(v.drawableSize.width), h = Int(v.drawableSize.height)
            guard w > 0, h > 0 else { onPhotoCaptured(false); return }

            var uniforms = makeUniforms(width: w, height: h)
            if let basis = deviceBasis, mode.usesCamera || !manualAlignment {
                let b = mode.usesCamera ? arCalibrated(basis) : basis
                uniforms.forward = SIMD4<Float>(b.forward, 0)
                uniforms.right = SIMD4<Float>(b.right, 0)
                uniforms.up = SIMD4<Float>(b.up, 0)
            }
            let effectiveMode: TerrainViewMode =
                (mode.usesCamera && !cameraRevealed) ? .threeD : mode

            // Offscreen metal pass → CGImage (readable .shared texture).
            var metalCG: CGImage?
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: TerrainRenderer.colorFormat, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            if let tex = renderer.device.makeTexture(descriptor: desc),
               let cb = renderer.commandQueue.makeCommandBuffer() {
                switch effectiveMode {
                case .threeD: renderer.encodeView(uniforms: uniforms, into: tex, commandBuffer: cb)
                case .arRelief: renderer.encodeViewAR(uniforms: uniforms, into: tex, commandBuffer: cb)
                case .arEdges: renderer.encodeViewEdges(uniforms: uniforms, into: tex, commandBuffer: cb)
                case .arLabels: renderer.encodeClearTransparent(into: tex, commandBuffer: cb)
                }
                cb.commit()
                cb.waitUntilCompleted()
                var bytes = [UInt8](repeating: 0, count: w * h * 4)
                tex.getBytes(&bytes, bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                metalCG = CGDataProvider(data: Data(bytes) as CFData).flatMap {
                    CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: $0, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)
                }
            }

            // Camera frame (AR modes): newest buffer, rotated to portrait.
            var cameraCG: CGImage?
            if effectiveMode.usesCamera, cameraRevealed {
                pixelBufferLock.lock()
                let pb = latestPixelBuffer
                pixelBufferLock.unlock()
                if let pb {
                    let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
                    cameraCG = Self.ciContext.createCGImage(ci, from: ci.extent)
                }
            }

            // Composite at drawable resolution: camera → metal → overlays.
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = true
            let size = CGSize(width: w, height: h)
            let image = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                let rect = CGRect(origin: .zero, size: size)
                UIColor.black.setFill()
                ctx.fill(rect)
                if let cameraCG {                              // aspect-fill, like the preview layer
                    let cw = CGFloat(cameraCG.width), ch = CGFloat(cameraCG.height)
                    let s = max(rect.width / cw, rect.height / ch)
                    UIImage(cgImage: cameraCG).draw(in: CGRect(
                        x: (rect.width - cw * s) / 2, y: (rect.height - ch * s) / 2,
                        width: cw * s, height: ch * s))
                }
                if let metalCG { UIImage(cgImage: metalCG).draw(in: rect) }
                let cg = ctx.cgContext                          // overlays are in points → scale up
                cg.saveGState()
                cg.scaleBy(x: size.width / max(1, container.labelOverlay.bounds.width),
                           y: size.height / max(1, container.labelOverlay.bounds.height))
                container.skyArc.layer.render(in: cg)
                container.labelOverlay.layer.render(in: cg)
                cg.restoreGState()
            }

            // Debug hook for automated verification: also write to Documents.
            if ProcessInfo.processInfo.arguments.contains("-captureToDocuments"),
               let data = image.pngData(),
               let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: dir.appendingPathComponent("capture.png"))
            }

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { self?.onPhotoCaptured(false) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { ok, _ in
                    DispatchQueue.main.async { self?.onPhotoCaptured(ok) }
                }
            }
        }

        /// Device alignment vs. manual look-around. With no IMU the view is forced
        /// to manual (and the HUD is told). Switching into manual seeds the drag
        /// azimuth/pitch from the current device heading so the view doesn't jump.
        func setManualAlignment(_ requested: Bool) {
            var manual = requested
            if !motionAvailable {
                manual = true
                if !requested && !didForceManual {
                    didForceManual = true
                    let cb = onForceManual
                    DispatchQueue.main.async { cb() }
                }
            }
            guard manual != manualAlignment else { return }
            if manual, let b = deviceBasis { seedAzPitch(from: b.forward) }
            manualAlignment = manual
            syncRenderLoop()                       // live look-around ↔ gesture pan
            view?.setNeedsDisplay()
        }

        private func seedAzPitch(from forward: SIMD3<Float>) {
            azimuth = atan2(forward.x, forward.y) * 180 / .pi
            pitch = max(-80, min(80, asinf(max(-1, min(1, forward.z))) * 180 / .pi))
        }

        func startCamera() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.inputs.isEmpty {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .hd1920x1080
                    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                       let input = try? AVCaptureDeviceInput(device: device),
                       self.session.canAddInput(input) {
                        self.session.addInput(input)
                        // Record the active format's true field of view + dimensions so
                        // the AR projection matches the camera exactly. With geometric
                        // distortion correction on (the default on supporting devices)
                        // the DELIVERED image has a different FOV than the raw format
                        // reports — using the raw figure scales the overlay a few %
                        // off the world, so labels drift toward the screen edges.
                        let format = device.activeFormat
                        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let gdcFOV = format.geometricDistortionCorrectedVideoFieldOfView
                        let fov = (device.isGeometricDistortionCorrectionSupported
                                   && device.isGeometricDistortionCorrectionEnabled
                                   && gdcFOV > 1)
                            ? gdcFOV : format.videoFieldOfView
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.cameraLongFOVDeg = fov
                            self.cameraFormatLong = Int(max(dims.width, dims.height))
                            self.cameraFormatShort = Int(min(dims.width, dims.height))
                            self.view?.setNeedsDisplay()
                        }
                    }
                    // A video data output purely to detect the first delivered frame
                    // (drives the smooth AR reveal); the preview layer draws the feed.
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutQueue)
                    if self.session.canAddOutput(self.videoOutput) {
                        self.session.addOutput(self.videoOutput)
                    }
                    self.session.commitConfiguration()
                }
                // CRITICAL for AR registration: digital video stabilization shifts the
                // image to smooth slow motion, so the stabilized feed lags the device's
                // true orientation — the overlay (locked to the IMU) then drifts against
                // it, worst during slow pans. Force it OFF on every connection.
                for output in self.session.outputs {
                    for conn in output.connections where conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = .off
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    if let conn = self?.container?.previewLayer.connection,
                       conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = .off
                    }
                }
                // No camera (simulator) → reveal at once so the overlay still shows
                // (transparent over black), matching the old behavior.
                if self.session.inputs.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.revealCamera() }
                    return
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }

        func stopCamera() {
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        // MARK: Viewpoint

        /// Stand at a new viewpoint. The eye sits at the coordinate at ground +
        /// 1.6 m; with `snapToSummit` ("Stand here" on a peak) it first moves to
        /// the highest DEM cell nearby, so you stand on the TRUE summit with a
        /// clear 360° view instead of a catalog point below the top.
        ///
        /// Fetch avoidance: each fetch downloads/stitches ~80 km of SRTM tiles, so if
        /// the CURRENT tile already covers this point (with a margin of terrain around
        /// the eye), reuse it and skip the network — exploring or GPS-walking within a
        /// region then costs zero downloads.
        func requestViewpoint(lat: Double, lon: Double, snapToSummit: Bool = false) {
            if let last = lastRequested,
               abs(last.lat - lat) < 1e-6, abs(last.lon - lon) < 1e-6 { return }
            if isReloading {
                // Never DROP a move that arrives mid-bake: doing so left the model
                // standing at the new feature while the render stayed put (the
                // Illumination Saddle → Rock bug). Keep only the LATEST request
                // and run it when the in-flight bake settles (finishReload).
                queuedRequest = (lat: lat, lon: lon, snap: snapToSummit)
                return
            }
            lastRequested = (lat, lon)
            pendingSummitSnap = snapToSummit
            isReloading = true
            report(.preparingTerrain(progress: nil))

            // Reuse fast-path: both tiers already cover this viewpoint.
            if let tile = dem, tile.contains(lat: lat, lon: lon, marginMeters: 18_000),
               let far = demFar, far.contains(lat: lat, lon: lon, marginMeters: 18_000) {
                let eye = summitSnappedEye(lat: lat, lon: lon, tile: tile)
                let ground = eye.elev
                refLat = eye.lat; refLon = eye.lon
                groundElev = ground
                recomputeCamElev()
                // Labels rebuild when the new panorama installs (bakeProgressive) —
                // rebuilding here floated new-ref anchors over the still-old image.
                rebuildSky()
                NSLog("Viewpoint reused current tile (no fetch)")
                bakeProgressive(progressFrom: 0) {
                    self.report(.ready)
                    self.onEyeElevation(Double(ground) + 1.6)
                    self.finishReload()
                }
                return
            }

            guard let device = view?.device else { isReloading = false; return }
            Task { [weak self] in
                let t0 = DispatchTime.now()
                var nearTile: DEMTile?
                var farTile: DEMTile?
                var fromNetwork = false
                let failure = "No elevation data for this area — check your connection and try again."
                // Instant-open fast path: reuse the last region's prebuilt tiles if they
                // cover this point — a flat disk read (<1 s) vs a ~10 s network + stitch.
                if let saved = DEMFetcher.loadLastRegion(),
                   saved.near.contains(lat: lat, lon: lon, marginMeters: 18_000),
                   (saved.far?.contains(lat: lat, lon: lon, marginMeters: 18_000) ?? true) {
                    nearTile = saved.near
                    farTile = saved.far
                    NSLog("DEM loaded from last-region snapshot (instant open)")
                } else {
                    do {
                        // Progress spans the WHOLE load, not just the network: every
                        // degree tile counts one unit when its download settles and a
                        // second when its decode + stitch finishes. Cached tiles tick
                        // their download units instantly, but the readout keeps
                        // climbing through the (often longer) stitch instead of
                        // sitting at "100%" while it runs. The bake is the fixed tail
                        // above `loadShare` (no incremental GPU signal).
                        let total = 2 * (DEMFetcher.tileCount(lat: lat, lon: lon, radiusMeters: Self.nearRadius)
                            + DEMFetcher.tileCount(lat: lat, lon: lon, radiusMeters: Self.farRadius))
                        await MainActor.run {
                            self?.loadUnitsDone = 0
                            self?.loadUnitsTotal = total
                            self?.report(.preparingTerrain(progress: total > 0 ? 0 : nil))
                        }
                        let onUnit: @Sendable () -> Void = { [weak self] in
                            DispatchQueue.main.async {
                                guard let self, self.loadUnitsTotal > 0 else { return }
                                self.loadUnitsDone = min(self.loadUnitsDone + 1, self.loadUnitsTotal)
                                self.report(.preparingTerrain(progress:
                                    Self.loadShare * Double(self.loadUnitsDone) / Double(self.loadUnitsTotal)))
                            }
                        }
                        // Near (native ~30 m, ≈40 km) + far (coarse, ≈120 km) in parallel.
                        async let near = DEMFetcher.fetch(lat: lat, lon: lon,
                                                          radiusMeters: Self.nearRadius, maxGrid: Self.nearMaxGrid,
                                                          onTileComplete: onUnit, onTileStitched: onUnit)
                        async let far = DEMFetcher.fetch(lat: lat, lon: lon,
                                                         radiusMeters: Self.farRadius, maxGrid: Self.farMaxGrid,
                                                         onTileComplete: onUnit, onTileStitched: onUnit)
                        nearTile = try await near
                        farTile = try await far
                        fromNetwork = true
                    } catch {
                        if let bundled = self?.bundledTile(), bundled.contains(lat: lat, lon: lon) {
                            nearTile = bundled; farTile = bundled
                            NSLog("DEM fetch failed; using bundled cascades fallback")
                        } else {
                            NSLog("DEM fetch failed: \(error)")
                        }
                    }
                }
                guard let tile = nearTile else {
                    await MainActor.run {
                        // Clear the dedupe memory: a retry of the SAME spot after
                        // a failure must re-attempt, not silently no-op.
                        self?.lastRequested = nil
                        self?.report(.failed(failure))
                        self?.finishReload()
                    }
                    return
                }
                let tex = tile.makeTexture(device: device)
                let farTex = (farTile?.makeTexture(device: device))
                NSLog("DEM ready in %.0f ms (%@)", Self.ms(since: t0), fromNetwork ? "fetch" : "snapshot")
                // Snapshot a freshly fetched region for an instant next launch.
                if fromNetwork { DEMFetcher.saveLastRegion(near: tile, far: farTile) }
                await MainActor.run {
                    guard let self else { return }
                    self.dem = tile
                    self.demTexture = tex
                    self.demFar = farTile
                    self.demFarTexture = farTex
                    self.renderer?.heightTexture = tex
                    self.renderer?.farHeightTexture = farTex
                    let eye = self.summitSnappedEye(lat: lat, lon: lon, tile: tile)
                    let ground = eye.elev
                    self.refLat = eye.lat; self.refLon = eye.lon
                    self.groundElev = ground
                    self.recomputeCamElev()
                    // Labels rebuild on panorama install (see bakeProgressive).
                    self.rebuildSky()
                    self.bakeProgressive(progressFrom: Self.loadShare) {
                        self.report(.ready)
                        self.onEyeElevation(Double(ground) + 1.6)
                        self.finishReload()
                    }
                }
            }
        }

        /// Where the eye actually stands. Plain viewpoints (GPS, map pin) use the
        /// exact coordinate; a "Stand here" peak visit snaps to the highest DEM
        /// cell nearby — catalog summit coords are often tens of meters off the
        /// true top, which leaves a shoulder blocking part of the panorama. The
        /// snap radius is capped at ~45% of the distance to the NEAREST OTHER
        /// named peak, so standing on a labelled false summit keeps you on ITS
        /// top instead of teleporting you to the higher main summit.
        private func summitSnappedEye(
            lat: Double, lon: Double, tile: DEMTile
        ) -> (lat: Double, lon: Double, elev: Float) {
            if pendingSummitSnap {
                let mLat = 111_320.0, mLon = 111_320.0 * max(cos(lat * .pi / 180), 0.01)
                var nearestOther = Double.infinity
                for p in peaks {
                    let d = hypot((p.latitude - lat) * mLat, (p.longitude - lon) * mLon)
                    if d > 1, d < nearestOther { nearestOther = d }   // >1 m: skip this peak itself
                }
                let radius = min(250, max(40, nearestOther * 0.45))
                return tile.highestNear(lat: lat, lon: lon, radiusMeters: radius)
            }
            // Never spawn the camera inside the hillside. The coordinate's BILINEAR
            // height can sit many meters below the DEM cells right next to it
            // (catalog/GPS coords vs AW3D30 misregistration — routine on summits
            // and steep faces); the raymarch then hits rock at zero distance in
            // every direction and the whole view (sky included) renders one flat
            // grey. Keep the position but lift the eye to the local crest within
            // ~1.5 cells — a real observer standing there sees over that relief.
            let crest = tile.highestNear(lat: lat, lon: lon, radiusMeters: 45).elev
            return (lat, lon, max(tile.elevation(lat: lat, lon: lon), crest))
        }

        /// Change the vertical exaggeration: rescale the eye to sit above the
        /// scaled ground and re-bake. No-op if unchanged or no DEM yet.
        func setExaggeration(_ value: Float) {
            guard abs(value - exaggeration) > 0.001 else { return }
            exaggeration = value
            guard dem != nil else { return }
            recomputeCamElev()
            // Labels rebuild on panorama install (see bakeProgressive) — the old
            // heights stay glued to the old image until the re-baked one swaps in.
            bakeProgressive(progressFrom: 0) { self.report(.ready) }
        }

        /// Eye sits just above the (exaggeration-scaled) ground at the viewpoint.
        private func recomputeCamElev() {
            camElev = groundElev * exaggeration + 1.6
        }

        // MARK: Peak labels

        func setPeaks(_ p: [Peak]) {
            guard p.map(\.id) != peaks.map(\.id) else { return }
            peaks = p
            rebuildLabelAnchors()
        }

        func setLakes(_ l: [Peak]) {
            guard l.map(\.id) != lakes.map(\.id) else { return }
            lakes = l
            rebuildLabelAnchors()
        }

        /// Anchors are density-independent (the overlay declutters per frame),
        /// so switching density is just a redraw — no anchor rebuild.
        func setLabelDensity(_ d: LabelDensity) {
            guard container?.labelOverlay.density != d else { return }
            container?.labelOverlay.density = d
            view?.setNeedsDisplay()
        }

        /// Saved-list membership for the Saved density — a redraw, like density.
        func setSavedPeaks(climbed: Set<String>, bookmarked: Set<String>) {
            guard let overlay = container?.labelOverlay,
                  overlay.climbedIDs != climbed || overlay.bookmarkedIDs != bookmarked
            else { return }
            overlay.climbedIDs = climbed
            overlay.bookmarkedIDs = bookmarked
            view?.setNeedsDisplay()
        }

        /// Pending coalesced anchor rebuild (see `rebuildLabelAnchors`).
        private var anchorRebuildWork: DispatchWorkItem?

        /// Recompute label anchors for the current viewpoint/exaggeration.
        /// COALESCED: a teleport fires this three times within ~100 ms (bake
        /// start, then setPeaks + setLakes as the new area's features publish),
        /// and each compute renders its own 4096-wide depth panorama — running
        /// all three serialized the GPU behind the bake and tripled the wait
        /// before labels (and, during a re-bake, the whole scene swap) could
        /// land. Only the last request in a burst actually runs.
        private func rebuildLabelAnchors() {
            anchorRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuildLabelAnchorsNow() }
            anchorRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        /// The actual (expensive) rebuild: DEM-snap each peak, fold in curvature +
        /// heightScale, line-of-sight occlusion — off the main thread; a generation
        /// token drops stale results. The result routes through `installAnchors`:
        /// installed directly when the scene is stable, or stashed for the atomic
        /// swap while a re-bake is in flight — safe to call mid-bake.
        private func rebuildLabelAnchorsNow() {
            // Early-outs still deliver a (empty) result: during a re-bake the swap
            // barrier is waiting on it — silently returning would hang the swap.
            guard let dem else {
                installAnchors([], visibleIDs: [])
                return
            }
            let far = self.demFar
            let peaks = self.peaks
            let lakes = self.lakes
            guard !peaks.isEmpty || !lakes.isEmpty else {
                installAnchors([], visibleIDs: [])
                return
            }
            let refLat = self.refLat, refLon = self.refLon
            let camElevM = Double(self.camElev), hs = Double(self.exaggeration)
            // Build the SAME uniforms the bake uses: the depth map below is rendered
            // with the exact march/eye/DEM of the visible panorama, so per-label
            // visibility decided against it always agrees with the picture on screen.
            var maskUniforms = makeUniforms(width: 1, height: 1)
            dem.applyDEMUniforms(to: &maskUniforms, refLat: refLat, refLon: refLon)
            far?.applyFarDEMUniforms(to: &maskUniforms, refLat: refLat, refLon: refLon)
            let panoElevMax = Double(maskUniforms.panoElevMax)
            let skyDepth = Double(maskUniforms.maxDistance) * 2   // beyond = the FAR sky sentinel
            let renderer = self.renderer
            labelGeneration &+= 1
            let gen = labelGeneration
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let tD = DispatchTime.now()
                let depthMap = renderer?.terrainDepthMap(uniforms: maskUniforms)
                let tB = DispatchTime.now()
                if Self.labelDebug {
                    NSLog("Anchor depth map: %.0f ms", Self.ms(since: tD))
                }
                defer {
                    if Self.labelDebug { NSLog("Anchor build: %.0f ms", Self.ms(since: tB)) }
                }
                let (anchors, visibleIDs) = Self.buildAnchors(
                    peaks: peaks, lakes: lakes, dem: dem, far: far, refLat: refLat, refLon: refLon,
                    camElevMeters: camElevM, heightScale: hs,
                    depth: depthMap?.depth ?? [], depthW: depthMap?.width ?? 0,
                    depthH: depthMap?.height ?? 0, skyDepth: skyDepth, panoElevMax: panoElevMax)
                DispatchQueue.main.async {
                    guard let self, gen == self.labelGeneration else { return }
                    self.installAnchors(anchors, visibleIDs: visibleIDs)
                }
            }
        }

        /// Route a computed anchor set: stash it for the atomic image+label swap
        /// while a re-bake is pending, install it directly otherwise.
        private func installAnchors(_ anchors: [PeakLabelOverlayView.Anchor],
                                    visibleIDs: Set<String>) {
            if rebakePending {
                pendingAnchors = (anchors, visibleIDs)
                maybeCompleteSwap()
            } else {
                container?.labelOverlay.anchors = anchors
                onVisibleFeatures(visibleIDs)
                view?.setNeedsDisplay()
            }
        }

        /// Scrub the sky to a new instant. The terrain skyline (horizon) is unchanged,
        /// so this only re-lights the celestial overlay — cheap enough per scrub tick.
        func setDisplayDate(_ date: Date) {
            guard abs(date.timeIntervalSince(displayDate)) > 0.5 else { return }
            displayDate = date
            updateSunDirectionNow()
            rebuildCelestial()
        }

        /// Compute the sun direction for the CURRENT viewpoint/date on the spot and push
        /// it to the render uniforms. `skySunENU` alone drives the day↔night sky colour,
        /// but the full star/arc rebuild is a two-hop async job (skyline → celestial) —
        /// so on teleport the terrain would render with the OLD location's sun (a day sky
        /// over a night place) until that landed, a visible flash. Setting the sun here,
        /// synchronously, means the very next bake/frame is already lit correctly; the
        /// async pass then fills in the stars, arcs and discs. Sun ephemeris is cheap and
        /// needs no skyline, so this is safe on the main thread.
        private func updateSunDirectionNow() {
            let sun = Ephemeris.sunPosition(date: displayDate, latitude: refLat, longitude: refLon)
            skySunENU = SkyArcOverlayView.enu(azimuthDeg: sun.azimuthDeg, elevationDeg: sun.elevationDeg)
        }

        /// Recompute the terrain skyline for this viewpoint (the expensive,
        /// time-independent part), cache it, then place the sky bodies on it.
        private func rebuildSky() {
            guard let dem else { return }
            // Correct the sky lighting for the new viewpoint immediately, so the next
            // bake isn't lit by the previous location's sun while the async pass runs.
            updateSunDirectionNow()
            let far = self.demFar
            let lat = refLat, lon = refLon
            let camElevM = Double(camElev), hs = Double(exaggeration)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let horizon = Self.buildHorizon(dem: dem, far: far, refLat: lat, refLon: lon,
                                                camElevMeters: camElevM, heightScale: hs)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cachedHorizon = horizon
                    self.rebuildCelestial()
                }
            }
        }

        /// Place the sun, moon, stars and Milky Way at `displayDate` against the cached
        /// skyline (off-main), then hand the projected directions to the sky overlay.
        /// No DEM marching → fast, so scrubbing time stays smooth.
        private func rebuildCelestial() {
            guard let horizon = cachedHorizon else { return }
            let lat = refLat, lon = refLon
            let date = displayDate
            DispatchQueue.global(qos: .utility).async { [weak self] in
                func horizonAt(_ azDeg: Double) -> Double {
                    var a = azDeg.truncatingRemainder(dividingBy: 360); if a < 0 { a += 360 }
                    let n = horizon.count
                    let x = a / 360 * Double(n) - 0.5
                    let i0 = Int(floor(x))
                    let f = x - Double(i0)
                    let a0 = horizon[((i0 % n) + n) % n]
                    let a1 = horizon[((i0 + 1) % n + n) % n]
                    return Double(a0) * (1 - f) + Double(a1) * f
                }
                func shortestDelta(_ a: Double, _ b: Double) -> Double {
                    var d = (b - a).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d -= 360 }; if d < -180 { d += 360 }
                    return d
                }
                // Format rise/set in the VIEWED location's timezone (offline, from its
                // longitude), not the device's — otherwise a remote viewpoint shows
                // times shifted by the UTC gap between here and there.
                let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .none
                fmt.timeZone = PanoramaViewModel.approxTimeZone(longitudeDeg: lon)

                // Per-body: samples flagged visible (above the ridge skyline) + the
                // ridge-crossing rise/set tags (first ↑ and first ↓).
                func build(_ path: Ephemeris.Path, color: UIColor)
                    -> (samples: [SkyArcOverlayView.Sample], tags: [SkyArcOverlayView.Tag]) {
                    var samples: [SkyArcOverlayView.Sample] = []
                    samples.reserveCapacity(path.samples.count + 8)
                    var prev: (az: Double, el: Double, c: Double)?
                    for s in path.samples {
                        let az = s.position.azimuthDeg, el = s.position.elevationDeg
                        let c = el - horizonAt(az)
                        // Insert the EXACT ridge crossing between a hidden and a
                        // visible sample: without it each arc stopped at whatever
                        // height its last time-step sample landed, so the sun and
                        // moon lines ended at visibly different gaps above the
                        // terrain. With it, every arc runs precisely down to the
                        // ridge line.
                        if let p = prev, (p.c <= 0) != (c <= 0), p.c != c {
                            let f = p.c / (p.c - c)
                            let crossAz = p.az + f * shortestDelta(p.az, az)
                            samples.append(.init(
                                dir: SkyArcOverlayView.enu(azimuthDeg: crossAz,
                                                           elevationDeg: horizonAt(crossAz)),
                                visible: true))
                        }
                        samples.append(.init(dir: SkyArcOverlayView.enu(azimuthDeg: az, elevationDeg: el),
                                             visible: c >= 0))
                        prev = (az, el, c)
                    }
                    var tags: [SkyArcOverlayView.Tag] = []
                    var haveUp = false, haveDown = false
                    for i in 1..<path.samples.count {
                        let p0 = path.samples[i - 1].position, p1 = path.samples[i].position
                        let c0 = p0.elevationDeg - horizonAt(p0.azimuthDeg)
                        let c1 = p1.elevationDeg - horizonAt(p1.azimuthDeg)
                        guard c0 != c1, (c0 <= 0) != (c1 <= 0) else { continue }
                        let rising = c1 > c0
                        if (rising && haveUp) || (!rising && haveDown) { continue }
                        let f = c0 / (c0 - c1)
                        let az = p0.azimuthDeg + f * shortestDelta(p0.azimuthDeg, p1.azimuthDeg)
                        let date = path.samples[i - 1].date.addingTimeInterval(
                            f * path.samples[i].date.timeIntervalSince(path.samples[i - 1].date))
                        tags.append(.init(
                            dir: SkyArcOverlayView.enu(azimuthDeg: az, elevationDeg: horizonAt(az)),
                            text: "\(rising ? "↑" : "↓") \(fmt.string(from: date))", color: color))
                        if rising { haveUp = true } else { haveDown = true }
                    }
                    return (samples, tags)
                }

                let sun = build(Ephemeris.windowPath(of: .sun, centeredOn: date, latitude: lat, longitude: lon),
                                color: UIColor(red: 0.95, green: 0.73, blue: 0.10, alpha: 0.95))
                let moon = build(Ephemeris.windowPath(of: .moon, centeredOn: date, latitude: lat, longitude: lon),
                                 color: UIColor(white: 0.85, alpha: 0.9))
                let sunNow = Ephemeris.sunPosition(date: date, latitude: lat, longitude: lon)
                let moonNow = Ephemeris.moonPosition(date: date, latitude: lat, longitude: lon)
                let sunDisc = SkyArcOverlayView.Disc(
                    dir: SkyArcOverlayView.enu(azimuthDeg: sunNow.azimuthDeg, elevationDeg: sunNow.elevationDeg),
                    visible: sunNow.elevationDeg >= horizonAt(sunNow.azimuthDeg))
                let moonDisc = SkyArcOverlayView.Disc(
                    dir: SkyArcOverlayView.enu(azimuthDeg: moonNow.azimuthDeg, elevationDeg: moonNow.elevationDeg),
                    visible: moonNow.elevationDeg >= horizonAt(moonNow.azimuthDeg))

                // Stars + planets + Milky Way: fade in as the sun sets (twilight →
                // night), hidden below the ridge skyline like the arcs. Named objects
                // (bright stars, planets, sun, moon) are collected for tap-to-label.
                let nightOpacity = Float(CelestialSky.nightVisibility(sunElevationDeg: sunNow.elevationDeg))
                var stars: [SkyArcOverlayView.StarSample] = []
                var planets: [SkyArcOverlayView.StarSample] = []
                var named: [SkyArcOverlayView.NamedObject] = []
                func enu(_ az: Double, _ el: Double) -> SIMD3<Float> {
                    SkyArcOverlayView.enu(azimuthDeg: az, elevationDeg: el)
                }
                if nightOpacity > 0.001 {
                    // Stars: rendered as brightness-tiered white points — except the
                    // brightest (mag < 1.5), which go through the COLOURED point
                    // layers so Betelgeuse/Antares read orange-red and Vega/Rigel
                    // blue-white, like the real sky. Every REAL catalog star carries
                    // a name (the procedural fill doesn't) and is tappable.
                    for ps in CelestialSky.projectedStars(date: date, latitude: lat, longitude: lon)
                    where ps.elevationDeg > -2 {
                        let dir = enu(ps.azimuthDeg, ps.elevationDeg)
                        let vis = ps.elevationDeg >= horizonAt(ps.azimuthDeg)
                        if ps.magnitude < 1.5 {
                            planets.append(.init(dir: dir, visible: vis, magnitude: ps.magnitude,
                                                 colorIndex: Self.starColorIndex(ps.color)))
                        } else {
                            stars.append(.init(dir: dir, visible: vis, magnitude: ps.magnitude, colorIndex: 0))
                        }
                        if vis, !ps.name.isEmpty {
                            named.append(.init(name: ps.name, dir: dir, magnitude: ps.magnitude))
                        }
                    }
                    // Planets: coloured, sized by magnitude, and tappable (named).
                    for pp in CelestialSky.projectedPlanets(date: date, latitude: lat, longitude: lon)
                    where pp.elevationDeg > -2 {
                        let dir = enu(pp.azimuthDeg, pp.elevationDeg)
                        let vis = pp.elevationDeg >= horizonAt(pp.azimuthDeg)
                        planets.append(.init(dir: dir, visible: vis, magnitude: pp.magnitude,
                                             colorIndex: Self.starColorIndex(pp.color)))
                        if vis { named.append(.init(name: pp.name, dir: dir, magnitude: pp.magnitude)) }
                    }
                }
                // Sun + Moon are tappable whenever above the skyline (day or night).
                if sunNow.elevationDeg >= horizonAt(sunNow.azimuthDeg) {
                    named.append(.init(name: "Sun", dir: enu(sunNow.azimuthDeg, sunNow.elevationDeg),
                                       magnitude: -26.7))
                }
                if moonNow.elevationDeg >= horizonAt(moonNow.azimuthDeg) {
                    named.append(.init(name: "Moon", dir: enu(moonNow.azimuthDeg, moonNow.elevationDeg),
                                       magnitude: -12.7))
                }
                let phase = Ephemeris.moonPhase(date: date)
                let moonIllum = CGFloat(phase.illuminatedFraction)
                let moonWaxing = phase.ageDays < 14.7653          // < half a synodic month

                let skySun = SkyArcOverlayView.enu(azimuthDeg: sunNow.azimuthDeg,
                                                   elevationDeg: sunNow.elevationDeg)
                DispatchQueue.main.async {
                    guard let self, let so = self.container?.skyArc else { return }
                    so.sunSamples = sun.samples
                    so.moonSamples = moon.samples
                    so.sunDisc = sunDisc
                    so.moonDisc = moonDisc
                    so.tags = sun.tags + moon.tags
                    so.stars = stars
                    so.planets = planets
                    so.nightOpacity = nightOpacity
                    so.namedObjects = named
                    so.moonIlluminated = moonIllum
                    so.moonWaxing = moonWaxing
                    self.skySunENU = skySun
                    self.view?.setNeedsDisplay()
                }
            }
        }

        /// Map a catalog star colour to the overlay's fixed colour-bucket index.
        private static func starColorIndex(_ c: CelestialSky.StarColor) -> Int {
            switch c {
            case .blueWhite: return 0
            case .white: return 1
            case .yellowWhite: return 2
            case .orange: return 3
            case .red: return 4
            }
        }

        /// Two-tier elevation: the high-res near tile where it covers the point, else
        /// the coarse far tile (mirrors the shader's tier choice on the CPU side).
        private static func elevAt(near: DEMTile, far: DEMTile?, lat: Double, lon: Double) -> Float {
            if near.contains(lat: lat, lon: lon) { return near.elevation(lat: lat, lon: lon) }
            return (far ?? near).elevation(lat: lat, lon: lon)
        }

        /// Terrain skyline elevation angle per azimuth bin — marched once per
        /// viewpoint. Drives sky-arc occlusion + rise/set crossing tags.
        private static func buildHorizon(
            dem: DEMTile, far: DEMTile?, refLat: Double, refLon: Double,
            camElevMeters: Double, heightScale: Double
        ) -> [Float] {
            // 0.375°/bin: at 480 bins (0.75°) the interpolated skyline could disagree
            // with the rendered ridge by a few tenths of a degree in rugged terrain,
            // visibly mis-timing sun/moon rise-set tags and disc visibility. One-time
            // per viewpoint, off-main, so the 2× march cost is invisible.
            let bins = 960
            let earthR = 6_371_000.0, refraction = 0.13
            let curvatureK = (1 - refraction) / (2 * earthR)
            let maxDist = 120_000.0
            // Cell-aware step (see lineOfSightClear): keep ≤ ~0.8 cell so a thin ridge
            // or notch can't slip between samples and let a sky-arc segment show
            // through the terrain.
            let nearCellM = dem.cellsize * 111_320.0
            let farCellM = (far?.cellsize ?? dem.cellsize) * 111_320.0
            var horizon = [Float](repeating: -90, count: bins)
            for b in 0..<bins {
                let bearing = (Double(b) + 0.5) / Double(bins) * 360 * .pi / 180
                var maxAngle = -90.0
                var s = 12.0
                while s < maxDist {
                    let p = GeoMath.destination(latitude: refLat, longitude: refLon,
                                                bearingRad: bearing, distanceMeters: s)
                    let g = Double(elevAt(near: dem, far: far, lat: p.latitude, lon: p.longitude))
                    let a = atan2(g * heightScale - curvatureK * s * s - camElevMeters, s) * 180 / .pi
                    if a > maxAngle { maxAngle = a }
                    let cellHere = (s < Self.nearRadius) ? nearCellM : farCellM
                    s += min(max(12.0, s * 0.012), cellHere * 0.8)
                }
                horizon[b] = Float(maxAngle)
            }
            return horizon
        }

        private static func buildAnchors(
            peaks: [Peak], lakes: [Peak] = [], dem: DEMTile, far: DEMTile?, refLat: Double, refLon: Double,
            camElevMeters: Double, heightScale: Double,
            depth: [Float], depthW: Int, depthH: Int, skyDepth: Double, panoElevMax: Double
        ) -> (anchors: [PeakLabelOverlayView.Anchor], visibleIDs: Set<String>) {
            let mLat = 111_320.0
            let mLon = 111_320.0 * max(cos(refLat * .pi / 180), 0.01)
            let earthR = 6_371_000.0, refraction = 0.13
            let curvatureK = (1 - refraction) / (2 * earthR)   // matches the shader
            // Geodesic-bulge coefficient — the forward twin of the shader's per-sample
            // correction (Shaders.metal terrainHeight): a feature due east is seen
            // slightly poleward of east, by east²·tanRef/(2R) meters of northing.
            let tanRefOver2R = tan(refLat * .pi / 180) / (2 * Uniforms.enuEarthRadiusMeters)
            let maxDist = 120_000.0                             // within the far DEM tile
            // The per-peak work (summit snap + line-of-sight ray march, thousands of
            // DEM samples each) is independent and reads only immutable data, so fan
            // it out across cores; single-threaded this was the visible post-load
            // stall. Each slot is written by exactly one iteration.
            enum Verdict: UInt8 { case skipped = 0, shown, occluded, floating }
            // Per-peak summit-snap radius: 300 m by default (catalog coords are
            // often off the rendered summit), but capped at ~45% of the distance
            // to the NEAREST OTHER named peak — so a labelled false summit snaps
            // to ITS OWN top instead of stealing the main summit next door (which
            // would stack both labels on one point). Neighbors found via a coarse
            // grid hash (one ring covers the 667 m that could cap a 300 m radius).
            var snapRadius = [Double](repeating: 300, count: peaks.count)
            if peaks.count > 1 {
                let cellLat = 0.006
                let cellLon = 0.006 / max(cos(refLat * .pi / 180), 0.01)
                func cellKey(_ la: Int64, _ lo: Int64) -> Int64 { la &* 1_000_000 &+ lo }
                var grid: [Int64: [Int]] = [:]
                for (i, p) in peaks.enumerated() {
                    grid[cellKey(Int64((p.latitude + 90) / cellLat),
                                 Int64((p.longitude + 180) / cellLon)), default: []].append(i)
                }
                for (i, p) in peaks.enumerated() {
                    let la = Int64((p.latitude + 90) / cellLat)
                    let lo = Int64((p.longitude + 180) / cellLon)
                    var nn = Double.infinity
                    for dla in -1...1 {
                        for dlo in -1...1 {
                            // Saddles never snap, so they don't compete for summit cells —
                            // don't let them shrink a real summit's snap radius.
                            for j in grid[cellKey(la + Int64(dla), lo + Int64(dlo)), default: []]
                            where j != i && !peaks[j].isSaddle {
                                let q = peaks[j]
                                let d = hypot((q.latitude - p.latitude) * mLat,
                                              (q.longitude - p.longitude) * mLon)
                                if d < nn { nn = d }
                            }
                        }
                    }
                    if nn * 0.45 < 300 { snapRadius[i] = max(40, nn * 0.45) }
                }
            }
            // Peaks occupy [0, peaks.count); lakes [peaks.count, total). Lakes skip
            // the summit snap (a lake would "snap" onto its shoreline ridge!) and the
            // floating-sky cull (a surface point can't float): they anchor at the DEM
            // surface elevation of the catalog coordinate.
            let total = peaks.count + lakes.count
            var results = [PeakLabelOverlayView.Anchor?](repeating: nil, count: total)
            var verdicts = [UInt8](repeating: 0, count: total)
            results.withUnsafeMutableBufferPointer { res in
                verdicts.withUnsafeMutableBufferPointer { verd in
                    DispatchQueue.concurrentPerform(iterations: total) { i in
                        let isWater = i >= peaks.count
                        let peak = isWater ? lakes[i - peaks.count] : peaks[i]
                        // Coverage is the union of both tiers (far spans the whole scene).
                        let inNear = dem.contains(lat: peak.latitude, lon: peak.longitude)
                        let snapTile = inNear ? dem : (far ?? dem)
                        guard snapTile.contains(lat: peak.latitude, lon: peak.longitude) else { return }
                        // Cheap range gate on the CATALOG coord before the (costly) summit
                        // snap; the snap moves ≤300 m so the slack keeps boundary peaks.
                        let approxHoriz = hypot((peak.longitude - refLon) * mLon,
                                                (peak.latitude - refLat) * mLat)
                        guard approxHoriz <= maxDist + 500 else { return }
                        // Snap to the highest DEM cell near the catalog coord, and use the DEM
                        // elevation — so the label sits on the rendered summit, not the (often
                        // offset) catalog point/height. Near peaks snap on the high-res tile.
                        // Lakes AND saddles/gaps anchor at the DEM elevation of the point
                        // itself, no snap: a saddle is a LOW point between summits, and the
                        // summit snap dragged its label uphill onto the neighboring peak.
                        let hi = isWater || peak.isSaddle
                            ? (lat: peak.latitude, lon: peak.longitude,
                               elev: snapTile.elevation(lat: peak.latitude, lon: peak.longitude))
                            : snapTile.highestNear(lat: peak.latitude, lon: peak.longitude,
                                                   radiusMeters: snapRadius[i])
                        // Forward mapping matching the shader's corrected sampling:
                        // easting scaled by cos at the FEATURE's latitude (meridian
                        // convergence), northing plus the geodesic bulge. atan2(east,
                        // north) then equals the great-circle compass bearing, so the
                        // label direction, the rendered summit and the real world agree.
                        let east = (hi.lon - refLon) * 111_320.0 * max(cos(hi.lat * .pi / 180), 0.01)
                        let north = (hi.lat - refLat) * mLat + east * east * tanRefOver2R
                        let horiz = (east * east + north * north).squareRoot()
                        if horiz < 80 || horiz > maxDist { return }
                        let apparentUp = Double(hi.elev) * heightScale - curvatureK * horiz * horiz - camElevMeters
                        let sightAngle = atan2(apparentUp, horiz) * 180 / .pi
                        // Depth-map azimuth = the anchor's own rendered azimuth (NOT a
                        // separately-derived geographic bearing), so the occlusion
                        // lookup can never sample a different column than the summit
                        // is drawn in.
                        var bearing = atan2(east, north)
                        if bearing < 0 { bearing += 2 * .pi }
                        // OCCLUSION = one lookup in the RENDER's own depth panorama:
                        // the feature is visible exactly when rendered TERRAIN in its
                        // direction reaches (about) its distance. Sky texels are
                        // NEUTRAL — they must never vouch for a peak. (They used to:
                        // any sky in the 3×3 made `farthest` the FAR sentinel, so a
                        // 110 km giant whose sightline passed a hair BELOW a 35 km
                        // ridge picked up the sky above that ridge and labeled itself
                        // onto the occluder's slope — the classic "Mount Stuart
                        // through Buck Mountain" bug.)
                        // The 3×3 neighborhood forgives the map's finite resolution
                        // at silhouettes; the relative margin absorbs the summit-snap
                        // vs texel-centre offset; saddles get a looser one since
                        // their grazing rays legally stop on the col walls.
                        //
                        // WATER doesn't use the depth map at all. A lake is a LOW
                        // point, so its grazing ray legally stops on the basin rim —
                        // that forced a huge slack margin (max(250, 18%·distance) ≈
                        // 2.5 km at 14 km), and the 3×3 max-depth let any farther
                        // terrain peeking above a near ridge "vouch" for the lake:
                        // distant lakes labeled onto ridges kilometers in front of
                        // them. An exact CPU march along the sightline (same
                        // apparent-height math as this anchor) has none of that.
                        if isWater {
                            // Cheap conservative pre-pass: if the rendered terrain
                            // at the lake's OWN pixel already reaches the lake's
                            // distance, the water itself is drawn there — visible,
                            // no march needed. (Strict center-texel + tight margin:
                            // the old false-visibles came from a 3×3 MAX depth and
                            // an 18% margin, not from this test.) Only the
                            // ambiguous rim-grazing cases fall through to the
                            // march, and those exit early at their occluder —
                            // without this, a summit viewpoint marched hundreds of
                            // clear sightlines end-to-end (~seconds of CPU).
                            var quickVisible = false
                            if depthW > 0 {
                                var uu = bearing / (2 * .pi)
                                uu -= floor(uu)
                                let vv = 0.5 - 0.5 * (sightAngle * .pi / 180) / panoElevMax
                                let mx = min(depthW - 1, max(0, Int(uu * Double(depthW))))
                                let my = min(depthH - 1, max(0, Int(vv * Double(depthH))))
                                let dC = Double(depth[my * depthW + mx])
                                if dC < skyDepth, dC >= horiz - max(150, horiz * 0.02) {
                                    quickVisible = true
                                }
                            }
                            let occluded = !quickVisible && Self.waterSightlineOccluded(
                                eyeLat: refLat, eyeLon: refLon,
                                featLat: hi.lat, featLon: hi.lon,
                                horiz: horiz, apparentUp: apparentUp,
                                camElevMeters: camElevMeters, heightScale: heightScale,
                                curvatureK: curvatureK, dem: dem, far: far)
                            if Self.labelDebug, horiz < 25_000 {
                                NSLog("labelDebug WATER %@ at %.0f m: %@%@",
                                      peak.name, horiz, occluded ? "OCCLUDED" : "visible",
                                      quickVisible ? " (depth fast-path)" : "")
                            }
                            if occluded {
                                verd[i] = Verdict.occluded.rawValue
                                return
                            }
                        } else if depthW > 0 {
                            var uu = bearing / (2 * .pi)
                            uu -= floor(uu)                                  // wrap to [0,1)
                            let elRad = sightAngle * .pi / 180
                            let vv = 0.5 - 0.5 * elRad / panoElevMax
                            let mx = Int(uu * Double(depthW))
                            let my = min(depthH - 1, max(0, Int(vv * Double(depthH))))
                            var farthestTerrain: Float = 0
                            var skyTouched = false
                            for dy in -1...1 {
                                let ry = min(depthH - 1, max(0, my + dy))
                                for dx in -1...1 {
                                    let rx = ((mx + dx) % depthW + depthW) % depthW
                                    let d = depth[ry * depthW + rx]
                                    if Double(d) >= skyDepth { skyTouched = true }
                                    else { farthestTerrain = max(farthestTerrain, d) }
                                }
                            }
                            let margin = peak.isSaddle
                                ? max(250, horiz * 0.18)
                                : max(120, horiz * 0.08)
                            if Double(farthestTerrain) < horiz - margin {
                                // No rendered terrain reaches the peak's distance here.
                                // A sky-touched neighborhood can still be a sub-texel
                                // summit tip the bake missed — but ONLY if the terrain
                                // just below is the peak's OWN body (depth ≈ its
                                // distance), not a nearer occluder's slope. The below-
                                // margin is looser: a gentle distant flank recedes fast
                                // with each 0.2° step down.
                                var rescued = false
                                if skyTouched, !peak.isSaddle {
                                    let belowMargin = max(margin, horiz * 0.15)
                                    var dropDeg = 0.2
                                    while dropDeg <= 0.6 {
                                        let el = (sightAngle - dropDeg) * .pi / 180
                                        let dvv = 0.5 - 0.5 * el / panoElevMax
                                        let dmy = min(depthH - 1, max(0, Int(dvv * Double(depthH))))
                                        let d = Double(depth[dmy * depthW + min(depthW - 1, max(0, mx))])
                                        if d < skyDepth, d >= horiz - belowMargin {
                                            rescued = true
                                            break
                                        }
                                        dropDeg += 0.2
                                    }
                                }
                                if !rescued {
                                    if Self.labelDebug, horiz < 10_000 {
                                        NSLog("labelDebug OCCLUDED %@ at %.0f m: render terrain reaches %.0f m in its direction",
                                              peak.name, horiz, Double(farthestTerrain))
                                    }
                                    // For the stats: all-sky with no supporting body =
                                    // floater; otherwise nearer terrain occludes it.
                                    verd[i] = (skyTouched && farthestTerrain == 0)
                                        ? Verdict.floating.rawValue : Verdict.occluded.rawValue
                                    return
                                }
                            }
                        }
                        verd[i] = Verdict.shown.rawValue
                        // Pin the dot to the RENDERED silhouette. The anchor's
                        // height is the DEM's summit cell, but the raymarch can
                        // undersample a sharp spire and draw it a little lower —
                        // the dot then floats in the sky above the drawn mountain
                        // (classic on needle summits like Alpamayo). If the depth
                        // map shows SKY at the anchor's own pixel, walk down its
                        // column to the first rendered terrain and place the dot
                        // there. (The visible bake is finer than the depth map, so
                        // its silhouette is never LOWER — the clamp can only land
                        // on or just inside the drawn mountain.)
                        var placedUp = apparentUp
                        if depthW > 0 {
                            var cu = bearing / (2 * .pi)
                            cu -= floor(cu)
                            let cx = min(depthW - 1, max(0, Int(cu * Double(depthW))))
                            let elRad = sightAngle * .pi / 180
                            let row0 = min(depthH - 1, max(0,
                                Int((0.5 - 0.5 * elRad / panoElevMax) * Double(depthH))))
                            if Double(depth[row0 * depthW + cx]) >= skyDepth {
                                // Cap the drop at ~3.5°: the occlusion pass vouched
                                // for terrain near this feature's distance, so the
                                // silhouette is always close below.
                                let rowsPerDeg = Double(depthH) / (2 * panoElevMax) * .pi / 180
                                let maxRow = min(depthH - 1, row0 + max(2, Int(rowsPerDeg * 3.5)))
                                var r = row0 + 1
                                while r <= maxRow, Double(depth[r * depthW + cx]) >= skyDepth { r += 1 }
                                if r <= maxRow {
                                    let vv = (Double(r) + 0.5) / Double(depthH)
                                    let clampedRad = (0.5 - vv) * 2 * panoElevMax
                                    placedUp = tan(clampedRad) * horiz
                                }
                            }
                        }
                        // Catalog elevation 0 = "unknown" (some OSM peaks have no ele
                        // tag): substitute the DEM summit height so the label's declutter
                        // priority and the info card don't see a bogus 0 m.
                        let labeled = peak.elevationMeters > 0 ? peak : Peak(
                            id: peak.id, name: peak.name,
                            latitude: peak.latitude, longitude: peak.longitude,
                            elevationMeters: Double(hi.elev).rounded(),
                            prominenceMeters: peak.prominenceMeters)
                        res[i] = .init(
                            peak: labeled,
                            direction: SIMD3<Float>(Float(east), Float(north), Float(placedUp)),
                            distanceMeters: horiz,
                            isWater: isWater)
                    }
                }
            }
            let all = results.compactMap { $0 }
            let occludedCount = verdicts.lazy.filter { $0 == Verdict.occluded.rawValue }.count
            let floatingCount = verdicts.lazy.filter { $0 == Verdict.floating.rawValue }.count
            let inRangeCount = occludedCount + floatingCount + all.count
            NSLog("Occlusion: %d in-range, %d occluded, %d floating, %d shown",
                  inRangeCount, occludedCount, floatingCount, all.count)
            // Cap peaks and lakes separately so lake country can't crowd out summits
            // (and vice versa). Peaks rank by prominence/elevation (a distant giant
            // SHOULD label); lakes rank DISTANCE-WEIGHTED — elevation alone made the
            // cap a lottery among hundreds of equal-height alpine tarns, dropping the
            // one right below the viewer in favor of look-alikes 80 km out.
            var peaksOut = all.filter { !$0.isWater }
            var lakesOut = all.filter { $0.isWater }
            peaksOut.sort { $0.peak.priority > $1.peak.priority }
            let lakesShown = lakesOut.count
            lakesOut.sort {
                $0.peak.priority / max(1, $0.distanceMeters) >
                $1.peak.priority / max(1, $1.distanceMeters)
            }
            if peaksOut.count > 400 { peaksOut = Array(peaksOut.prefix(400)) }
            if lakesOut.count > 200 { lakesOut = Array(lakesOut.prefix(200)) }
            if labelDebug {
                NSLog("labelDebug lakes: %d visible, %d kept after cap", lakesShown, lakesOut.count)
            }
            // The visible set is PRE-cap: a summit that lost the label lottery is
            // still line-of-sight visible, and the info card should say so.
            return (peaksOut + lakesOut, Set(all.map(\.peak.id)))
        }

        /// March the DEM along the eye→summit bearing; if any nearer terrain rises
        /// above the sightline to the summit, the peak is occluded.
        ///
        /// PRECISION: the step is kept ≤ ~0.8 of the DEM cell at the current distance
        /// (≈30 m in the near tier, ≈90 m in the far tier). The old fixed 120 m cap
        /// over-stepped the 30 m near grid by ~4 cells in the 10–40 km band, marching
        /// clean over intervening ridges and leaving occluded peaks visible. Sampling
        /// at sub-cell spacing means no ridge between two samples can be missed.
        /// Debug: `-labelDebug` logs every cull (with the blocking terrain for
        /// occlusions) for anchors within 10 km — for diagnosing missing labels.
        static let labelDebug = ProcessInfo.processInfo.arguments.contains("-labelDebug")

        // (The old CPU line-of-sight ray march for PEAKS is gone: their occlusion
        // reads the renderer's own hit-distance panorama in buildAnchors — one
        // lookup per feature, always in agreement with the drawn image. WATER gets
        // a dedicated march below: the depth lookup fundamentally can't judge a
        // LOW point — see the isWater branch in buildAnchors.)

        /// True when intermediate terrain rises above the sightline from the eye
        /// to a water-surface point. Same apparent-height math as the anchors
        /// (heightScale + curvature drop), sampled at ≤ cell spacing, so the
        /// verdict matches the drawn terrain. The final 150 m before the lake are
        /// skipped (its own shore cells sit ± a DEM cell around water height and
        /// would self-occlude), as are the first 60 m (the eye's own crest —
        /// `summitSnappedEye` guarantees nothing above the eye within ~45 m).
        private static func waterSightlineOccluded(
            eyeLat: Double, eyeLon: Double, featLat: Double, featLon: Double,
            horiz: Double, apparentUp: Double, camElevMeters: Double,
            heightScale: Double, curvatureK: Double, dem: DEMTile, far: DEMTile?
        ) -> Bool {
            let sightSlope = apparentUp / horiz
            // Tolerance ≈ 0.05° of grazing slack: DEM noise on a long skimming
            // sightline must not flip a genuinely visible lake to hidden.
            let slack = 8e-4
            let stop = horiz - 150
            var d = 60.0
            guard stop > d else { return false }        // basically at the lake
            while d < stop {
                let f = d / horiz
                let sLat = eyeLat + (featLat - eyeLat) * f
                let sLon = eyeLon + (featLon - eyeLon) * f
                let inNear = dem.contains(lat: sLat, lon: sLon)
                let tile: DEMTile? = inNear ? dem : far
                if let tile, tile.contains(lat: sLat, lon: sLon) {
                    let up = Double(tile.elevation(lat: sLat, lon: sLon)) * heightScale
                        - curvatureK * d * d - camElevMeters
                    if up / d > sightSlope + slack { return true }
                }
                d += inNear ? 36 : 110                  // ≈ a cell per tier
            }
            return false
        }

        private func bundledTile() -> DEMTile? {
            if let cached = bundledTileCache { return cached }
            guard let url = Bundle.main.url(forResource: "cascades", withExtension: "dembin"),
                  let tile = try? DEMTile.loadCached(binPath: url.path) else { return nil }
            bundledTileCache = tile
            return tile
        }

        private func report(_ status: PanoramaViewModel.Status) {
            let cb = onStatus
            DispatchQueue.main.async { cb(status) }
        }

        private static func ms(since t0: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        }

        // MARK: Bake

        /// Bake the panorama off the main thread. FIRST image: a fast low-res pass
        /// installs something usable immediately, then full-res swaps in silently.
        /// RE-BAKES (teleport, exaggeration): the current full-res scene stays on
        /// screen — labels and all — until the new FULL-res image is ready, then
        /// everything swaps at once. The old quick pass painted the new place
        /// blurry for a beat, and the half-swapped state let stale labels float
        /// over the wrong terrain. A generation token discards a stale bake if a
        /// newer viewpoint/exaggeration has been requested.
        ///
        /// The readout sweeps `progressFrom → 0.95` on real band completions
        /// (32+ ticks at full res), holds at 0.95 while the label anchors land,
        /// and `.ready` closes it out — pass 0.85 after a tile fetch so the bar
        /// continues where the tiles left off, 0 when there was no tile phase.
        private func bakeProgressive(progressFrom: Double, onReady: @escaping () -> Void) {
            guard let renderer = renderer, dem != nil else { onReady(); return }
            bakeGeneration &+= 1
            let gen = bakeGeneration
            let t0 = DispatchTime.now()
            let span = 0.95 - progressFrom
            report(.rendering(progress: progressFrom))
            let onBand: (Double) -> Void = { [weak self] f in
                guard let self, gen == self.bakeGeneration else { return }
                self.report(.rendering(progress: progressFrom + span * f))
            }
            if panoInstalled {
                rebakePending = true
                pendingPanoTex = nil
                pendingAnchors = nil
                pendingOnReady = onReady
                // The new labels compute concurrently with the bake (they render
                // their own depth map from the new uniforms, independent of the
                // displayed image); `installAnchors` stashes the result and the
                // swap fires once BOTH image and labels are ready.
                rebuildLabelAnchors()
                renderer.panoramaWidth = Self.fullPanoramaWidth
                bakeOnce(onProgress: onBand) { [weak self] tex in
                    guard let self else { return }
                    guard gen == self.bakeGeneration else { return }  // superseded: the newer bake swaps
                    guard let tex else {
                        // Bake failed (e.g. backgrounded mid-bake): keep the old
                        // scene WHOLE — drop the new-viewpoint anchors too (they'd
                        // float over the old image) — and retry on foreground.
                        self.anchorRebuildWork?.cancel()
                        self.labelGeneration &+= 1
                        self.pendingAnchors = nil
                        self.pendingOnReady = nil
                        self.rebakePending = false
                        self.needsRebakeOnActivate = true
                        onReady()
                        return
                    }
                    self.pendingPanoTex = tex
                    NSLog("Full bake (w=%d) %.0f ms — %@", Self.fullPanoramaWidth,
                          Self.ms(since: t0),
                          self.pendingAnchors == nil ? "waiting for labels" : "swapping with labels")
                    self.maybeCompleteSwap()
                }
                return
            }
            renderer.panoramaWidth = Self.quickPanoramaWidth
            bakeOnce(onProgress: onBand) { [weak self] tex in
                guard let self, gen == self.bakeGeneration else { onReady(); return }
                guard let tex, let renderer = self.renderer else {
                    self.needsRebakeOnActivate = true                 // retry on foreground
                    onReady()
                    return
                }
                renderer.installPanorama(tex)
                self.panoInstalled = true
                self.view?.setNeedsDisplay()                 // usable image now
                onReady()
                self.rebuildLabelAnchors()
                NSLog("Quick bake (w=%d) %.0f ms", Self.quickPanoramaWidth, Self.ms(since: t0))
                let t1 = DispatchTime.now()
                renderer.panoramaWidth = Self.fullPanoramaWidth
                self.bakeOnce { tex in
                    guard gen == self.bakeGeneration else { return }
                    guard let tex else {
                        // Quick pano is on screen but stuck low-res: redo on foreground.
                        self.needsRebakeOnActivate = true
                        return
                    }
                    renderer.installPanorama(tex)            // swap in the crisp pano
                    self.view?.setNeedsDisplay()
                    NSLog("Full bake (w=%d) %.0f ms", Self.fullPanoramaWidth, Self.ms(since: t1))
                }
            }
        }

        private func bakeOnce(onProgress: ((Double) -> Void)? = nil,
                              _ done: @escaping (MTLTexture?) -> Void) {
            guard let renderer = renderer, dem != nil else { done(nil); return }
            var u = makeUniforms(width: 1, height: 1)
            dem?.applyDEMUniforms(to: &u, refLat: refLat, refLon: refLon)
            // Far tier overrides globalMaxHeight (it spans the whole scene).
            demFar?.applyFarDEMUniforms(to: &u, refLat: refLat, refLon: refLon)
            renderer.bakePanoramaAsync(uniforms: u, onProgress: onProgress, completion: done)
        }

        private func makeUniforms(width: Int, height: Int) -> Uniforms {
            var camera = PanoramaCamera(
                position: SIMD3<Float>(0, 0, camElev),
                azimuthDegrees: azimuth,
                pitchDegrees: pitch,
                verticalFovDegrees: fov)
            camera.heightScale = exaggeration
            var u = camera.makeUniforms(width: width, height: height)
            u.skySunDir = SIMD4<Float>(skySunENU, 0)   // live sun → dynamic sky colour
            // In AR, lock the projection's vertical FOV to the real on-screen camera
            // FOV so the overlay tracks the world (no scale drift as you tilt/pan).
            if mode.usesCamera, width > 2, height > 2,
               let tanV = arVerticalTanHalfFov(drawableW: width, drawableH: height) {
                u.tanHalfFovY = tanV
            }
            return u
        }

        /// tan(½ vertical FOV) the live camera actually shows on screen, accounting for
        /// the portrait rotation + `resizeAspectFill` crop. Returns nil until the
        /// camera intrinsics are known.
        ///
        /// The camera is a pinhole with focal length (in image px) `f = (L/2)/tan(Hfov/2)`
        /// where `L` is the long (landscape-horizontal) edge. Rotated to portrait the
        /// image is `short × long`; aspect-fill scales it by `s = max(Ws/short, Hs/long)`
        /// to cover the drawable. The on-screen vertical FOV then spans `Hs/s` image px:
        /// `tan(½Vfov) = (Hs / 2s) / f`.
        private func arVerticalTanHalfFov(drawableW: Int, drawableH: Int) -> Float? {
            guard cameraLongFOVDeg > 1, cameraFormatLong > 0, cameraFormatShort > 0 else { return nil }
            let ws = Float(drawableW), hs = Float(drawableH)
            let long = Float(cameraFormatLong), short = Float(cameraFormatShort)
            let scale = max(ws / short, hs / long)
            let f = (long / 2) / tanf(cameraLongFOVDeg * .pi / 360)   // .pi/360 = (deg→rad)/2
            return (hs / (2 * scale)) / f
        }

        // MARK: Gestures

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            // ANY device-tracked view (AR or 3D): drag nudges a YAW-ONLY calibration
            // offset on top of the live tracking — pitch is gravity-anchored and never
            // meaningfully wrong, and a second drag axis just made horizontal
            // alignment harder. The view keeps following the phone.
            if let basis = deviceBasis, mode.usesCamera || !manualAlignment {
                applyYawDrag(g, in: v, basis: basis)
                return
            }
            // No IMU (simulator / desktop) or explicit manual mode: the finger drag IS
            // the look-around — az + pitch both, since it's the only way to look up.
            guard !mode.usesCamera else { return }
            if !manualAlignment {
                setManualAlignment(true)
                onForceManual()
            }
            if g.state == .began { panStartAz = azimuth; panStartPitch = pitch }
            let t = g.translation(in: v)
            let degPerPoint = fov / Float(v.bounds.height)
            azimuth = panStartAz - Float(t.x) * degPerPoint
            pitch = max(-80, min(80, panStartPitch + Float(t.y) * degPerPoint))
            v.setNeedsDisplay()
        }

        /// Yaw-only drag alignment on top of device tracking. Scaled by the rendered
        /// focal length → 1 finger-point ≈ the angle that point subtends on screen,
        /// so the overlay drags 1:1 with the image (AR uses the real camera FOV).
        ///
        /// The offset lives in WORLD space while the finger moves in SCREEN space —
        /// take the drag's component along the on-screen gravity-RIGHT axis (same
        /// right.z/up.z construction the label overlay uses). Without this, rolling
        /// the phone to landscape broke the mapping: a drag along the horizon didn't
        /// turn the overlay. Level portrait ⇒ gRight=(1,0) ⇒ dxWorld = t.x, exactly
        /// the screen-axis behavior. The vertical drag component is deliberately
        /// discarded.
        private func applyYawDrag(_ g: UIPanGestureRecognizer, in v: MTKView,
                                  basis: DeviceAttitude.Basis) {
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            let tanHalfV: Double = mode.usesCamera
                ? Double(arVerticalTanHalfFov(drawableW: Int(v.bounds.width),
                                              drawableH: Int(v.bounds.height))
                         ?? tanf(fov * .pi / 360))
                : Double(tanf(fov * .pi / 360))
            let focalPoints = Double(v.bounds.height) / 2 / max(1e-4, tanHalfV)
            let pointsPerDeg = focalPoints * .pi / 180
            var dxWorld = Double(t.x)
            let gLen = hypot(Double(basis.right.z), Double(basis.up.z))
            if gLen > 0.2 {                     // gravity direction well-defined on screen
                let gUpX = Double(basis.right.z) / gLen, gUpY = -Double(basis.up.z) / gLen
                dxWorld = -Double(t.x) * gUpY + Double(t.y) * gUpX   // t · (gUp rotated +90°)
            }
            // Grab-the-world: drag right ⇒ overlay moves right (camera yaws left).
            arYawOffsetDeg += -dxWorld / pointsPerDeg
            reportARAdjusted()
            v.setNeedsDisplay()
        }

        /// Apply the AR calibration offset to the live device basis: yaw about world-up
        /// (Z) — roll-independent, keeps the horizon level.
        private func arCalibrated(_ b: DeviceAttitude.Basis) -> DeviceAttitude.Basis {
            if arYawOffsetDeg == 0 { return b }
            // +yaw offset = +azimuth (clockwise from north); a +Z rotation DECREASES
            // clockwise azimuth, so rotate by -offset about +Z.
            let qYaw = simd_quatf(angle: Float(-arYawOffsetDeg * .pi / 180), axis: SIMD3(0, 0, 1))
            return DeviceAttitude.Basis(forward: qYaw.act(b.forward),
                                        right: qYaw.act(b.right),
                                        up: qYaw.act(b.up))
        }

        /// Clear the AR adjustment (back to pure device tracking).
        func recenterAR() {
            guard arYawOffsetDeg != 0 else { return }
            arYawOffsetDeg = 0
            reportARAdjusted()
            view?.setNeedsDisplay()
        }

        /// RootScreen bumps a token to request a recenter (one-way action input).
        func setARRecenterToken(_ token: Int) {
            guard token != arRecenterToken else { return }
            arRecenterToken = token
            recenterAR()
        }

        private func reportARAdjusted() {
            let adjusted = (arYawOffsetDeg != 0)
            guard adjusted != lastReportedARAdjusted else { return }
            lastReportedARAdjusted = adjusted
            let cb = onARAdjustedChanged
            DispatchQueue.main.async { cb(adjusted) }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let v = view else { return }
            // In AR the FOV is locked to the physical camera (no optical zoom), so a
            // pinch must not change it — that would desync the overlay from the world.
            guard !mode.usesCamera else { return }
            if g.state == .began { pinchStartFov = fov }
            fov = max(15, min(90, pinchStartFov / Float(g.scale)))
            v.setNeedsDisplay()
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let overlay = container?.labelOverlay else { return }
            let pt = g.location(in: overlay)
            // Peaks take priority; then a sky object (star/planet/sun/moon) shows a
            // small name tag; an empty tap clears both.
            if let peak = overlay.peak(at: pt) {
                container?.skyArc.selectedSkyName = nil
                onSelectPeak(peak)
                return
            }
            if let name = container?.skyArc.skyObjectName(at: pt) {
                container?.skyArc.selectedSkyName = name
                onSelectPeak(nil)
                view?.setNeedsDisplay()
                return
            }
            container?.skyArc.selectedSkyName = nil
            onSelectPeak(nil)
        }

        func setSelectedPeak(_ annotated: AnnotatedPeak?) {
            guard annotated?.id != selectedPeakID else { return }
            selectedPeakID = annotated?.id
            container?.labelOverlay.selectedPeakID = annotated?.id
            // Direction marker (az/el/distance fully define the screen direction, so no
            // DEM lookup needed): shown by the overlay only when the peak isn't already
            // an on-screen label.
            container?.labelOverlay.target = annotated.map { a in
                let az = a.azimuthDeg * .pi / 180, el = a.elevationAngleDeg * .pi / 180
                let dist = max(1, a.distanceMeters)
                return PeakLabelOverlayView.Target(
                    id: a.id, name: a.peak.name,
                    direction: SIMD3<Float>(Float(dist * sin(az)), Float(dist * cos(az)),
                                            Float(dist * tan(el))),
                    distanceText: UnitText.distance(meters: a.distanceMeters))
            }
            view?.setNeedsDisplay()        // re-project to refresh the highlight + marker
        }

        // MARK: Render

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let renderer = renderer,
                  let drawable = view.currentDrawable else { return }
            let w = Int(view.drawableSize.width)
            let h = Int(view.drawableSize.height)
            guard w > 0, h > 0 else { return }

            // Pull the freshest device attitude for THIS frame (zero queuing lag).
            if motionDrivesCamera { sampleDeviceBasis() }

            var uniforms = makeUniforms(width: w, height: h)
            // Device alignment overrides the az/pitch basis with the live device
            // orientation (the bake is orientation-independent, so only the per-frame
            // resample changes). Every device-tracked view (AR and 3D) also applies
            // the drag calibration yaw offset; 3D falls back to gestures only when
            // manual look-around is on (no-IMU environments).
            if let basis = deviceBasis, mode.usesCamera || !manualAlignment {
                let b = arCalibrated(basis)
                uniforms.forward = SIMD4<Float>(b.forward, 0)
                uniforms.right = SIMD4<Float>(b.right, 0)
                uniforms.up = SIMD4<Float>(b.up, 0)
            }
            guard let cb = renderer.commandQueue.makeCommandBuffer() else { return }
            // While an AR mode is warming up the camera, keep drawing the opaque 3D
            // scene so nothing flashes black; switch to the real AR pass on reveal.
            let effectiveMode: TerrainViewMode =
                (mode.usesCamera && !cameraRevealed) ? .threeD : mode
            switch effectiveMode {
            case .threeD:
                renderer.encodeView(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
            case .arRelief:
                renderer.encodeViewAR(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
            case .arEdges:
                renderer.encodeViewEdges(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
            case .arLabels:
                renderer.encodeClearTransparent(into: drawable.texture, commandBuffer: cb)
            }
            cb.present(drawable)
            cb.commit()
            reportHUD(forward: uniforms.forward)

            // Project peak labels with the EXACT basis/FOV the GPU just used, so they
            // land on the rendered summits and track as the view moves.
            let fwd = SIMD3<Float>(uniforms.forward.x, uniforms.forward.y, uniforms.forward.z)
            let rgt = SIMD3<Float>(uniforms.right.x, uniforms.right.y, uniforms.right.z)
            let upv = SIMD3<Float>(uniforms.up.x, uniforms.up.y, uniforms.up.z)
            container?.skyArc.project(forward: fwd, right: rgt, up: upv,
                                      tanHalfFovY: uniforms.tanHalfFovY, aspect: uniforms.aspect)
            // True magnification = base-FOV tan ratio over the FOV actually rendered
            // (so AR uses the camera's real FOV, not the stale `fov`).
            let baseTanHalf = tanf(60.0 * .pi / 360)
            let zoom = baseTanHalf / max(1e-4, uniforms.tanHalfFovY)
            container?.labelOverlay.project(forward: fwd, right: rgt, up: upv,
                                            tanHalfFovY: uniforms.tanHalfFovY, aspect: uniforms.aspect,
                                            zoom: zoom)
            var headingDeg = atan2(Double(fwd.x), Double(fwd.y)) * 180 / .pi
            if headingDeg < 0 { headingDeg += 360 }
            container?.compassZoom.update(headingDeg: headingDeg, zoom: Double(zoom))
        }

        /// Push throttled heading (compass) and zoom (×) to the HUD. ~15 Hz, and
        /// only on a meaningful change, so SwiftUI isn't churned every frame.
        private func reportHUD(forward: SIMD4<Float>) {
            var heading = atan2(Double(forward.x), Double(forward.y)) * 180 / .pi
            if heading < 0 { heading += 360 }
            let zoom = 60.0 / max(1.0, Double(fov))   // base FOV 60° = 1.0×
            let now = CACurrentMediaTime()
            if now - lastHeadingReport > 0.066,
               lastHeading.isNaN || headingDelta(heading, lastHeading) >= 0.5 {
                lastHeading = heading
                lastHeadingReport = now
                let cb = onHeading
                DispatchQueue.main.async { cb(heading) }
            }
            if lastZoom.isNaN || abs(zoom - lastZoom) >= 0.02 {
                lastZoom = zoom
                let cb = onZoom
                DispatchQueue.main.async { cb(zoom) }
            }
        }

        private func headingDelta(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d
        }
    }
}
