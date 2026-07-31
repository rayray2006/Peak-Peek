import SwiftUI
import MetalKit
import simd
import CoreMotion
import CoreLocation
@preconcurrency import AVFoundation

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
    /// Timezone for on-scene time text (the sky-arc ↑/↓ rise/set tags): the
    /// VIEWED location's resolved zone from the model — DST-correct, unlike
    /// the longitude approximation it replaces.
    var displayTimeZone: TimeZone = .current
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
    /// User-saved custom spots (`loc_…`) to label as yellow look-around dots.
    var savedSpots: [Peak] = []
    /// Currently selected peak (highlighted; also shown as an accent direction marker when
    /// off-view), and the tap callback (nil = a tap that hit no label).
    var selectedPeak: AnnotatedPeak?
    /// Labels pinned open by taps — their name capsules stay up at any zoom
    /// (only `selectedPeak` gets the highlight ring + direction marker).
    var pinnedPeakIDs: Set<String> = []
    var onSelectPeak: (Peak?) -> Void = { _ in }
    /// Fired whenever label anchors are rebuilt: the ids of every feature with a
    /// clear line of sight from the current viewpoint (peaks + lakes). Anything
    /// absent is occluded by terrain, out of range, or behind the horizon.
    var onVisibleFeatures: (Set<String>) -> Void = { _ in }
    /// Fired when the DEM tiles install (near, far) — the model keeps them so
    /// UI features (search elevation fill) can sample terrain heights.
    var onDEMTiles: (DEMTile?, DEMTile?) -> Void = { _, _ in }
    /// Fired per celestial rebuild: true sunrise/sunset + the ridge-visibility
    /// window for the displayed day at this viewpoint (drives the Time card).
    var onSunTimes: (PanoramaViewModel.SunTimes?) -> Void = { _ in }
    var onStatus: (PanoramaViewModel.Status) -> Void = { _ in }
    var onEyeElevation: (Double?) -> Void = { _ in }
    /// Fired when the view force-switches to manual (no IMU) so the HUD can match.
    var onForceManual: () -> Void = { }
    /// Incremented by the HUD's "Recenter" button to clear the AR drag calibration.
    var arRecenterToken: Int = 0
    /// Incremented by the switching card's ✕: abandon the in-flight viewpoint
    /// move (the model re-requests the previous spot in the same update).
    var cancelMoveToken: Int = 0
    /// Fired when an AR drag calibration becomes active / is cleared (drives the HUD).
    var onARAdjustedChanged: (Bool) -> Void = { _ in }
    /// Fired at the END of every alignment-changing drag (yaw calibration or
    /// manual look-around) — the HUD re-introduces its Realign button on each.
    var onAlignmentNudged: () -> Void = { }
    /// The DISPLAYED sky just crossed day↔night (fires in the same beat the
    /// live sun applies: scene swaps and time scrubs alike). Drives the Auto
    /// theme with zero lag — sunrise/sunset times arrive seconds later from
    /// the async celestial pass and are not needed for this.
    var onNightChanged: (Bool) -> Void = { _ in }
    /// Changes when the ft↔m preference flips — the label overlay re-bakes
    /// its elevation strings.
    var unitsStamp: String = ""
    /// Changes when the 12h↔24h preference flips — the sky overlay re-formats
    /// its rise/set (↑/↓) time tags.
    var clockStamp: String = ""
    /// Immersive view (empty tap): RootScreen hides its chrome; the compass +
    /// zoom readout live inside this view, so they're hidden here.
    var immersive: Bool = false
    /// Fired on a single tap that hit NO feature (no label dot, no sky
    /// object). RootScreen arbitrates: a tap with something dismissible open
    /// dismisses it; only a truly idle tap toggles immersive. The Bool says
    /// this tap already cleared a sky-object name tag (that counts as
    /// dismissing something).
    var onEmptyTap: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus, onEyeElevation: onEyeElevation,
                    onForceManual: onForceManual)
    }

    func makeUIView(context: Context) -> TerrainContainerView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = TerrainRenderer.colorFormat
        view.framebufferOnly = true
        view.isPaused = true                 // draw on demand (fixed viewpoint)
        view.enableSetNeedsDisplay = true
        // Present the drawable INSIDE the CoreAnimation transaction (with the
        // explicit commit → waitUntilScheduled → present in draw(in:)): the
        // label/sky overlays are CALayers positioned in the same runloop turn
        // as the render, and without this they reached the screen ~a frame
        // after the Metal image — the dots visibly drifted over the terrain
        // while the phone moved, snapping back at rest.
        view.presentsWithTransaction = true
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        context.coordinator.configure(view: view)

        // Device orientation drives looking around; pinch zooms. Touch-drag is a
        // fallback only where there's no IMU (simulator / macOS).
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        // Pan is always available now (manual-alignment look-around); it only moves
        // the view when manual alignment is on, or as the no-IMU fallback. On
        // device-tracked views the one-finger drag is the ALIGN drag: axis-
        // locked to yaw (horizontal) or pitch trim (vertical), never both.
        // Capped at one finger so pinch can't also drive it.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        // One single-tap recognizer for everything: label/sky selection when
        // the tap lands on a feature, and (via onEmptyTap) dismiss-or-immersive
        // when it doesn't — RootScreen decides which, since it owns the
        // menus/cards a tap might be dismissing. The old separate double-tap
        // recognizer for immersive is gone; selection stays instant because
        // nothing waits on a double-tap window.
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
        context.coordinator.onForceManual = onForceManual
        context.coordinator.onARAdjustedChanged = onARAdjustedChanged
        context.coordinator.onAlignmentNudged = onAlignmentNudged
        context.coordinator.onNightChanged = onNightChanged
        context.coordinator.setExaggeration(Float(exaggeration))
        context.coordinator.setDisplayDate(displayDate)
        context.coordinator.setDisplayTimeZone(displayTimeZone)
        context.coordinator.setManualAlignment(manualAlignment)
        context.coordinator.setMode(mode)
        context.coordinator.setARRecenterToken(arRecenterToken)
        context.coordinator.onEmptyTap = onEmptyTap
        context.coordinator.setImmersive(immersive)
        context.coordinator.setPeaks(peaks)
        context.coordinator.setLakes(lakes)
        context.coordinator.setSavedSpots(savedSpots)
        context.coordinator.setLabelDensity(labelDensity)
        context.coordinator.setUnitsStamp(unitsStamp)
        context.coordinator.setClockStamp(clockStamp)
        context.coordinator.setSavedPeaks(climbed: climbedPeakIDs, bookmarked: bookmarkedPeakIDs)
        context.coordinator.onSelectPeak = onSelectPeak
        context.coordinator.onVisibleFeatures = onVisibleFeatures
        context.coordinator.onDEMTiles = onDEMTiles
        context.coordinator.onSunTimes = onSunTimes
        context.coordinator.setSelectedPeak(selectedPeak)
        context.coordinator.setPinnedPeaks(pinnedPeakIDs)
        // BEFORE the viewpoint resubmission below: a cancel arrives in the
        // same update pass as the model's revert-teleport, and the abandoned
        // move must be dropped before the old spot is re-requested.
        context.coordinator.setCancelMoveToken(cancelMoveToken)
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
            // No scale factor: AR is locked to the camera's native 1x — the
            // feed is displayed exactly as the lens delivers it (see setMode).
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
        private var dem: DEMTile?
        /// Coarse, wide-coverage far tile (≈120 km). Renders + labels distant ranges
        /// the high-res near tile (≈40 km, native ~30 m) doesn't reach.
        /// (The textures themselves live on the renderer: heightTexture/farHeightTexture.)
        private var demFar: DEMTile?

        /// Near (high-res) and far (coarse) DEM fetch radii + grid caps.
        /// The far tile reaches `FarHorizon.farTileMeters` — real raymarched
        /// terrain out to 160 km, so much less of the view is the hazy ring.
        private static let nearRadius = 40_000.0, farRadius = FarHorizon.farTileMeters
        private static let nearMaxGrid = 9000, farMaxGrid = 4096
        private weak var view: MTKView?
        var onStatus: (PanoramaViewModel.Status) -> Void
        var onEyeElevation: (Double?) -> Void
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
        private var displayTimeZone = TimeZone.current
        func setDisplayTimeZone(_ tz: TimeZone) {
            guard tz != displayTimeZone else { return }
            displayTimeZone = tz
            rebuildCelestial()   // the rise/set tags carry formatted times
        }
        private var cachedHorizon: [Float]?
        /// The `farProfileGen` (ring generation) `cachedHorizon` was built against
        /// — so a celestial pass can record which ring its star-occlusion reflects.
        private var cachedHorizonRingGen = 0
        /// Real sun direction (ENU) at `displayDate`, for the dynamic sky colour.
        /// Sun for the DISPLAYED panorama — drives the live sky colour. On a
        /// location change this holds the OLD location's sun until the new
        /// panorama installs, so sky and terrain swap in the same frame.
        private var skySunENU = SIMD3<Float>(0, 0, 1)
        /// Sun for the IN-FLIGHT bake (new viewpoint/date): the bake lights
        /// with this; it becomes `skySunENU` the moment its panorama installs.
        private var bakeSunENU = SIMD3<Float>(0, 0, 1)
        /// Viewpoint the CURRENTLY APPLIED sky-overlay content (stars/arcs/
        /// discs) was computed for. Lets a panorama swap detect that the
        /// overlay still shows another location's sky — the new scene's
        /// celestial pass (horizon march + ephemeris, CPU) can lose the race
        /// against the GPU bake, and without this check the old stars kept
        /// shining through the new terrain until that pass landed.
        private var celestialRef: (lat: Double, lon: Double)?
        /// The ring generation (`farProfileGen`) the CURRENTLY displayed celestial
        /// content was culled against. The far-horizon ring lands mid-move and
        /// tops the panorama up with distant silhouettes — a SAME-location re-bake,
        /// so the lat/lon staleness guard alone keeps the pre-ring stars, which
        /// were occluded against a ring-less horizon and then shine THROUGH the
        /// newly drawn far ridges. Comparing this at the swap clears them.
        private var celestialRingGen = -1
        /// Stamped with the viewpoint it was computed FOR: a reload-window
        /// rebuild can still describe the OLD location (a live-clock tick
        /// firing before the new DEM installs refLat/refLon), and applying
        /// that at the swap overwrote the fresh sky sun with the old one —
        /// the "wrong sky for a second after a teleport" flash.
        /// Celestial overlay content (stars/arcs/discs) computed for a scene
        /// that hasn't installed yet — applied atomically with the swap.
        private var pendingCelestialApply: (lat: Double, lon: Double, ringGen: Int, run: () -> Void)?

        /// Run the held celestial content if it matches the CURRENT viewpoint;
        /// drop it if it was computed for another one (the real content for
        /// this scene lands moments later and applies directly).
        private func applyPendingCelestialIfCurrent() {
            defer { pendingCelestialApply = nil }
            guard let pending = pendingCelestialApply,
                  abs(pending.lat - refLat) < 1e-6, abs(pending.lon - refLon) < 1e-6
            else { return }
            pending.run()
        }
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
        /// AR PITCH trim (degrees, + = look up): the align drag's VERTICAL
        /// axis (one finger, axis-locked — see applyAlignDrag), for when
        /// elevation-data error at the eye (SRTM canopy bias, GPS sampling a
        /// steep slope) leaves the whole overlay sitting slightly above/below
        /// the real terrain. Clamped to ±8° — a trim, not look-around.
        /// Cleared with the yaw offset by `recenterAR()`.
        private var arPitchOffsetDeg: Double = 0
        private var arRecenterToken = 0
        /// Reports whether a non-zero AR adjustment is currently applied (drives the
        /// "Recenter" button + orange menu icon).
        var onARAdjustedChanged: (Bool) -> Void = { _ in }
        var onAlignmentNudged: () -> Void = { }
        var onNightChanged: (Bool) -> Void = { _ in }
        private var lastReportedNight: Bool?

        /// Report day↔night from the LIVE sun's elevation (z = sin el; night
        /// below ~-0.833°, the refraction-corrected sunset). Called wherever
        /// `skySunENU` is (re)applied, so the theme flips in the SAME beat as
        /// the sky it describes. Async dispatch: call sites run inside view
        /// updates.
        private func reportNight() {
            let night = skySunENU.z < Float(sin(-0.833 * Double.pi / 180))
            guard night != lastReportedNight else { return }
            lastReportedNight = night
            let cb = onNightChanged
            DispatchQueue.main.async { cb(night) }
        }
        private var lastReportedARAdjusted = false

        // Peak labels.
        private var peaks: [Peak] = []
        private var lakes: [Peak] = []
        private var savedSpots: [Peak] = []
        private var labelGeneration = 0
        var onSelectPeak: (Peak?) -> Void = { _ in }
        var onVisibleFeatures: (Set<String>) -> Void = { _ in }
        var onDEMTiles: (DEMTile?, DEMTile?) -> Void = { _, _ in }
        var onSunTimes: (PanoramaViewModel.SunTimes?) -> Void = { _ in }
        var onEmptyTap: (Bool) -> Void = { _ in }
        private var selectedAnnotated: AnnotatedPeak?

        // Viewpoint bookkeeping.
        private var lastRequested: (lat: Double, lon: Double)?
        /// Set by "Stand here": once the DEM is in, move the eye to the true summit.
        private var pendingSummitSnap = false
        private var isReloading = false
        /// The last coordinate whose load FAILED, with when — gates the
        /// passive re-request loop (see requestViewpoint).
        private var lastFailedRequest: (lat: Double, lon: Double, at: Date)?
        /// The latest viewpoint requested while a reload was in flight; run when
        /// the current bake settles instead of being silently dropped.
        private var queuedRequest: (lat: Double, lon: Double, snap: Bool)?
        /// Generation stamp for viewpoint moves: every requestViewpoint bumps
        /// it, and every completion (fetch install, failure report, bake
        /// onReady, progress tick) is guarded on it — so a cancelled or
        /// superseded move's late completions drop silently instead of
        /// installing tiles, flipping status, or re-animating progress.
        private var moveGeneration = 0
        private var cancelMoveToken = 0
        /// The dedupe memory as it stood before the in-flight move — restored
        /// on a mid-fetch cancel so the revert-teleport's resubmission of the
        /// still-displayed spot dedupes to a no-op instead of re-baking it.
        private var requestBeforeMove: (lat: Double, lon: Double)?
        /// True once the in-flight move has retargeted scene state (refLat,
        /// ground, sky). Fetch moves stay false until install; reuse-fast-path
        /// moves flip immediately — that's the case a cancel must re-bake.
        private var moveMutatedScene = false

        /// The switching card's ✕: abandon the in-flight move. The scene on
        /// screen still shows the PREVIOUS viewpoint (a new panorama only
        /// installs when its bake completes), so cancelling means dropping the
        /// pending work — the generation bumps orphan the in-flight fetch and
        /// bake — and settling back into the old scene.
        func setCancelMoveToken(_ token: Int) {
            guard token != cancelMoveToken else { return }
            cancelMoveToken = token
            guard isReloading else { return }
            moveGeneration &+= 1
            bakeGeneration &+= 1
            queuedRequest = nil
            isReloading = false
            if moveMutatedScene {
                // The move already retargeted the scene state (a reuse-move
                // mid-bake): the model's revert-teleport (same update pass)
                // must re-request and re-bake the old spot.
                lastRequested = nil
            } else {
                // Cancelled mid-fetch: nothing was touched — the displayed
                // scene IS the previous viewpoint. Restore the dedupe memory
                // so the revert resubmission no-ops, and stand ready NOW: no
                // re-bake, and no waiting out the orphaned fetch's stitch
                // (which starves the cores for seconds after a heavy cancel).
                lastRequested = requestBeforeMove
                report(.ready)
                onEyeElevation(Double(groundElev) + 1.6)
            }
        }

        /// Every reload exit path funnels here so a queued mid-bake move is
        /// never lost (main thread only, like all reload state).
        private func finishReload() {
            isReloading = false
            if let q = queuedRequest {
                queuedRequest = nil
                requestViewpoint(lat: q.lat, lon: q.lon, snapToSummit: q.snap)
            } else if ringLandedMidBake {
                // The far-horizon ring arrived after this bake's bands encoded:
                // top the panorama up quietly so distant silhouettes appear.
                // The anchors usually DON'T need redoing: the ring lands within
                // ~ms of the bake starting, so the (0.1 s-debounced) anchor
                // build already snapshotted the current profile — reuse its
                // result rather than re-judging ~30k peaks (~2 s of CPU, and
                // the ring haze waited on it) for an identical set. A build
                // that genuinely predates the ring (stamp mismatch) still gets
                // the full rebuild.
                ringLandedMidBake = false
                let anchorsCurrent = lastAnchorState?.ringStamp == ringGeneration
                NSLog("Ring top-up bake (%@)", anchorsCurrent ? "anchors reused" : "anchors rebuilt")
                bakeProgressive(progressFrom: 0, reportProgress: false,
                                reuseAnchors: anchorsCurrent, paced: true) { self.report(.ready) }
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
        /// Fractional byte progress of tiles still in flight (keyed by tile
        /// name); a tile's entry clears when its completion unit ticks.
        private var loadPartialDownloads: [String: Double] = [:]

        /// Combined download+stitch readout: whole units plus in-flight bytes.
        private func reportLoadProgress() {
            guard loadUnitsTotal > 0 else { return }
            let partial = loadPartialDownloads.values.reduce(0, +)
            let fraction = min(1, (Double(loadUnitsDone) + partial) / Double(loadUnitsTotal))
            report(.preparingTerrain(progress: Self.loadShare * fraction))
        }
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
        /// The staged anchors are the SAME set already installed (a reuse top-up):
        /// the swap must NOT reassign them onto the overlay. Reassigning an
        /// identical set still fires `anchors.didSet` → `rebuildPool()`, which
        /// resets the chunked build and re-streams every dot — the "dots flash a
        /// few seconds after open" when the far-horizon ring lands mid-bake.
        private var pendingAnchorsUnchanged = false
        private var pendingOnReady: (() -> Void)?

        private func maybeCompleteSwap() {
            guard let tex = pendingPanoTex,
                  let (anchors, visibleIDs) = pendingAnchors,
                  let renderer else { return }
            pendingPanoTex = nil
            pendingAnchors = nil
            rebakePending = false
            let anchorsUnchanged = pendingAnchorsUnchanged
            pendingAnchorsUnchanged = false
            renderer.installPanorama(tex)
            // Sky joins the swap: the sun the panorama was baked with becomes
            // the live sky sun, the theme flips with it, and any celestial
            // overlay computed for the new scene lands now — terrain, sky
            // colour, theme, labels, stars: one frame.
            skySunENU = bakeSunENU
            reportNight()
            // Held content is only good for THIS swap if it matches the new
            // viewpoint AND was culled against the ring now baked into the
            // panorama — a ring top-up bakes distant silhouettes in, and stars
            // occluded against the pre-ring horizon otherwise shine through them.
            let ringNow = farProfileGen
            if let pending = pendingCelestialApply,
               abs(pending.lat - refLat) < 1e-6, abs(pending.lon - refLon) < 1e-6,
               pending.ringGen == ringNow {
                pending.run()
                pendingCelestialApply = nil
            } else {
                // No content valid for THIS scene yet (none, wrong location, or
                // computed against a stale ring). Drop it and, if the overlay
                // still shows another location's OR a pre-ring sky, clear it so
                // those stars don't shine through the new terrain; the correct
                // pass (already scheduled) applies a beat later.
                pendingCelestialApply = nil
                if let ref = celestialRef,
                   abs(ref.lat - refLat) > 1e-6 || abs(ref.lon - refLon) > 1e-6
                    || celestialRingGen != ringNow {
                    container?.skyArc.clearCelestial()
                    celestialRef = nil
                    celestialRingGen = -1
                }
            }
            // Reused anchors are already on the overlay and unchanged — leave its
            // dots untouched (reassigning would rebuild the pool and flash them).
            if !anchorsUnchanged {
                container?.labelOverlay.anchors = anchors
                onVisibleFeatures(visibleIDs)
            }
            view?.setNeedsDisplay()
            // Capture-then-clear, in that order: the completion below runs
            // finishReload, which starts a QUEUED move synchronously — and that
            // move's bakeProgressive stores ITS onReady into `pendingOnReady`.
            // Clearing after the call wiped the new move's completion, so its
            // swap later landed with no one to report .ready — the "Switching
            // location" card then hung forever and every further move queued
            // behind the stuck isReloading (chained-teleport soft lock).
            let onReady = pendingOnReady
            pendingOnReady = nil
            onReady?()
        }
        private var bundledTileCache: DEMTile?

        init(onStatus: @escaping (PanoramaViewModel.Status) -> Void,
             onEyeElevation: @escaping (Double?) -> Void,
             onForceManual: @escaping () -> Void) {
            self.onStatus = onStatus
            self.onEyeElevation = onEyeElevation
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
            // A depth pass that failed in the background re-judges label
            // visibility now (a full rebake below covers it on its own).
            if anchorRetryOnActivate {
                anchorRetryOnActivate = false
                if !needsRebakeOnActivate { rebuildLabelAnchors() }
            }
            guard needsRebakeOnActivate else { return }
            needsRebakeOnActivate = false
            guard dem != nil else { return }
            bakeProgressive(progressFrom: 0) { [weak self] in
                guard let self else { return }
                self.report(.ready)
                self.finishReload()
            }
        }

        /// Panorama bake resolution (every bake runs at full resolution; the old
        /// quick 2048 preview pass is gone — see `bakeProgressive`).
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

        /// Debug (-continuousRender): force the every-vsync render loop in the
        /// SIMULATOR (no gyro → on-demand there), so frame-pacing measurements
        /// (-frameWatch) exercise the same continuous draw path a real device
        /// runs while the user looks around.
        private static let forceContinuousRender =
            ProcessInfo.processInfo.arguments.contains("-continuousRender")

        /// Continuous rendering while the device attitude drives the camera (so `draw`
        /// pulls a fresh sample every vsync); on-demand otherwise to save power.
        func syncRenderLoop() {
            guard let v = view else { return }
            let live = motionDrivesCamera || Self.forceContinuousRender
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
            // Camera modes anchor dots at the TRUE summits (catalog height,
            // unclamped): the reference is the real mountain, not the drawn
            // DEM crest — which loses sharp spire tops (see buildAnchors).
            container?.labelOverlay.usesTrueSummits = usesCamera
            // Stars only belong to the 3D panorama — over the live camera the
            // real sky is already there and painted points read as noise.
            container?.skyArc.showsStars = (newMode == .threeD)
            // AR is locked to the camera's native 1x lens — no user zoom, so drop
            // the flat "1.0×" readout there and keep it only in the 3D view.
            container?.compassZoom.showsZoom = !usesCamera

            if usesCamera {
                // ARKit path shows its own display layer; AVCapture the preview.
                (usesARKitCamera ? container?.arDisplayLayer : container?.previewLayer)?
                    .isHidden = false             // sits behind the metal view
                if wasCamera {
                    // AR↔AR: camera already streaming + view already transparent.
                    view?.setNeedsDisplay()
                } else {
                    // 3D→AR: hold the opaque 3D view until the first frame lands.
                    setAwaitingFirstFrame(true)
                    cameraRevealed = false
                    // AR is LOCKED to the camera's native 1x magnification. The
                    // old matched digital crop ran TWO implementations of "zoom"
                    // — a CALayer scale on the feed and a divided projection FOV
                    // — whose tiny disagreements (and any principal-point offset
                    // from the assumed center, magnified by the crop factor)
                    // read as world misalignment. At 1x the only geometry is
                    // the lens intrinsics + the aspect-fill crop: one exact
                    // pinhole. The ramp eases the magnification jump from the
                    // 3D view's zoom to the lens.
                    arFovRampFrom = tanf(fov * .pi / 360)
                    arFovRampStart = nil       // starts when the camera FOV is known
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
                // AR→3D: opaque immediately (renders the sky — no gap), drop the
                // camera. AR ran at the locked native 1x, and the 3D fov was
                // never touched while there — ease back from the camera's
                // magnification to the user's own zoom.
                if wasCamera, let v = view,
                   let tanV = arVerticalTanHalfFov(drawableW: Int(v.drawableSize.width),
                                                   drawableH: Int(v.drawableSize.height)) {
                    arFovRampFrom = tanV
                    arFovRampStart = nil
                }
                setAwaitingFirstFrame(false)
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
            setAwaitingFirstFrame(false)
            setMetalOpaque(false)
            view?.setNeedsDisplay()
        }

        /// Write `awaitingFirstFrame` under the pixel-buffer lock: it is set on
        /// main but READ on the video queue (captureOutput below), and the bare
        /// cross-thread Bool was a data race. Main-thread reads stay lock-free
        /// (main is the only writer).
        private func setAwaitingFirstFrame(_ value: Bool) {
            pixelBufferLock.lock()
            awaitingFirstFrame = value
            pixelBufferLock.unlock()
        }

        // Every camera frame: the first one reveals the preview.
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let needsReveal: Bool
            pixelBufferLock.lock()
            needsReveal = awaitingFirstFrame
            pixelBufferLock.unlock()
            guard needsReveal else { return }
            DispatchQueue.main.async { [weak self] in self?.revealCamera() }
        }

        /// Guards `awaitingFirstFrame` (set on main, read on the video queue).
        private let pixelBufferLock = NSLock()

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
                        // Sunrise/sunset blowouts: keep exposure ADAPTING and
                        // turn the format's video HDR on — the fallback path
                        // previously took whatever the preset defaulted to,
                        // and a bright sky behind dark terrain clipped hard.
                        if (try? device.lockForConfiguration()) != nil {
                            if device.isExposureModeSupported(.continuousAutoExposure) {
                                device.exposureMode = .continuousAutoExposure
                            }
                            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                                device.whiteBalanceMode = .continuousAutoWhiteBalance
                            }
                            if device.activeFormat.isVideoHDRSupported {
                                device.automaticallyAdjustsVideoHDREnabled = true
                            }
                            device.unlockForConfiguration()
                        }
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
            // A spot that just FAILED (offline fetch): updateUIView resubmits
            // the model's viewpoint on every SwiftUI update, and with the
            // dedupe memory cleared below that became a tight fail-retry loop
            // (status thrashing "Switching location" ↔ failed ~every 1.5 s).
            // Cool down instead: the model shows the failure and falls back to
            // the previous scene; an explicit later retry sails past this.
            if let failed = lastFailedRequest,
               abs(failed.lat - lat) < 1e-6, abs(failed.lon - lon) < 1e-6,
               Date().timeIntervalSince(failed.at) < 8 { return }
            if isReloading {
                // Never DROP a move that arrives mid-bake: doing so left the model
                // standing at the new feature while the render stayed put (the
                // Illumination Saddle → Rock bug). Keep only the LATEST request
                // and run it when the in-flight bake settles (finishReload).
                queuedRequest = (lat: lat, lon: lon, snap: snapToSummit)
                return
            }
            requestBeforeMove = lastRequested
            lastRequested = (lat, lon)
            pendingSummitSnap = snapToSummit
            isReloading = true
            moveGeneration &+= 1
            let gen = moveGeneration
            moveMutatedScene = false
            report(.preparingTerrain(progress: nil))

            // Reuse fast-path: both tiers already cover this viewpoint.
            if let tile = dem, tile.contains(lat: lat, lon: lon, marginMeters: 18_000),
               let far = demFar, far.contains(lat: lat, lon: lon, marginMeters: 18_000) {
                moveMutatedScene = true
                let eye = summitSnappedEye(lat: lat, lon: lon, tile: tile)
                let ground = eye.elev
                refLat = eye.lat; refLon = eye.lon
                groundElev = ground
                recomputeCamElev()
                // Labels rebuild when the new panorama installs (bakeProgressive) —
                // rebuilding here floated new-ref anchors over the still-old image.
                rebuildSky()
                updateFarHorizon()
                NSLog("Viewpoint reused current tile (no fetch)")
                bakeProgressive(progressFrom: 0) {
                    guard gen == self.moveGeneration else { return }   // cancelled
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
                            self?.loadPartialDownloads = [:]
                            self?.loadUnitsTotal = total
                            self?.report(.preparingTerrain(progress: total > 0 ? 0 : nil))
                        }
                        // Whole units per settled tile + FRACTIONAL bytes for
                        // tiles in flight: each tile is ~10 MB, and unit-only
                        // ticks left the bar frozen for the many seconds a
                        // tile spends downloading (measured: 20+ s stalls on
                        // a cold load over a slow link).
                        let onStitched: @Sendable () -> Void = { [weak self] in
                            DispatchQueue.main.async {
                                guard let self, gen == self.moveGeneration else { return }
                                self.loadUnitsDone = min(self.loadUnitsDone + 1, self.loadUnitsTotal)
                                self.reportLoadProgress()
                            }
                        }
                        let onTileDone: @Sendable (String) -> Void = { [weak self] name in
                            DispatchQueue.main.async {
                                guard let self, gen == self.moveGeneration else { return }
                                self.loadPartialDownloads[name] = nil
                                self.loadUnitsDone = min(self.loadUnitsDone + 1, self.loadUnitsTotal)
                                self.reportLoadProgress()
                            }
                        }
                        let onTileBytes: @Sendable (String, Double) -> Void = { [weak self] name, frac in
                            DispatchQueue.main.async {
                                guard let self, gen == self.moveGeneration else { return }
                                self.loadPartialDownloads[name] = min(1, frac)
                                self.reportLoadProgress()
                            }
                        }
                        // Near (native ~30 m, ≈40 km) + far (coarse, ≈120 km) in parallel.
                        async let near = DEMFetcher.fetch(lat: lat, lon: lon,
                                                          radiusMeters: Self.nearRadius, maxGrid: Self.nearMaxGrid,
                                                          onTileComplete: onTileDone,
                                                          onTileDownloadProgress: onTileBytes,
                                                          onTileStitched: onStitched)
                        async let far = DEMFetcher.fetch(lat: lat, lon: lon,
                                                         radiusMeters: Self.farRadius, maxGrid: Self.farMaxGrid,
                                                         onTileComplete: onTileDone,
                                                         onTileDownloadProgress: onTileBytes,
                                                         onTileStitched: onStitched)
                        let nearResult = try await near
                        let farResult = try await far
                        nearTile = nearResult.tile
                        farTile = farResult.tile
                        // Persist only COMPLETE fetches: a tile with transiently
                        // failed degree squares renders now (voids filled) but must
                        // not become the instant-open snapshot — that turned a
                        // Wi-Fi hiccup into flat ocean across launches.
                        fromNetwork = nearResult.complete && farResult.complete
                        if !fromNetwork { NSLog("DEM fetch incomplete (transient tile failures) — not snapshotting") }
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
                        guard let self, gen == self.moveGeneration else { return }  // cancelled
                        // Clear the dedupe memory: a retry of the SAME spot after
                        // a failure must re-attempt, not silently no-op — but
                        // stamp the failure so the passive resubmission path
                        // cools down instead of looping (see requestViewpoint).
                        self.lastRequested = nil
                        self.lastFailedRequest = (lat, lon, Date())
                        self.report(.failed(failure))
                        self.finishReload()
                    }
                    return
                }
                // Cancelled while fetching? Stop before the expensive tail: no
                // texture upload, and — critically — no last-region snapshot
                // (a cancelled move must not overwrite the instant-launch
                // cache with a region the user backed out of).
                let stillWanted = await MainActor.run { [weak self] in gen == self?.moveGeneration }
                guard stillWanted else { return }
                let tex = tile.makeTexture(device: device)
                let farTex = (farTile?.makeTexture(device: device))
                NSLog("DEM ready in %.0f ms (%@)", Self.ms(since: t0), fromNetwork ? "fetch" : "snapshot")
                // Snapshot a freshly fetched region for an instant next launch.
                if fromNetwork { DEMFetcher.saveLastRegion(near: tile, far: farTile) }
                await MainActor.run {
                    guard let self, gen == self.moveGeneration else { return }  // cancelled
                    self.moveMutatedScene = true
                    self.dem = tile
                    self.demFar = farTile
                    self.onDEMTiles(tile, farTile)
                    self.renderer?.heightTexture = tex
                    self.renderer?.farHeightTexture = farTex
                    let eye = self.summitSnappedEye(lat: lat, lon: lon, tile: tile)
                    let ground = eye.elev
                    self.refLat = eye.lat; self.refLon = eye.lon
                    self.groundElev = ground
                    self.recomputeCamElev()
                    // Labels rebuild on panorama install (see bakeProgressive).
                    self.rebuildSky()
                    self.updateFarHorizon()
                    self.bakeProgressive(progressFrom: Self.loadShare) {
                        guard gen == self.moveGeneration else { return }        // cancelled
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
            // The eye stands EXACTLY on the DEM surface here (eye height is
            // added in recomputeCamElev): the CPU `elevation(lat:lon:)` and the
            // shader's `sampleGrid` resolve the same bilinear surface — both
            // map index i to (i+0.5)·cell from the corner — so ground+eye can
            // never start inside the rendered hillside. The old "lift to the
            // 45 m crest" guard traded accuracy for that fear: in AR it pushed
            // the render eye above the real one, which sank close ridges below
            // their true elevation and erased their silhouettes; on lakes it
            // climbed the shoreline bank. A nearby bump that legitimately
            // blocks the view now blocks it, exactly as it does in reality.
            return (lat, lon, tile.elevation(lat: lat, lon: lon))
        }

        // MARK: Far-horizon ring

        private var ringGeneration = 0
        /// Latest ring profile, for the anchor pre-filter. Main-thread only;
        /// the background workers (buildHorizon/buildAnchors) take it as a
        /// parameter — the old unsynchronized static was a cross-thread race.
        private var farProfile: FarHorizon.Profile?
        /// The `ringGeneration` that produced `farProfile` — anchors record the
        /// value they were built against, so the ring top-up can tell "already
        /// reflects the current ring" (reuse) from "built before it landed"
        /// (full rebuild). 0 until the first ring lands.
        private var farProfileGen = 0
        /// Set when the ring profile landed while a bake was already in flight
        /// (the bands encoded without it); finishReload tops the panorama up.
        var ringLandedMidBake = false

        /// Compute the beyond-tier silhouette profile (FarHorizon) for the
        /// current eye off-main and hand it to the renderer. Usually lands
        /// before the full bake's bands encode; when it doesn't, a quiet
        /// top-up bake runs after the reload settles.
        func updateFarHorizon() {
            guard FarHorizon.isAvailable else { return }
            ringGeneration &+= 1
            let gen = ringGeneration
            let lat = refLat, lon = refLon
            let eye = Double(groundElev) + 1.6
            renderer?.ringTexture = nil            // stale viewpoint's ring must not leak in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let profile = FarHorizon.profile(
                    latitude: lat, longitude: lon, eyeElevation: eye) else { return }
                DispatchQueue.main.async {
                    guard let self, gen == self.ringGeneration,
                          let renderer = self.renderer else { return }
                    self.farProfile = profile
                    self.farProfileGen = gen
                    renderer.ringTexture = Self.makeRingTexture(profile, device: renderer.device)
                    self.rebuildSky()   // rise/set tags re-anchor to the TRUE horizon
                    if self.isReloading {
                        self.ringLandedMidBake = true
                    } else {
                        self.bakeProgressive(progressFrom: 0, reportProgress: false,
                                             paced: true) {
                            self.report(.ready)
                        }
                    }
                }
            }
        }

        private static func makeRingTexture(_ p: FarHorizon.Profile,
                                            device: MTLDevice) -> MTLTexture? {
            // 2D strip (az x elevation band): nearest hit distance in km per
            // texel, 0 = sky. The bake reads real layered depth from this.
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float, width: FarHorizon.bins,
                height: FarHorizon.stripRows, mipmapped: false)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            p.strip.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, FarHorizon.bins, FarHorizon.stripRows),
                          mipmapLevel: 0, withBytes: $0.baseAddress!,
                          bytesPerRow: FarHorizon.bins * 2)
            }
            return t
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

        /// ID-wise equality without materializing two [String] arrays: this runs
        /// on every SwiftUI update over potentially thousands of peaks, and the
        /// common case is "nothing changed".
        private static func sameIDs(_ a: [Peak], _ b: [Peak]) -> Bool {
            guard a.count == b.count else { return false }
            // Same backing storage = definitely equal, for free. The common
            // case by far: the model hasn't republished, SwiftUI is just
            // re-running updateUIView (every frame during e.g. the keyboard
            // animation) — the full ID scan over ~50k peaks each time was a
            // visible main-thread hitch.
            let sameStorage = a.withUnsafeBufferPointer { ap in
                b.withUnsafeBufferPointer { bp in ap.baseAddress == bp.baseAddress }
            }
            if sameStorage { return true }
            return zip(a, b).allSatisfy { $0.id == $1.id }
        }

        func setPeaks(_ p: [Peak]) {
            guard !Self.sameIDs(p, peaks) else { return }
            peaks = p
            rebuildLabelAnchors()
        }

        func setLakes(_ l: [Peak]) {
            guard !Self.sameIDs(l, lakes) else { return }
            lakes = l
            rebuildLabelAnchors()
        }

        /// User saved spots (`loc_…`) — their own yellow look-around dots. Same
        /// coalesced rebuild path as peaks/lakes; a fresh drop shows on the next
        /// anchor build without a re-bake.
        func setSavedSpots(_ s: [Peak]) {
            guard !Self.sameIDs(s, savedSpots) else { return }
            savedSpots = s
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
        /// An anchor build has been requested and its result hasn't landed yet.
        private var anchorBuildInFlight = false
        /// One-shot: fired (and cleared) when the next anchor set delivers —
        /// the first bake holds its `.ready` on this so terrain and labels
        /// reach the screen in the same frame (see bakeProgressive).
        private var onAnchorsInstalled: (() -> Void)?
        /// One-shot: fired (and cleared) when celestial content applies to the
        /// overlay — the first bake ALSO holds `.ready` on this (after the
        /// anchors) so the sun/moon arcs and stars can't pop in a beat after
        /// the reveal. Fired from the apply closure in rebuildCelestial.
        private var onCelestialInstalled: (() -> Void)?
        /// The anchor depth pass failed while backgrounded — rebuild on activate.
        private var anchorRetryOnActivate = false
        /// Backoff for depth-pass failures while ACTIVE (transient GPU aborts);
        /// reset by any successful pass.
        private var anchorDepthRetries = 0

        /// A nil depth map means the GPU pass was aborted — usually the app
        /// went to the background mid-load. The anchors just delivered were
        /// judged blind (degraded visibility, or none at all), so schedule a
        /// re-judge: right away (with a small backoff cap) while active, or
        /// the moment the app returns to the foreground.
        private func scheduleAnchorDepthRetry() {
            if UIApplication.shared.applicationState == .active {
                guard anchorDepthRetries < 3 else { return }
                anchorDepthRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.rebuildLabelAnchors()
                }
            } else {
                anchorRetryOnActivate = true
            }
        }

        /// Recompute label anchors for the current viewpoint/exaggeration.
        /// COALESCED: a teleport fires this three times within ~100 ms (bake
        /// start, then setPeaks + setLakes as the new area's features publish),
        /// and each compute renders its own 4096-wide depth panorama — running
        /// all three serialized the GPU behind the bake and tripled the wait
        /// before labels (and, during a re-bake, the whole scene swap) could
        /// land. Only the last request in a burst actually runs.
        private func rebuildLabelAnchors() {
            anchorRebuildWork?.cancel()
            anchorBuildInFlight = true
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
                installAnchors([], visibleIDs: [], ringStamp: farProfileGen)
                return
            }
            let far = self.demFar
            let peaks = self.peaks
            let lakes = self.lakes
            let savedSpots = self.savedSpots
            guard !peaks.isEmpty || !lakes.isEmpty || !savedSpots.isEmpty else {
                installAnchors([], visibleIDs: [], ringStamp: farProfileGen)
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
            let ringProfile = farProfile           // main-thread snapshot for the worker
            let ringStamp = farProfileGen          // which ring the anchors will reflect
            labelGeneration &+= 1
            let gen = labelGeneration
            // .userInitiated, not .utility: during a move this build GATES the
            // scene swap (maybeCompleteSwap waits on it) — utility landed it on
            // efficiency cores and visibly stretched the "Switching location" tail.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                    peaks: peaks, lakes: lakes, savedSpots: savedSpots,
                    dem: dem, far: far, refLat: refLat, refLon: refLon,
                    camElevMeters: camElevM, heightScale: hs,
                    depth: depthMap?.depth ?? [], depthW: depthMap?.width ?? 0,
                    depthH: depthMap?.height ?? 0, skyDepth: skyDepth, panoElevMax: panoElevMax,
                    ringProfile: ringProfile)
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Depth-pass health is orthogonal to staleness: a failed
                    // pass schedules a retry even if this result is outdated.
                    if depthMap == nil { self.scheduleAnchorDepthRetry() }
                    else { self.anchorDepthRetries = 0 }
                    guard gen == self.labelGeneration else { return }
                    self.installAnchors(anchors, visibleIDs: visibleIDs, ringStamp: ringStamp)
                }
            }
        }

        /// The last anchor set delivered (installed or stashed for a swap), with
        /// the `farProfileGen` its build snapshotted — lets the ring top-up bake
        /// reuse it verbatim when the anchors already reflect the current ring
        /// (see finishReload) instead of re-judging ~30k peaks for an identical
        /// result.
        private var lastAnchorState:
            (anchors: [PeakLabelOverlayView.Anchor], visibleIDs: Set<String>, ringStamp: Int)?

        /// Route a computed anchor set: stash it for the atomic image+label swap
        /// while a re-bake is pending, install it directly otherwise.
        private func installAnchors(_ anchors: [PeakLabelOverlayView.Anchor],
                                    visibleIDs: Set<String>, ringStamp: Int) {
            lastAnchorState = (anchors, visibleIDs, ringStamp)
            anchorBuildInFlight = false
            // Hold the CURRENT labels on screen for the whole move, not just the
            // bake tail. `teleport` republishes the new region's peaks the instant
            // the move starts (via loadPeaks), and that fires an anchor rebuild
            // while the DEM fetch is still in flight — built against the OLD DEM,
            // so it resolves to nothing and wiped the labels off the still-shown
            // old terrain. Stash any build during a move (isReloading) once a
            // scene exists; the bake's own rebuild lands the correct set at the
            // atomic swap. (First load has no scene to protect — install direct.)
            // EXCEPT while the first-load `.ready` barrier waits on THIS install
            // (onAnchorsInstalled set): the first bake just installed the pano
            // (panoInstalled true, isReloading true until .ready), but that path
            // never runs the swap — stashing here parked the first scene's dots
            // in a swap that never completed, and they only appeared seconds
            // later via the ring top-up. The barrier's install goes DIRECT.
            let holdForSwap = rebakePending
                || (isReloading && panoInstalled && onAnchorsInstalled == nil)
            if holdForSwap {
                pendingAnchors = (anchors, visibleIDs)
                maybeCompleteSwap()
            } else {
                container?.labelOverlay.anchors = anchors
                onVisibleFeatures(visibleIDs)
                view?.setNeedsDisplay()
            }
            // Release the first bake's .ready barrier (either branch: a swap
            // superseding the first scene must not strand the held completion).
            if let cb = onAnchorsInstalled { onAnchorsInstalled = nil; cb() }
        }

        /// Scrub the sky to a new instant. The terrain skyline (horizon) is unchanged,
        /// so this only re-lights the celestial overlay — cheap enough per scrub tick.
        func setDisplayDate(_ date: Date) {
            guard abs(date.timeIntervalSince(displayDate)) > 0.5 else { return }
            displayDate = date
            // Same viewpoint, new time: the live sky re-lights immediately
            // (that's the point of scrubbing) — EXCEPT mid-reload, where
            // refLat/refLon may already be the new location's: the displayed
            // scene keeps its own sun until the swap (a live-clock tick here
            // used to repaint the sky for the destination over the old
            // terrain).
            updateSunDirectionNow(applyToLiveSky: !isReloading && !rebakePending)
            rebuildCelestial()
        }

        /// Compute the sun direction for the CURRENT viewpoint/date on the spot.
        /// It always feeds the BAKE (`bakeSunENU`) so the very next bake is lit
        /// for the new place/time. It reaches the LIVE sky (`skySunENU`) only
        /// when asked (time scrubs) or when nothing is on screen yet — on a
        /// LOCATION change the live sky keeps the old sun until the new
        /// panorama installs, so sky and terrain never change apart.
        private func updateSunDirectionNow(applyToLiveSky: Bool) {
            let sun = Ephemeris.sunPosition(date: displayDate, latitude: refLat, longitude: refLon)
            bakeSunENU = SkyArcOverlayView.enu(azimuthDeg: sun.azimuthDeg, elevationDeg: sun.elevationDeg)
            if applyToLiveSky || !panoInstalled {
                skySunENU = bakeSunENU
                reportNight()
            }
        }

        /// Recompute the terrain skyline for this viewpoint (the expensive,
        /// time-independent part), cache it, then place the sky bodies on it.
        private func rebuildSky() {
            guard let dem else { return }
            // Light the upcoming BAKE for the new viewpoint (the live sky keeps
            // the old sun until that bake's panorama installs).
            updateSunDirectionNow(applyToLiveSky: false)
            let far = self.demFar
            let lat = refLat, lon = refLon
            let camElevM = Double(camElev), hs = Double(exaggeration)
            let ringProfile = farProfile           // main-thread snapshot for the worker
            let ringGen = farProfileGen            // which ring that profile reflects
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let horizon = Self.buildHorizon(dem: dem, far: far, refLat: lat, refLon: lon,
                                                camElevMeters: camElevM, heightScale: hs,
                                                ringProfile: ringProfile)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cachedHorizon = horizon
                    self.cachedHorizonRingGen = ringGen
                    self.rebuildCelestial()
                }
            }
        }

        /// Serial home for celestial rebuilds: keeps overlapping scrub ticks from
        /// racing each other, and confines the cached formatter + day-path cache
        /// below to one thread (DateFormatter is not thread-safe).
        private static let celestialQueue = DispatchQueue(
            label: "com.peakpeek.celestial", qos: .utility)
        /// Rise/set tag formatter, reused across rebuilds (construction is one of
        /// the classically expensive Foundation inits, and this fired per scrub
        /// tick). celestialQueue-confined; only `timeZone` changes per viewpoint.
        private static let tagFormatter: DateFormatter = {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return f
        }()
        /// Sun/moon diurnal arcs cached per (local day, viewpoint): windowPath is
        /// anchored to the lap's lower culmination precisely so scrubbing hours
        /// leaves the arc fixed — yet each 0.5 s scrub tick re-derived both
        /// (~290 full ephemeris samples). A hit must also still COVER the
        /// display date: the moon's ~24h50m lap can roll over mid-day, and a
        /// stale lap would strand the disc off its arc. celestialQueue-confined.
        private static var dayPathCache:
            (key: String, sun: Ephemeris.Path, moon: Ephemeris.Path)?

        /// Place the sun, moon, stars and Milky Way at `displayDate` against the cached
        /// skyline (off-main), then hand the projected directions to the sky overlay.
        /// No DEM marching → fast, so scrubbing time stays smooth.
        private func rebuildCelestial() {
            guard let horizon = cachedHorizon else { return }
            let lat = refLat, lon = refLon
            let ringGen = cachedHorizonRingGen  // ring this pass's occlusion reflects
            let date = displayDate
            let displayTZ = displayTimeZone     // main-thread snapshot for the worker
            Self.celestialQueue.async { [weak self] in
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
                // Format rise/set in the VIEWED location's timezone (the model's
                // resolved DST-correct zone), not the device's — otherwise a
                // remote viewpoint shows times shifted by the UTC gap.
                let fmt = Self.tagFormatter
                fmt.timeZone = displayTZ
                ClockText.applyTimeStyle(to: fmt)   // 12/24h per the menu override or locale

                // Per-body: samples flagged visible (above the ridge skyline) + the
                // ridge-crossing rise/set tags (first ↑, LAST ↓), plus the
                // crossing INSTANTS themselves (the Time card's visibility window).
                func build(_ path: Ephemeris.Path, color: UIColor)
                    -> (samples: [SkyArcOverlayView.Sample], tags: [SkyArcOverlayView.Tag],
                        firstUp: Date?, lastDown: Date?) {
                    // Ridge clearance per sample, computed once and shared by the
                    // arc pass and the tag pass below (which used to re-derive it).
                    let clearance = path.samples.map {
                        $0.position.elevationDeg - horizonAt($0.position.azimuthDeg)
                    }
                    var samples: [SkyArcOverlayView.Sample] = []
                    samples.reserveCapacity(path.samples.count + 8)
                    var prev: (az: Double, el: Double, c: Double)?
                    for (idx, s) in path.samples.enumerated() {
                        let az = s.position.azimuthDeg, el = s.position.elevationDeg
                        let c = clearance[idx]
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
                    // Collect ALL ridge crossings, then keep only the day's
                    // OUTER pair: the FIRST rise into view and the LAST drop
                    // out of it. The old "first ↓" broke whenever the arc
                    // slipped behind a tall peak mid-day — that temporary dip
                    // supplied the ↓ tag and the card's "last visible" hours
                    // early. Dips still read on the arc itself (its hidden
                    // segments); they're just not the day's rise/set.
                    var crossings: [(rising: Bool, az: Double, date: Date)] = []
                    for i in 1..<path.samples.count {
                        let p0 = path.samples[i - 1].position, p1 = path.samples[i].position
                        let c0 = clearance[i - 1]
                        let c1 = clearance[i]
                        guard c0 != c1, (c0 <= 0) != (c1 <= 0) else { continue }
                        let f = c0 / (c0 - c1)
                        let az = p0.azimuthDeg + f * shortestDelta(p0.azimuthDeg, p1.azimuthDeg)
                        let date = path.samples[i - 1].date.addingTimeInterval(
                            f * path.samples[i].date.timeIntervalSince(path.samples[i - 1].date))
                        crossings.append((c1 > c0, az, date))
                    }
                    var tags: [SkyArcOverlayView.Tag] = []
                    var firstUp: Date?, lastDown: Date?
                    let outer = [crossings.first(where: { $0.rising }),
                                 crossings.last(where: { !$0.rising })]
                    for cr in outer.compactMap({ $0 }) {
                        tags.append(.init(
                            dir: SkyArcOverlayView.enu(azimuthDeg: cr.az,
                                                       elevationDeg: horizonAt(cr.az)),
                            text: "\(cr.rising ? "↑" : "↓") \(fmt.string(from: cr.date))",
                            color: color))
                        if cr.rising { firstUp = cr.date } else { lastDown = cr.date }
                    }
                    return (samples, tags, firstUp, lastDown)
                }

                // TRUE (astronomical-horizon) rise/set: the sun's upper limb
                // touching the sea-level horizon — apparent centre elevation
                // (refraction is already folded into the ephemeris) crossing
                // −16′ (the solar semidiameter). Linear interpolation between
                // the 10-min lap samples is within ~a minute, plenty for a card.
                func trueRiseSet(_ path: Ephemeris.Path) -> (rise: Date?, set: Date?) {
                    let limbDeg = 0.267
                    var rise: Date?, set: Date?
                    for i in 1..<path.samples.count {
                        let e0 = path.samples[i - 1].position.elevationDeg + limbDeg
                        let e1 = path.samples[i].position.elevationDeg + limbDeg
                        guard e0 != e1, (e0 <= 0) != (e1 <= 0) else { continue }
                        let f = e0 / (e0 - e1)
                        let d = path.samples[i - 1].date.addingTimeInterval(
                            f * path.samples[i].date.timeIntervalSince(path.samples[i - 1].date))
                        if e1 > e0 { if rise == nil { rise = d } }
                        else if set == nil { set = d }
                    }
                    return (rise, set)
                }

                // windowPath is anchored to the lap containing `date`, constant
                // while scrubbing within the lap — cache per (day, viewpoint),
                // and require the cached laps to still cover `date`.
                let dayKey = "\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)_\(lat)_\(lon)"
                let paths: (sun: Ephemeris.Path, moon: Ephemeris.Path)
                if let hit = Self.dayPathCache, hit.key == dayKey,
                   hit.sun.covers(date), hit.moon.covers(date) {
                    paths = (hit.sun, hit.moon)
                } else {
                    paths = (Ephemeris.windowPath(of: .sun, centeredOn: date, latitude: lat, longitude: lon),
                             Ephemeris.windowPath(of: .moon, centeredOn: date, latitude: lat, longitude: lon))
                    Self.dayPathCache = (dayKey, paths.sun, paths.moon)
                }
                let sun = build(paths.sun,
                                color: UIColor(red: 0.95, green: 0.73, blue: 0.10, alpha: 0.95))
                let moon = build(paths.moon,
                                 color: UIColor(white: 0.85, alpha: 0.9))
                let sunRiseSet = trueRiseSet(paths.sun)
                let sunTimes = PanoramaViewModel.SunTimes(
                    sunrise: sunRiseSet.rise, sunset: sunRiseSet.set,
                    firstVisible: sun.firstUp, lastVisible: sun.lastDown)
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
                let phase = Ephemeris.moonPhase(date: date)
                if moonNow.elevationDeg >= horizonAt(moonNow.azimuthDeg) {
                    // Tapping the moon answers the question you actually have:
                    // which phase is that?
                    named.append(.init(name: "Moon · \(phase.name)",
                                       dir: enu(moonNow.azimuthDeg, moonNow.elevationDeg),
                                       magnitude: -12.7))
                }
                let moonIllum = CGFloat(phase.illuminatedFraction)
                let moonWaxing = phase.ageDays < 14.7653          // < half a synodic month

                let skySun = SkyArcOverlayView.enu(azimuthDeg: sunNow.azimuthDeg,
                                                   elevationDeg: sunNow.elevationDeg)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let apply = { [weak self] in
                        guard let self, let so = self.container?.skyArc else { return }
                        so.sunSamples = sun.samples
                        so.moonSamples = moon.samples
                        so.sunDisc = sunDisc
                        so.moonDisc = moonDisc
                        // The skyline the discs emerge from — same profile the
                        // verdicts above were judged against.
                        so.horizonProfile = horizon
                        so.tags = sun.tags + moon.tags
                        so.stars = stars
                        so.planets = planets
                        so.nightOpacity = nightOpacity
                        so.namedObjects = named
                        so.moonIlluminated = moonIllum
                        so.moonWaxing = moonWaxing
                        self.celestialRef = (lat, lon)
                        self.celestialRingGen = ringGen
                        self.skySunENU = skySun
                        self.reportNight()
                        self.onSunTimes(sunTimes)
                        self.view?.setNeedsDisplay()
                        // Release a first-load `.ready` waiting on the sky
                        // (see bakeProgressive's first-image branch).
                        if let cb = self.onCelestialInstalled {
                            self.onCelestialInstalled = nil
                            cb()
                        }
                    }
                    // A scene reload is in flight: hold the content and land
                    // it with the panorama swap, not over the still-displayed
                    // old terrain. Stamped with ITS viewpoint — a mid-reload
                    // rebuild can still describe the OLD location (live-clock
                    // tick before the new DEM installs), and the swap must
                    // not apply that over the new scene.
                    // EXCEPT when the first-load barrier is waiting on this very
                    // content (onCelestialInstalled set, refs match): the pano
                    // is already installed and no swap is coming — stashing
                    // would deadlock the reveal. Apply directly instead.
                    let matchesCurrent = abs(lat - self.refLat) < 1e-6
                        && abs(lon - self.refLon) < 1e-6
                    if (self.isReloading || self.rebakePending)
                        && !(self.onCelestialInstalled != nil && matchesCurrent) {
                        self.pendingCelestialApply = (lat, lon, ringGen, apply)
                    } else {
                        apply()
                    }
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
            camElevMeters: Double, heightScale: Double,
            ringProfile: FarHorizon.Profile?
        ) -> [Float] {
            // 0.375°/bin: at 480 bins (0.75°) the interpolated skyline could disagree
            // with the rendered ridge by a few tenths of a degree in rugged terrain,
            // visibly mis-timing sun/moon rise-set tags and disc visibility. One-time
            // per viewpoint, off-main, so the 2× march cost is invisible.
            let bins = 960
            let curvatureK = (1 - GeoMath.refractionCoefficient) / (2 * GeoMath.earthRadiusMeters)
            // The far tile is a SQUARE box: corner directions carry rendered
            // terrain out to √2 × its radius. March the whole square so a
            // drawn corner-band ridge still shapes the sky skyline.
            let maxDist = FarHorizon.farTileMeters * 2.0.squareRoot()
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
                // The DEM ends at 120 km, but the WORLD doesn't: clamp to the
                // far-horizon ring's silhouette and, where that is empty (open
                // ocean), the sea-level curvature dip — so the sun/moon rise
                // and set on the TRUE horizon, not the terrain tile's edge.
                if let prof = ringProfile {
                    let rb = min(FarHorizon.bins - 1,
                                 max(0, Int(bearing / (2 * .pi) * Double(FarHorizon.bins))))
                    maxAngle = max(maxAngle, atan(Double(prof.tanEl[rb])) * 180 / .pi)
                }
                maxAngle = max(maxAngle,
                               -sqrt(max(0, 2 * camElevMeters / 7_324_000)) * 180 / .pi)
                horizon[b] = Float(maxAngle)
            }
            return horizon
        }

        private static func buildAnchors(
            peaks: [Peak], lakes: [Peak] = [], savedSpots: [Peak] = [],
            dem: DEMTile, far: DEMTile?, refLat: Double, refLon: Double,
            camElevMeters: Double, heightScale: Double,
            depth: [Float], depthW: Int, depthH: Int, skyDepth: Double, panoElevMax: Double,
            ringProfile: FarHorizon.Profile?
        ) -> (anchors: [PeakLabelOverlayView.Anchor], visibleIDs: Set<String>) {
            let mLat = 111_320.0
            let mLon = 111_320.0 * max(cos(refLat * .pi / 180), 0.01)
            let curvatureK = (1 - GeoMath.refractionCoefficient)
                / (2 * GeoMath.earthRadiusMeters)               // matches the shader
            // Geodesic-bulge coefficient — the forward twin of the shader's per-sample
            // correction (Shaders.metal terrainHeight): a feature due east is seen
            // slightly poleward of east, by east²·tanRef/(2R) meters of northing.
            let tanRefOver2R = tan(refLat * .pi / 180) / (2 * Uniforms.enuEarthRadiusMeters)
            // The far DEM tile is a SQUARE ±farTileMeters box — in corner
            // directions its rendered terrain reaches √2 × that. The real
            // coverage gate is `contains` below; this radius must NOT
            // undershoot the corners (a stale 120 km here skipped Rainier
            // seen from Mount Olympus at 180 km: drawn by the tile, yet
            // unanchored and mis-verdicted "Occluded").
            let maxDist = FarHorizon.farTileMeters * 2.0.squareRoot()
            // The per-peak work (summit snap + line-of-sight ray march, thousands of
            // DEM samples each) is independent and reads only immutable data, so fan
            // it out across cores; single-threaded this was the visible post-load
            // stall. Each slot is written by exactly one iteration.
            // `ringVisible` = drawn only by the far-horizon ring: honestly VISIBLE
            // (info card / search say so) but deliberately unlabeled — it never
            // becomes an anchor.
            enum Verdict: UInt8 { case skipped = 0, shown, occluded, floating, ringVisible }
            // ---- Deterministic summit CLAIMING --------------------------------
            // The old scheme let every peak independently grab the highest cell
            // within its radius, with a SYMMETRIC neighbor cap — two failure
            // modes, both live on the Matterhorn: Épaule de Furggen 157 m away
            // crushed the Matterhorn's own snap radius to 71 m, and the
            // void-filled SRTM summit (3567 m where the mountain is 4478!) put
            // the massif's highest DRAWN cell (4230 m) over Pic Tyndall — whose
            // independent snap then claimed the drawn apex while the Matterhorn
            // label sat visibly below it. Now:
            //  1. Radius caps are ASYMMETRIC: only a HIGHER catalog peak shrinks
            //     a neighbor's reach (a false summit must never starve the main
            //     peak's), ties broken by id for determinism.
            //  2. Peaks snap SERIALLY in descending catalog elevation, each
            //     claiming its cell (plus a one-cell halo) — the dominant peak
            //     of a cluster always gets the best cell, subordinates take the
            //     next-best, never a race.
            //  3. A dominant whose best cell UNDERSHOOTS its catalog height by
            //     >150 m (the void-fill signature) extends its scan once to
            //     600 m so it can claim the massif's true drawn apex; and
            //     cells above a peak's own height carry an overshoot penalty
            //     (see summitCellNear), so shoulders prefer their own tops.
            let effElev: [Double] = peaks.map { $0.elevationMeters }
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
                            // Saddles never snap; LOWER peaks never shrink a
                            // higher one's reach (asymmetric cap, rule 1).
                            for j in grid[cellKey(la + Int64(dla), lo + Int64(dlo)), default: []]
                            where j != i && !peaks[j].isSaddle
                                && (effElev[j] > effElev[i]
                                    || (effElev[j] == effElev[i] && peaks[j].id < peaks[i].id)) {
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
            // Serial claim pass (rules 2–3). Cheap: one small window scan per
            // peak (~tens of ms across the catalog), and it makes the whole
            // assignment order-deterministic.
            var snappedCell = [(lat: Double, lon: Double, elev: Float)?](
                repeating: nil, count: peaks.count)
            do {
                var claimed = Set<Int64>()
                func claimKey(_ la: Double, _ lo: Double) -> Int64 {
                    // Half-arc-second bins: finer than any tier's cell grid.
                    Int64(((la + 90) * 7200).rounded()) &* 4_000_000
                        &+ Int64(((lo + 180) * 7200).rounded())
                }
                let order = peaks.indices.sorted {
                    effElev[$0] == effElev[$1] ? peaks[$0].id < peaks[$1].id
                                               : effElev[$0] > effElev[$1]
                }
                for i in order where !peaks[i].isSaddle {
                    let p = peaks[i]
                    let inNear = dem.contains(lat: p.latitude, lon: p.longitude)
                    let tile = inNear ? dem : (far ?? dem)
                    guard tile.contains(lat: p.latitude, lon: p.longitude) else { continue }
                    let target = p.elevationMeters > 0 ? Float(p.elevationMeters) : nil
                    let excluded: (Double, Double) -> Bool = { claimed.contains(claimKey($0, $1)) }
                    var s = tile.summitCellNear(lat: p.latitude, lon: p.longitude,
                                                radiusMeters: snapRadius[i],
                                                targetElev: target, isExcluded: excluded)
                    if let target, target - s.elev > 150, snapRadius[i] < 600 {
                        // Void-shaved summit: reach out for the drawn apex.
                        s = tile.summitCellNear(lat: p.latitude, lon: p.longitude,
                                                radiusMeters: 600,
                                                targetElev: target, isExcluded: excluded)
                    }
                    snappedCell[i] = s
                    let halo = tile.cellsize
                    for dla in -1...1 {
                        for dlo in -1...1 {
                            claimed.insert(claimKey(s.lat + Double(dla) * halo,
                                                    s.lon + Double(dlo) * halo))
                        }
                    }
                }
            }
            // Peaks occupy [0, peaks.count); lakes [peaks.count, total). Lakes skip
            // the summit snap (a lake would "snap" onto its shoreline ridge!) and the
            // floating-sky cull (a surface point can't float): they anchor at the DEM
            // surface elevation of the catalog coordinate.
            // Combined index space: [0, peaks) peaks, [peaks, lakeEnd) lakes,
            // [lakeEnd, total) saved spots. Saved spots anchor at their exact
            // coordinate like lakes/saddles (no summit snap) and are never in the
            // peaks-only summit-claiming pass above.
            let lakeEnd = peaks.count + lakes.count
            let total = lakeEnd + savedSpots.count
            var results = [PeakLabelOverlayView.Anchor?](repeating: nil, count: total)
            var verdicts = [UInt8](repeating: 0, count: total)
            // Per-lake water-snap provenance, for the same-name dedup below:
            // which candidate RING the anchor came from (0 = the label sat on
            // or beside real water — most trustworthy) and its surface height.
            var waterMeta = [(ring: Int32, elev: Float)](repeating: (.max, 0), count: total)
            results.withUnsafeMutableBufferPointer { res in
                verdicts.withUnsafeMutableBufferPointer { verd in
                    waterMeta.withUnsafeMutableBufferPointer { wm in
                    DispatchQueue.concurrentPerform(iterations: total) { i in
                        let isSavedSpot = i >= lakeEnd
                        let isWater = i >= peaks.count && i < lakeEnd
                        let peak = isSavedSpot ? savedSpots[i - lakeEnd]
                            : isWater ? lakes[i - peaks.count] : peaks[i]
                        let watched = Self.labelWatch.map { peak.name.lowercased().contains($0) } ?? false
                        func watch(_ msg: String) {
                            if watched { NSLog("labelWatch %@: %@", peak.name, msg) }
                        }
                        // Coverage is the union of both tiers (far spans the whole scene).
                        let inNear = dem.contains(lat: peak.latitude, lon: peak.longitude)
                        // WATER beyond the near tier is judged but never
                        // ANCHORED: the far grid's 58 m cells barely render a
                        // lake basin, and the depth fast-path's relative margin
                        // grows with distance — together they scattered lake
                        // dots across the flat far-valley render ("lakes
                        // showing through terrain", Mount Adams). The exact CPU
                        // march has neither problem, so far lakes still get an
                        // honest Visible/Occluded for the search and the card —
                        // verdict-only, like the ring's unlabeled giants.
                        let farWater = isWater && !inNear
                        let snapTile = inNear ? dem : (far ?? dem)
                        // Beyond the far tile the ring draws terrain as haze.
                        // Peaks that crest its silhouette stay honestly visible
                        // for the card/search, and the ULTRA-PROMINENT ones
                        // (the only things visible at that range) get a dot on
                        // the silhouette so the label overlay covers the whole
                        // horizon, ring included.
                        let onTile = snapTile.contains(lat: peak.latitude, lon: peak.longitude)
                        // The raymarch draws only to `skyDepth/2` (the shader's
                        // tMax). The far tile is a SQUARE, so its corner band
                        // holds peaks on-tile yet BEYOND the march — Rainier
                        // from Mount Olympus (181 km) lives there: the RING
                        // draws its hazy silhouette while the depth map is
                        // honestly sky. Those must be judged and anchored by
                        // the ring path, not the depth map.
                        let inMarch = hypot((peak.longitude - refLon) * mLon,
                                            (peak.latitude - refLat) * mLat)
                            <= skyDepth / 2 - 1_000
                        guard onTile, inMarch else {
                            guard !isWater, !peak.isSaddle, peak.elevationMeters > 0,
                                  let prof = ringProfile else {
                                watch("skipped: beyond the raymarch, not ring-drawable")
                                return
                            }
                            // Same simple equirect mapping the ring march uses,
                            // so the silhouette bin (and the depth column) match
                            // where its haze is actually drawn.
                            let dE = (peak.longitude - refLon) * mLon
                            let dN = (peak.latitude - refLat) * mLat
                            let d = hypot(dE, dN)
                            guard d <= FarHorizon.endMeters else {
                                watch(String(format: "skipped: %.0f m beyond the ring's reach", d))
                                return
                            }
                            // Ring band: judge only what could plausibly be
                            // SEEN at this range — a small hill 200 km out is
                            // imperceptible however the geometry works out,
                            // and the coarse ring data can't vouch for it.
                            guard FarHorizon.perceptible(
                                prominenceMeters: peak.prominenceMeters,
                                elevationMeters: peak.elevationMeters,
                                distanceMeters: d) else {
                                watch("skipped: too small to read at this distance (ring band)")
                                return
                            }
                            let drop = curvatureK * d * d
                            let tanEl = (peak.elevationMeters * heightScale - camElevMeters - drop) / d
                            var az = atan2(dE, dN); if az < 0 { az += 2 * .pi }
                            let bin = min(FarHorizon.bins - 1,
                                          Int(az / (2 * .pi) * Double(FarHorizon.bins)))
                            guard Float(tanEl) >= prof.tanEl[bin] - 0.003 else {
                                watch("occluded: below the far-ring silhouette at its azimuth")
                                verd[i] = Verdict.occluded.rawValue
                                return
                            }
                            // Nearer, tier-rendered terrain can still block it.
                            // The ring is NOT in the depth map, so any terrain at
                            // its pixel is in front of it — visible only on sky.
                            // Judge at the angle the peak is DRAWN at (the ring
                            // silhouette it gets pinned to), NOT its catalog
                            // angle: when the max-pooled ring understates a
                            // giant, the catalog angle samples a sky pixel just
                            // above the front ridge while the drawn haze sits
                            // BEHIND it — Mount Adams from Hibox Mountain read
                            // "Visible" with its dot pinned into the front
                            // ridge's ground. Half a texel up so an exactly
                            // flush ridge doesn't false-occlude the boundary.
                            let pinnedTan = min(tanEl, Double(prof.tanEl[bin]))
                            if depthW > 0 {
                                var uu = az / (2 * .pi)
                                uu -= floor(uu)
                                let el = atan(pinnedTan) + panoElevMax / Double(depthH)
                                let vv = 0.5 - 0.5 * el / panoElevMax
                                let mx = min(depthW - 1, max(0, Int(uu * Double(depthW))))
                                let my = min(depthH - 1, max(0, Int(vv * Double(depthH))))
                                if Double(depth[my * depthW + mx]) < skyDepth {
                                    watch("occluded: within-tier terrain in front of the ring haze")
                                    verd[i] = Verdict.occluded.rawValue
                                    return
                                }
                            }
                            verd[i] = Verdict.ringVisible.rawValue
                            watch(String(format: "VISIBLE via the far-horizon ring at %.0f km", d / 1000))
                            // Ultra-prominent ring peaks anchor at the catalog
                            // coord (no DEM out there to snap to) — PINNED to
                            // the ring's DRAWN silhouette at their azimuth.
                            // The catalog summit can sit a shade above the
                            // max-pooled ETOPO crest, and an unpinned dot then
                            // floated in the sky over the drawn haze.
                            guard (peak.prominenceMeters ?? 0) >= 1500 else { return }
                            res[i] = .init(
                                peak: peak,
                                direction: SIMD3<Float>(Float(dE), Float(dN), Float(pinnedTan * d)),
                                distanceMeters: d,
                                isWater: false)
                            return
                        }
                        // Cheap range gate on the CATALOG coord before the (costly) summit
                        // snap; the snap moves ≤300 m so the slack keeps boundary peaks.
                        let approxHoriz = hypot((peak.longitude - refLon) * mLon,
                                                (peak.latitude - refLat) * mLat)
                        guard approxHoriz <= maxDist + 500 else {
                            watch(String(format: "skipped: %.0f m beyond reach %.0f m", approxHoriz, maxDist))
                            return
                        }
                        // Peaks use the CLAIMED summit cell from the serial
                        // assignment pass above (deterministic, contention-
                        // free); the label then sits on the rendered summit,
                        // not the (often offset) catalog point/height. Lakes
                        // AND saddles/gaps anchor at the DEM elevation of the
                        // point itself, no snap: a saddle is a LOW point
                        // between summits, and a summit snap dragged its label
                        // uphill onto the neighboring peak.
                        // Water snaps DOWN to the actual nearby surface — some
                        // lake catalog points sit on the shore slope (Ross
                        // Lake's is 430 m above the water), and the dot rode
                        // the mountainside. The march + occlusion then judge
                        // the surface point, which is also more honest.
                        var hi = peak.isSaddle || isWater || isSavedSpot
                            ? (lat: peak.latitude, lon: peak.longitude,
                               elev: snapTile.elevation(lat: peak.latitude, lon: peak.longitude))
                            : (snappedCell[i]
                               ?? (lat: peak.latitude, lon: peak.longitude,
                                   elev: snapTile.elevation(lat: peak.latitude, lon: peak.longitude)))
                        // Forward mapping matching the shader's corrected sampling:
                        // easting scaled by cos at the FEATURE's latitude (meridian
                        // convergence), northing plus the geodesic bulge. atan2(east,
                        // north) then equals the great-circle compass bearing, so the
                        // label direction, the rendered summit and the real world agree.
                        func geometry(_ pt: (lat: Double, lon: Double, elev: Float))
                            -> (east: Double, north: Double, horiz: Double,
                                apparentUp: Double, sightAngle: Double) {
                            let east = (pt.lon - refLon) * 111_320.0 * max(cos(pt.lat * .pi / 180), 0.01)
                            let north = (pt.lat - refLat) * mLat + east * east * tanRefOver2R
                            let horiz = (east * east + north * north).squareRoot()
                            let up = Double(pt.elev) * heightScale - curvatureK * horiz * horiz - camElevMeters
                            return (east, north, horiz, up, atan2(up, horiz) * 180 / .pi)
                        }
                        var g = geometry(hi)
                        if !isWater, g.horiz < 80 || g.horiz > maxDist {
                            watch(String(format: "skipped: snapped horiz %.0f m outside [80, %.0f]", g.horiz, maxDist))
                            return
                        }
                        // WATER: the dot belongs on the nearest VISIBLE water.
                        // Lake catalog points can sit on the shore slope (Ross
                        // Lake's is 430 m above the surface — the dot rode the
                        // mountainside), and the nearest surface cell alone can
                        // hide behind the shore ridge. So try surface CANDIDATES
                        // (one per search ring, stepping deeper into open
                        // water) and anchor at the first that passes the same
                        // depth pre-pass + exact-march judgment the single
                        // point used to get. None visible = honestly occluded.
                        if isWater {
                            func visible(_ pt: (lat: Double, lon: Double, elev: Float),
                                         _ gg: (east: Double, north: Double, horiz: Double,
                                                apparentUp: Double, sightAngle: Double)) -> Bool {
                                var bearing = atan2(gg.east, gg.north)
                                if bearing < 0 { bearing += 2 * .pi }
                                // Depth pre-pass (near tier only; see the old
                                // water notes — far cells made the pixel lie).
                                var drawnAtLake = depthW == 0 || farWater
                                if depthW > 0, !farWater {
                                    var uu = bearing / (2 * .pi)
                                    uu -= floor(uu)
                                    let vv = 0.5 - 0.5 * (gg.sightAngle * .pi / 180) / panoElevMax
                                    let mx = min(depthW - 1, max(0, Int(uu * Double(depthW))))
                                    let my = min(depthH - 1, max(0, Int(vv * Double(depthH))))
                                    let dC = Double(depth[my * depthW + mx])
                                    // Slant→horizontal (a summit eye looks DOWN
                                    // at its lakes; the slant runs long).
                                    let dH = dC * cos(gg.sightAngle * .pi / 180)
                                    let band = max(150, gg.horiz * 0.08)
                                    drawnAtLake = dC < skyDepth && abs(dH - gg.horiz) <= band
                                }
                                return drawnAtLake && !Self.waterSightlineOccluded(
                                    eyeLat: refLat, eyeLon: refLon,
                                    featLat: pt.lat, featLon: pt.lon,
                                    horiz: gg.horiz, apparentUp: gg.apparentUp,
                                    camElevMeters: camElevMeters, heightScale: heightScale,
                                    curvatureK: curvatureK, dem: dem, far: far)
                            }
                            var found = false
                            // Far-tier water is verdict-only (never dotted) —
                            // judge just the label point and skip the ring
                            // scans: 2,000+ far lakes × ~11k-cell scans was
                            // ~90% of a 20 s anchor build.
                            let candidates = farWater
                                ? [(lat: peak.latitude, lon: peak.longitude,
                                    elev: snapTile.elevation(lat: peak.latitude,
                                                             lon: peak.longitude))]
                                : snapTile.waterSurfaceCandidates(
                                    lat: peak.latitude, lon: peak.longitude)
                            for (ci, cand) in candidates.enumerated() {
                                let cg = geometry(cand)
                                guard cg.horiz >= 80, cg.horiz <= maxDist else { continue }
                                if visible(cand, cg) {
                                    hi = cand; g = cg; found = true
                                    wm[i] = (Int32(ci), cand.elev)
                                    watch(String(format: "WATER visible at candidate %.0f m out, elev %.0f",
                                                 cg.horiz, Double(cand.elev)))
                                    break
                                }
                            }
                            if !found {
                                verd[i] = Verdict.occluded.rawValue
                                return
                            }
                            if farWater {
                                // Visible, but no dot (far-tier water is
                                // judged-only) — the search/card verdicts pick
                                // this up exactly like the ring peaks.
                                verd[i] = Verdict.ringVisible.rawValue
                                watch("ring-visible: far-tier water, judged by the march only")
                                return
                            }
                        }
                        let east = g.east, north = g.north
                        let horiz = g.horiz, apparentUp = g.apparentUp
                        let sightAngle = g.sightAngle
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
                        // (Water was judged above, candidate by candidate —
                        // depth pre-pass + exact march; see waterSurfaceCandidates.)
                        if !isWater, depthW > 0 {
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
                                    watch(String(format: "OCCLUDED: horiz %.0f, sightAngle %.2f°, farthestTerrain %.0f, margin %.0f, skyTouched %@",
                                                 horiz, sightAngle, Double(farthestTerrain), margin, skyTouched ? "yes" : "no"))
                                    if watched {
                                        // Second opinion for the log: the exact march.
                                        let blocked = Self.waterSightlineOccluded(
                                            eyeLat: refLat, eyeLon: refLon,
                                            featLat: hi.lat, featLon: hi.lon,
                                            horiz: horiz, apparentUp: apparentUp,
                                            camElevMeters: camElevMeters, heightScale: heightScale,
                                            curvatureK: curvatureK, dem: dem, far: far)
                                        watch("exact march says: \(blocked ? "blocked" : "CLEAR — depth map disagrees with geometry")")
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
                        watch(String(format: "SHOWN: horiz %.0f, sightAngle %.2f°, bearing %.1f°",
                                     horiz, sightAngle, bearing * 180 / .pi))
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
                        // priority and the info card don't see a bogus 0 m. CARRY the
                        // saddle flag — this copy silently dropped it (init default
                        // false), so every ele-less pass lost its green dot and its
                        // no-summit-snap anchoring ("Easy Pass" bug).
                        let labeled = peak.elevationMeters > 0 ? peak : Peak(
                            id: peak.id, name: peak.name,
                            latitude: peak.latitude, longitude: peak.longitude,
                            elevationMeters: Double(hi.elev).rounded(),
                            prominenceMeters: peak.prominenceMeters,
                            isSaddle: peak.isSaddle)
                        // TRUE-summit anchor for the AR modes: the surveyed
                        // (catalog) elevation, unclamped — the DEM shaves sharp
                        // spire tops (Cutthroat's needle reads 11 m low; true
                        // needles lose ~100 m), and the silhouette pin above
                        // drops the dot to the DRAWN crest, so against the live
                        // camera it sat below the real rock. Bounded to +120 m
                        // over the DEM snap so a junk OSM ele tag can't launch
                        // a dot into the sky.
                        let trueElev = !isWater && peak.elevationMeters > Double(hi.elev)
                            ? min(peak.elevationMeters, Double(hi.elev) + 120)
                            : Double(hi.elev)
                        let trueUp = trueElev * heightScale - curvatureK * horiz * horiz - camElevMeters
                        res[i] = .init(
                            peak: labeled,
                            direction: SIMD3<Float>(Float(east), Float(north), Float(placedUp)),
                            distanceMeters: horiz,
                            isWater: isWater,
                            isSavedSpot: isSavedSpot,
                            directionTrue: isWater || isSavedSpot ? nil
                                : SIMD3<Float>(Float(east), Float(north), Float(trueUp)))
                    }
                    // ---- Same-name lake dedup ---------------------------------
                    // The catalog can carry TWO label points for one lake
                    // (Kachess Lake: one on the water, one stray on the eastern
                    // hillside whose water-snap latched onto a flat bench 330 m
                    // ABOVE the surface — two dots, one riding the hill). Rank
                    // same-named anchored lakes by how trustworthy their snap
                    // was — the smallest candidate RING first (its label sat
                    // nearest real water), then the lower surface, then id —
                    // and drop later ones within 6 km of the winner when their
                    // surfaces clearly describe the same lake (≤3 m apart:
                    // split arms of one reservoir) or a bogus perch (>15 m
                    // apart: a bench impostor). The 3–15 m middle band stays:
                    // genuine same-named twin tarns at stepped surfaces.
                    for li in peaks.count..<lakeEnd where res[li] != nil {
                        let name = lakes[li - peaks.count].name.lowercased()
                        for lj in peaks.count..<lakeEnd where lj != li
                            && res[lj] != nil
                            && lakes[lj - peaks.count].name.lowercased() == name {
                            // Rank: (ring, elev, id) — the winner survives.
                            let a = (wm[li].ring, wm[li].elev, lakes[li - peaks.count].id)
                            let b = (wm[lj].ring, wm[lj].elev, lakes[lj - peaks.count].id)
                            guard a < b, let di = res[li], let dj = res[lj] else { continue }
                            let dx = Double(dj.direction.x - di.direction.x)
                            let dy = Double(dj.direction.y - di.direction.y)
                            let apart = (dx * dx + dy * dy).squareRoot()
                            let dElev = abs(wm[lj].elev - wm[li].elev)
                            if apart < 6_000, dElev <= 3 || dElev > 15 {
                                NSLog("lakeDedup: would drop %@ (elev %.0f) for %@ (elev %.0f), %.0f m apart",
                                      lakes[lj - peaks.count].name, Double(wm[lj].elev),
                                      lakes[li - peaks.count].name, Double(wm[li].elev), apart)
                                res[lj] = nil
                                verd[lj] = Verdict.skipped.rawValue
                            }
                        }
                    }
                }
                }
            }
            let all = results.compactMap { $0 }
            // Ring-drawn peaks (and far-tier water, judged but unlabeled): all
            // stay visible for the card/search; the ultra-prominent peaks
            // among them also carry anchors (in `all`).
            let ringVisibleIDs = (0..<total).lazy
                .filter { verdicts[$0] == Verdict.ringVisible.rawValue }
                .map { $0 < peaks.count ? peaks[$0].id
                    : $0 < lakeEnd ? lakes[$0 - peaks.count].id : savedSpots[$0 - lakeEnd].id }
            let occludedCount = verdicts.lazy.filter { $0 == Verdict.occluded.rawValue }.count
            let floatingCount = verdicts.lazy.filter { $0 == Verdict.floating.rawValue }.count
            let ringCount = ringVisibleIDs.count
            let inRangeCount = occludedCount + floatingCount + all.count + ringCount
            NSLog("Occlusion: %d in-range, %d occluded, %d floating, %d shown, %d ring-visible",
                  inRangeCount, occludedCount, floatingCount, all.count, ringCount)
            // EVERY visible peak gets an anchor: a peak cut here can never appear
            // at ANY zoom (the overlay's declutter is zoom-scaled, this isn't), so
            // a tight cap made "Visible" info cards for summits that could never
            // be labeled — from Mount Stuart, ~1300 peaks are in range and the old
            // 400-by-priority cap ranked an unlabeled 12 km neighbor ~800th
            // (unknown prominence falls back to elevation·0.25). The caps below
            // are BACKSTOPS against pathological OSM density (an Alpine summit
            // with thousands of named neighbors would bloat the overlay's layer
            // pool and its O(n·kept) declutter pass), not curation: what draws at
            // a given zoom is decided by the overlay, and zooming all the way in
            // reveals everything that survives here. Peaks rank by prominence/
            // elevation (a distant giant SHOULD win a backstop fight); lakes rank
            // DISTANCE-WEIGHTED — elevation alone made the cap a lottery among
            // hundreds of equal-height alpine tarns, dropping the one right below
            // the viewer in favor of look-alikes 80 km out.
            var peaksOut = all.filter { !$0.isWater && !$0.isSavedSpot }
            var lakesOut = all.filter { $0.isWater }
            // User saved spots bypass the priority backstop entirely — there are
            // only ever a handful, and they must always survive to the overlay.
            let savedOut = all.filter { $0.isSavedSpot }
            peaksOut.sort { $0.peak.priority > $1.peak.priority }
            let peaksShown = peaksOut.count
            let lakesShown = lakesOut.count
            lakesOut.sort {
                $0.peak.priority / max(1, $0.distanceMeters) >
                $1.peak.priority / max(1, $1.distanceMeters)
            }
            if peaksOut.count > 2000 {
                NSLog("Anchor backstop: dropping %d of %d visible peaks",
                      peaksOut.count - 2000, peaksShown)
                peaksOut = Array(peaksOut.prefix(2000))
            }
            if lakesOut.count > 200 { lakesOut = Array(lakesOut.prefix(200)) }
            if labelDebug {
                NSLog("labelDebug lakes: %d visible, %d kept after cap", lakesShown, lakesOut.count)
            }
            // The visible set is PRE-backstop (a trimmed summit is still
            // line-of-sight visible) and includes the unlabeled ring giants —
            // the info card and search stay honest either way.
            return (peaksOut + lakesOut + savedOut, Set(all.map(\.peak.id)).union(ringVisibleIDs))
        }

        /// Debug: `-labelDebug` logs every cull (with the blocking terrain for
        /// occlusions) for anchors within 10 km — for diagnosing missing labels.
        static let labelDebug = ProcessInfo.processInfo.arguments.contains("-labelDebug")

        /// Debug (`-labelWatch <name>`): log the FULL anchor decision chain for
        /// any feature whose name contains the needle — which gate skipped it,
        /// or the occlusion numbers behind its verdict.
        static let labelWatch: String? = {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-labelWatch"), i + 1 < a.count else { return nil }
            return a[i + 1].lowercased()
        }()

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
        static func waterSightlineOccluded(
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

        /// Bake the panorama off the main thread — always at FULL resolution.
        /// FIRST image: the loading readout stays up until the full-res bake
        /// installs (there used to be a quick 2048-wide preview pass first, but
        /// it flashed a soft image that visibly sharpened ~a second later —
        /// binned in favor of arriving crisp). RE-BAKES (teleport,
        /// exaggeration): the current full-res scene stays on screen — labels
        /// and all — until the new FULL-res image is ready, then everything
        /// swaps at once. A generation token discards a stale bake if a newer
        /// viewpoint/exaggeration has been requested.
        ///
        /// The readout sweeps `progressFrom → 0.95` on real band completions
        /// (32+ ticks at full res), holds at 0.95 while the label anchors land,
        /// and `.ready` closes it out — pass 0.85 after a tile fetch so the bar
        /// continues where the tiles left off, 0 when there was no tile phase.
        /// `reportProgress: false` = a silent top-up (e.g. the far-horizon ring
        /// landing after the main bake): the panorama is already on screen, so
        /// re-reporting would drag the progress readout backward and then pin
        /// it at ~96% while terrain is visibly fine.
        /// `reuseAnchors: true` = swap in the LAST delivered anchor set instead
        /// of rebuilding — only for re-bakes whose anchors can't have changed
        /// (the ring top-up when the anchors already reflect the current ring):
        /// the rebuild re-judged ~30k peaks (~2 s of CPU) for an identical set,
        /// and the swap (with the ring haze) waited on it.
        /// `paced` (silent top-ups only): space the bake's bands a frame apart
        /// so the just-swapped scene pans smoothly while the ring haze streams
        /// in behind it — see `TerrainRenderer.bakePanoramaAsync`.
        private func bakeProgressive(progressFrom: Double, reportProgress: Bool = true,
                                     reuseAnchors: Bool = false, paced: Bool = false,
                                     onReady: @escaping () -> Void) {
            guard let renderer = renderer, dem != nil else { onReady(); return }
            bakeGeneration &+= 1
            let gen = bakeGeneration
            let t0 = DispatchTime.now()
            let span = 0.95 - progressFrom
            if reportProgress { report(.rendering(progress: progressFrom)) }
            let onBand: (Double) -> Void = { [weak self] f in
                guard let self, gen == self.bakeGeneration, reportProgress else { return }
                self.report(.rendering(progress: progressFrom + span * f))
            }
            if panoInstalled {
                rebakePending = true
                pendingPanoTex = nil
                pendingOnReady = onReady
                if reuseAnchors, let last = lastAnchorState {
                    // Anchors are already correct for this scene: stage them for
                    // the swap directly — the bake is the only thing to wait for.
                    // The overlay already holds this exact set, so the swap leaves
                    // its dots in place (see pendingAnchorsUnchanged).
                    pendingAnchors = (last.anchors, last.visibleIDs)
                    pendingAnchorsUnchanged = true
                } else {
                    pendingAnchors = nil
                    pendingAnchorsUnchanged = false
                    // The new labels compute concurrently with the bake (they render
                    // their own depth map from the new uniforms, independent of the
                    // displayed image); `installAnchors` stashes the result and the
                    // swap fires once BOTH image and labels are ready.
                    rebuildLabelAnchors()
                }
                renderer.panoramaWidth = Self.fullPanoramaWidth
                bakeOnce(paced: paced, onProgress: onBand) { [weak self] tex in
                    guard let self else { return }
                    guard gen == self.bakeGeneration else { return }  // superseded: the newer bake swaps
                    guard let tex else {
                        // Bake failed (e.g. backgrounded mid-bake): keep the old
                        // scene WHOLE — drop the new-viewpoint anchors too (they'd
                        // float over the old image) — and retry on foreground.
                        self.anchorRebuildWork?.cancel()
                        self.labelGeneration &+= 1
                        self.anchorBuildInFlight = false
                        // Never strand a held first-scene .ready (see installAnchors).
                        if let cb = self.onAnchorsInstalled { self.onAnchorsInstalled = nil; cb() }
                        self.pendingAnchors = nil
                        self.pendingAnchorsUnchanged = false
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
            // First image for this scene: straight to full resolution — the
            // loading readout (fed band-by-band via onBand) covers the wait.
            // Labels build CONCURRENTLY with the bake (their own depth pass,
            // exactly like re-bake swaps), and `.ready` holds until they've
            // installed — the loading screen lifts on terrain WITH its labels
            // instead of the labels streaming in a beat later.
            rebuildLabelAnchors()
            renderer.panoramaWidth = Self.fullPanoramaWidth
            bakeOnce(paced: paced, onProgress: onBand) { [weak self] tex in
                guard let self, gen == self.bakeGeneration else { onReady(); return }
                guard let tex, let renderer = self.renderer else {
                    self.needsRebakeOnActivate = true                 // retry on foreground
                    onReady()
                    return
                }
                renderer.installPanorama(tex)
                // First install: sky + theme + celestial land with the terrain.
                self.skySunENU = self.bakeSunENU
                self.reportNight()
                self.applyPendingCelestialIfCurrent()
                self.panoInstalled = true
                self.view?.setNeedsDisplay()
                NSLog("Full bake (w=%d) %.0f ms — %@", Self.fullPanoramaWidth, Self.ms(since: t0),
                      self.anchorBuildInFlight ? "waiting for labels" : "labels already in")
                // `.ready` (the loading-cover lift) waits for BOTH overlays:
                // first the label anchors, then the celestial pass (sun/moon
                // arcs + stars) — otherwise whichever loses the race against
                // the bake pops in a beat after the reveal.
                let awaitCelestialThenReady = { [weak self] in
                    guard let self else { onReady(); return }
                    let celestialCurrent = {
                        guard let ref = self.celestialRef else { return false }
                        return abs(ref.lat - self.refLat) < 1e-6
                            && abs(ref.lon - self.refLon) < 1e-6
                    }
                    // Consume any stash that raced in between the install above
                    // and this barrier (it would otherwise wait forever — the
                    // first-load path never runs the swap that drains it).
                    if !celestialCurrent() { self.applyPendingCelestialIfCurrent() }
                    if celestialCurrent() {
                        onReady()
                    } else {
                        self.onCelestialInstalled = onReady
                    }
                }
                if self.anchorBuildInFlight {
                    self.onAnchorsInstalled = awaitCelestialThenReady
                } else {
                    awaitCelestialThenReady()
                }
            }
        }

        private func bakeOnce(paced: Bool = false, onProgress: ((Double) -> Void)? = nil,
                              _ done: @escaping (MTLTexture?) -> Void) {
            guard let renderer = renderer, dem != nil else { done(nil); return }
            var u = makeUniforms(width: 1, height: 1)
            // The bake lights for its OWN scene (new viewpoint/date), while the
            // live uniforms keep the displayed scene's sun until the swap.
            u.skySunDir = SIMD4<Float>(bakeSunENU, 0)
            u.skySunElDeg = asin(max(-1, min(1, bakeSunENU.z))) * 180 / .pi
            u.terrainBright = Self.terrainBright(sunElDeg: u.skySunElDeg)
            dem?.applyDEMUniforms(to: &u, refLat: refLat, refLon: refLon)
            // Far tier overrides globalMaxHeight (it spans the whole scene).
            demFar?.applyFarDEMUniforms(to: &u, refLat: refLat, refLon: refLon)
            renderer.bakePanoramaAsync(uniforms: u, paced: paced,
                                       onProgress: onProgress, completion: done)
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
            // Sun elevation + terrain dimming, hoisted off the per-pixel view pass.
            u.skySunElDeg = asin(max(-1, min(1, skySunENU.z))) * 180 / .pi
            u.terrainBright = Self.terrainBright(sunElDeg: u.skySunElDeg)
            // In AR, lock the projection's vertical FOV to the real on-screen camera
            // FOV so the overlay tracks the world (no scale drift as you tilt/pan).
            // Eased on entry (arRampedTanHalf) so any FOV change left after the
            // matched crop reads as a transition, not a pop.
            if mode.usesCamera, width > 2, height > 2 {
                if let tanV = arVerticalTanHalfFov(drawableW: width, drawableH: height) {
                    u.tanHalfFovY = arRampedTanHalf(target: tanV)
                }
            } else if width > 2, height > 2, arFovRampFrom > 0 {
                // Eased restore of a clamp-eaten 3D zoom on AR exit (see
                // setMode): same ramp, target = the restored 3D fov.
                u.tanHalfFovY = arRampedTanHalf(target: tanf(fov * .pi / 360))
            }
            return u
        }

        /// 3D→AR FOV transition: eased over ~0.35 s from the FOV on screen at the
        /// switch (`arFovRampFrom`, armed by setMode) to the camera's true FOV.
        /// Starts the moment the camera FOV is first known — usually during the
        /// opaque-3D warmup hold, so by reveal the projection already matches the
        /// feed; at worst the tail of the ramp overlaps the reveal briefly.
        /// Labels and sky project with the same uniforms, so they stay glued
        /// throughout. Once complete (`arFovRampFrom = 0`) this is a passthrough.
        private var arFovRampStart: CFTimeInterval?
        private var arFovRampFrom: Float = 0
        private static let arFovRampDuration: CFTimeInterval = 0.35

        private func arRampedTanHalf(target: Float) -> Float {
            guard arFovRampFrom > 0 else { return target }
            let now = CACurrentMediaTime()
            guard let start = arFovRampStart else {
                arFovRampStart = now
                return arFovRampFrom
            }
            let t = Float(min(1, (now - start) / Self.arFovRampDuration))
            if t >= 1 {
                arFovRampFrom = 0
                return target
            }
            // Device-tracked AR renders continuously, but on the no-IMU fallback
            // the loop is on-demand — keep frames coming until the ramp lands.
            if view?.isPaused == true { view?.setNeedsDisplay() }
            let s = t * t * (3 - 2 * t)
            return arFovRampFrom + (target - arFovRampFrom) * s
        }

        /// Terrain brightness for the view pass: full by day, a 0.34 "moonlit"
        /// floor at night. MUST mirror the smoothstep the shader used to compute
        /// per pixel (see panoramaViewFragment's terrainBright before the hoist).
        private static func terrainBright(sunElDeg: Float) -> Float {
            let t = max(0, min(1, (sunElDeg + 7) / 12))   // smoothstep(-7, 5, el)
            let s = t * t * (3 - 2 * t)
            return 0.34 + 0.66 * s
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
            // ANY device-tracked view (AR or 3D): drag nudges a calibration
            // offset on top of the live tracking — AXIS-LOCKED to yaw
            // (horizontal drag) or the pitch trim (vertical drag), decided by
            // the drag's first centimeter and held for the whole gesture. One
            // finger serves both axes precisely BECAUSE of the lock: fixing
            // the horizontal alignment can't disturb the vertical one, and
            // vice versa — no diagonal drift. The view keeps following the
            // phone.
            if let basis = deviceBasis, mode.usesCamera || !manualAlignment {
                applyAlignDrag(g, in: v, basis: basis)
                if g.state == .ended { onAlignmentNudged() }
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
            if g.state == .ended { onAlignmentNudged() }
            v.setNeedsDisplay()
        }

        /// Axis lock for the one-finger align drag: `.undecided` while the
        /// first ~10 pt of movement accumulates, then yaw or pitch for the
        /// REST of the gesture — either left↔right or up↕down, never diagonal.
        private enum AlignAxis { case undecided, yaw, pitch }
        private var alignAxis = AlignAxis.undecided
        private var alignAccum = CGPoint.zero

        /// One-finger drag alignment on top of device tracking. Scaled by the
        /// rendered focal length → 1 finger-point ≈ the angle that point
        /// subtends on screen, so the overlay drags 1:1 with the image (AR
        /// uses the real camera FOV).
        ///
        /// The offsets live in WORLD space while the finger moves in SCREEN
        /// space — the drag is decomposed along the on-screen GRAVITY axes
        /// (same right.z/up.z construction the label overlay uses), so a
        /// rolled/landscape phone keeps "along the horizon" turning the view
        /// and "toward the sky" trimming pitch. Level portrait ⇒ the screen
        /// axes exactly. Grab-the-world in both: drag right moves the overlay
        /// right (camera yaws left); drag down pulls the overlay down onto
        /// terrain it floated above (camera pitches up). Pitch stays a ±8°
        /// TRIM — it corrects elevation-data error at the eye, not look-around.
        private func applyAlignDrag(_ g: UIPanGestureRecognizer, in v: MTKView,
                                    basis: DeviceAttitude.Basis) {
            if g.state == .began { alignAxis = .undecided; alignAccum = .zero }
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            let tanHalfV: Double = mode.usesCamera
                ? Double(arVerticalTanHalfFov(drawableW: Int(v.bounds.width),
                                              drawableH: Int(v.bounds.height))
                         ?? tanf(fov * .pi / 360))
                : Double(tanf(fov * .pi / 360))
            let focalPoints = Double(v.bounds.height) / 2 / max(1e-4, tanHalfV)
            let pointsPerDeg = focalPoints * .pi / 180
            // Screen → gravity axes (screen axes as the fallback when gravity
            // is edge-on to the screen).
            var gRight = (x: 1.0, y: 0.0), gDown = (x: 0.0, y: 1.0)
            let gLen = hypot(Double(basis.right.z), Double(basis.up.z))
            if gLen > 0.2 {
                let gUpX = Double(basis.right.z) / gLen, gUpY = -Double(basis.up.z) / gLen
                gRight = (x: -gUpY, y: gUpX)
                gDown = (x: -gUpX, y: -gUpY)
            }
            func along(_ a: (x: Double, y: Double), _ p: CGPoint) -> Double {
                Double(p.x) * a.x + Double(p.y) * a.y
            }
            var applied = t
            if alignAxis == .undecided {
                // Buffer until the direction is unambiguous, then apply the
                // WHOLE buffered movement so the lock doesn't eat the first
                // centimeter of drag.
                alignAccum.x += t.x
                alignAccum.y += t.y
                guard hypot(alignAccum.x, alignAccum.y) >= 10 else { return }
                let h = along(gRight, alignAccum), d = along(gDown, alignAccum)
                alignAxis = abs(h) >= abs(d) ? .yaw : .pitch
                applied = alignAccum
            }
            switch alignAxis {
            case .yaw:
                arYawOffsetDeg += -along(gRight, applied) / pointsPerDeg
            case .pitch:
                arPitchOffsetDeg = max(-8, min(8,
                    arPitchOffsetDeg + along(gDown, applied) / pointsPerDeg))
            case .undecided:
                return
            }
            reportARAdjusted()
            v.setNeedsDisplay()
        }

        /// Apply the AR calibration offsets to the live device basis: yaw about
        /// world-up (Z) — roll-independent, keeps the horizon level — then the
        /// pitch trim about the horizontal axis perpendicular to forward (so it
        /// raises/lowers the view without banking the horizon).
        private func arCalibrated(_ b: DeviceAttitude.Basis) -> DeviceAttitude.Basis {
            var out = b
            if arYawOffsetDeg != 0 {
                // +yaw offset = +azimuth (clockwise from north); a +Z rotation
                // DECREASES clockwise azimuth, so rotate by -offset about +Z.
                let qYaw = simd_quatf(angle: Float(-arYawOffsetDeg * .pi / 180),
                                      axis: SIMD3(0, 0, 1))
                out = DeviceAttitude.Basis(forward: qYaw.act(out.forward),
                                           right: qYaw.act(out.right),
                                           up: qYaw.act(out.up))
            }
            if arPitchOffsetDeg != 0 {
                let f = out.forward
                let len = (f.x * f.x + f.y * f.y).squareRoot()
                if len > 1e-4 {
                    // Horizontal right-of-forward axis; +rotation pitches up.
                    let axis = SIMD3<Float>(f.y / len, -f.x / len, 0)
                    let qP = simd_quatf(angle: Float(arPitchOffsetDeg * .pi / 180), axis: axis)
                    out = DeviceAttitude.Basis(forward: qP.act(out.forward),
                                               right: qP.act(out.right),
                                               up: qP.act(out.up))
                }
            }
            return out
        }

        /// Clear the AR adjustment (back to pure device tracking).
        func recenterAR() {
            guard arYawOffsetDeg != 0 || arPitchOffsetDeg != 0 else { return }
            arYawOffsetDeg = 0
            arPitchOffsetDeg = 0
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
            let adjusted = (arYawOffsetDeg != 0 || arPitchOffsetDeg != 0)
            guard adjusted != lastReportedARAdjusted else { return }
            lastReportedARAdjusted = adjusted
            let cb = onARAdjustedChanged
            DispatchQueue.main.async { cb(adjusted) }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let v = view else { return }
            // AR magnification is LOCKED to the camera's native 1x — a digital
            // crop trades alignment accuracy for zoom (see setMode), so the
            // pinch only zooms the 3D view.
            guard !mode.usesCamera else { return }
            if g.state == .began { pinchStartFov = fov }
            fov = max(15, min(90, pinchStartFov / Float(g.scale)))
            v.setNeedsDisplay()
        }

        /// Immersive chrome-hide: the compass + zoom readout are drawn inside
        /// this view (not RootScreen), so they hide here.
        private var immersiveChrome = false

        /// ft↔m flip: re-set the overlay's anchors so every baked elevation
        /// string re-measures and re-renders in the new units.
        private var unitsStamp = ""
        func setUnitsStamp(_ stamp: String) {
            guard stamp != unitsStamp else { return }
            unitsStamp = stamp
            if let overlay = container?.labelOverlay {
                let anchors = overlay.anchors   // re-set triggers the re-bake
                overlay.anchors = anchors
            }
        }

        /// 12h↔24h flip: re-run the celestial pass so the rise/set ↑/↓ tags
        /// re-format (the strings are baked in rebuildCelestial). Cheap — no DEM
        /// march, just ephemeris + formatting against the cached skyline.
        private var clockStamp = ""
        func setClockStamp(_ stamp: String) {
            guard stamp != clockStamp else { return }
            clockStamp = stamp
            rebuildCelestial()
        }

        func setImmersive(_ hidden: Bool) {
            immersiveChrome = hidden
            refreshOverlayVisibility()
        }

        func refreshOverlayVisibility() {
            container?.compassZoom.isHidden = immersiveChrome
            container?.labelOverlay.isHidden = false
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
            // Nothing under the tap: clearing a sky-object tag counts as the
            // tap's job — RootScreen only toggles immersive on a tap that
            // dismissed nothing at all.
            let clearedSkyTag = container?.skyArc.selectedSkyName != nil
            container?.skyArc.selectedSkyName = nil
            if clearedSkyTag { view?.setNeedsDisplay() }
            onEmptyTap(clearedSkyTag)
        }

        /// The cached terrain skyline (ring included), interpolated at an
        /// azimuth — the same lookup the celestial pass uses. nil before the
        /// first horizon march completes.
        private func horizonElevationDeg(atAzimuthDeg azDeg: Double) -> Double? {
            guard let horizon = cachedHorizon, !horizon.isEmpty else { return nil }
            let n = horizon.count
            var a = azDeg.truncatingRemainder(dividingBy: 360); if a < 0 { a += 360 }
            let x = a / 360 * Double(n) - 0.5
            let i0 = Int(floor(x))
            let f = x - Double(i0)
            let a0 = horizon[((i0 % n) + n) % n]
            let a1 = horizon[((i0 + 1) % n + n) % n]
            return Double(a0) * (1 - f) + Double(a1) * f
        }

        private var pinnedPeakIDs: Set<String> = []
        func setPinnedPeaks(_ ids: Set<String>) {
            guard ids != pinnedPeakIDs else { return }
            pinnedPeakIDs = ids
            container?.labelOverlay.pinnedPeakIDs = ids
            view?.setNeedsDisplay()
        }

        func setSelectedPeak(_ annotated: AnnotatedPeak?) {
            // Compare the WHOLE annotation, not just the id: after a location
            // change the model RE-annotates the same peak (fresh bearing/
            // angle/distance for the new eye), and an id-only guard swallowed
            // that refresh — the off-screen direction marker then kept the old
            // viewpoint's elevation angle, floating high in the new sky.
            guard annotated != selectedAnnotated else { return }
            selectedAnnotated = annotated
            container?.labelOverlay.selectedPeakID = annotated?.id
            // Direction marker (az/el/distance fully define the screen direction, so no
            // DEM lookup needed): shown by the overlay only when the peak isn't already
            // an on-screen label.
            container?.labelOverlay.target = annotated.map { a in
                let az = a.azimuthDeg * .pi / 180
                var elDeg = a.elevationAngleDeg
                // Ring-range peaks (beyond the far tile): the drawn silhouette
                // is the max-pooled ETOPO ring, which understates a sharp
                // summit — the TRUE sightline angle then floats in the sky
                // above the drawn haze (Everest from Manaslu North). Pin the
                // marker to the drawn skyline, exactly like ring anchors do.
                if a.distanceMeters > FarHorizon.farTileMeters,
                   let ridge = horizonElevationDeg(atAzimuthDeg: a.azimuthDeg) {
                    elDeg = min(elDeg, ridge)
                }
                let el = elDeg * .pi / 180
                let dist = max(1, a.distanceMeters)
                return PeakLabelOverlayView.Target(
                    id: a.id, name: a.peak.displayName,
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

        /// Mode actually drawn right now: AR modes hold the opaque 3D scene until
        /// the camera's first frame lands, so nothing flashes black.
        private var effectiveMode: TerrainViewMode {
            (mode.usesCamera && !cameraRevealed) ? .threeD : mode
        }

        /// Uniforms for THIS frame. Device alignment overrides the az/pitch basis
        /// with the live device orientation (the bake is orientation-independent,
        /// so only the per-frame resample changes). Every device-tracked view (AR
        /// and 3D) also applies the drag calibration yaw offset; 3D falls back to
        /// gestures only when manual look-around is on (no-IMU environments).

        private func currentUniformsWithDeviceBasis(width: Int, height: Int) -> Uniforms {
            var uniforms = makeUniforms(width: width, height: height)
            if let basis = deviceBasis, mode.usesCamera || !manualAlignment {
                let b = arCalibrated(basis)
                uniforms.forward = SIMD4<Float>(b.forward, 0)
                uniforms.right = SIMD4<Float>(b.right, 0)
                uniforms.up = SIMD4<Float>(b.up, 0)
            }
            return uniforms
        }

        /// Encode the current mode's view pass into `target`.
        private func encodeScene(uniforms: Uniforms, into target: MTLTexture,
                                 commandBuffer cb: MTLCommandBuffer, renderer: TerrainRenderer) {
            switch effectiveMode {
            case .threeD:
                renderer.encodeView(uniforms: uniforms, into: target, commandBuffer: cb)
            case .arRelief:
                renderer.encodeViewAR(uniforms: uniforms, into: target, commandBuffer: cb)
            case .arEdges:
                renderer.encodeViewEdges(uniforms: uniforms, into: target, commandBuffer: cb)
            case .arLabels:
                renderer.encodeClearTransparent(into: target, commandBuffer: cb)
            }
        }

        /// Debug (-frameWatch): log inter-frame gaps over 25 ms — how re-bake
        /// GPU contention (the post-move pan jitter) is measured headlessly.
        private static let frameWatch = ProcessInfo.processInfo.arguments.contains("-frameWatch")
        private var lastDrawTime: CFTimeInterval = 0

        func draw(in view: MTKView) {
            if Self.frameWatch {
                let now = CACurrentMediaTime()
                if lastDrawTime > 0, now - lastDrawTime > 0.025 {
                    NSLog("frameWatch gap %.0f ms", (now - lastDrawTime) * 1000)
                }
                lastDrawTime = now
            }
            guard let renderer = renderer,
                  let drawable = view.currentDrawable else { return }
            let w = Int(view.drawableSize.width)
            let h = Int(view.drawableSize.height)
            guard w > 0, h > 0 else { return }

            // Pull the freshest device attitude for THIS frame (zero queuing lag).
            if motionDrivesCamera { sampleDeviceBasis() }

            let uniforms = currentUniformsWithDeviceBasis(width: w, height: h)
            guard let cb = renderer.commandQueue.makeCommandBuffer() else { return }
            encodeScene(uniforms: uniforms, into: drawable.texture, commandBuffer: cb, renderer: renderer)
            cb.commit()
            // NOTE: the drawable is presented at the END of this method (after
            // the overlay layers below are positioned), via waitUntilScheduled +
            // present — with presentsWithTransaction, that lands the Metal frame
            // and the CALayer overlays in the SAME screen update. Presenting
            // up here let the terrain move a frame ahead of the labels.

            // Project peak labels with the EXACT basis/FOV the GPU just used, so they
            // land on the rendered summits and track as the view moves.
            let fwd = SIMD3<Float>(uniforms.forward.x, uniforms.forward.y, uniforms.forward.z)
            let rgt = SIMD3<Float>(uniforms.right.x, uniforms.right.y, uniforms.right.z)
            let upv = SIMD3<Float>(uniforms.up.x, uniforms.up.y, uniforms.up.z)
            container?.skyArc.project(forward: fwd, right: rgt, up: upv,
                                      tanHalfFovY: uniforms.tanHalfFovY, aspect: uniforms.aspect)
            // Magnification relative to the 3D default (60° vertical), from the
            // projection FOV actually rendered this frame — drives the label
            // density gate in both modes. The READOUT shows a flat 1.0x in AR:
            // the magnification there is locked to the camera's native lens
            // (like the Camera app's 1x), not a zoom the user can change.
            let zoom = Self.baseTanHalf60 / max(1e-4, uniforms.tanHalfFovY)
            container?.labelOverlay.project(forward: fwd, right: rgt, up: upv,
                                            tanHalfFovY: uniforms.tanHalfFovY, aspect: uniforms.aspect,
                                            zoom: zoom)
            var headingDeg = atan2(Double(fwd.x), Double(fwd.y)) * 180 / .pi
            if headingDeg < 0 { headingDeg += 360 }
            container?.compassZoom.update(headingDeg: headingDeg,
                                          zoom: mode.usesCamera ? 1 : Double(zoom))

            // All overlay layers are now positioned for this frame — put the
            // Metal image on screen in the same CoreAnimation transaction.
            cb.waitUntilScheduled()
            drawable.present()
        }

        /// tan(30°) — the 60° reference FOV's half-angle tangent, hoisted from
        /// the per-frame draw path.
        private static let baseTanHalf60 = tanf(60.0 * .pi / 360)
    }
}
