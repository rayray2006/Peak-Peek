import SwiftUI
import MetalKit
import simd
import CoreMotion
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

    var title: String {
        switch self {
        case .threeD: return "3D"
        case .arRelief: return "AR"
        case .arEdges: return "Edges"
        }
    }

    var systemImage: String {
        switch self {
        case .threeD: return "mountain.2"
        case .arRelief: return "camera.viewfinder"
        case .arEdges: return "scribble.variable"
        }
    }

    var next: TerrainViewMode {
        switch self {
        case .threeD: return .arRelief
        case .arRelief: return .arEdges
        case .arEdges: return .threeD
        }
    }

    var usesCamera: Bool { self != .threeD }
}

struct TerrainMetalView: UIViewRepresentable {
    var viewpoint: PanoramaViewModel.Viewpoint?
    var exaggeration: Double = 1.0
    /// Display mode: 3D relief, AR relief, or AR edges.
    var mode: TerrainViewMode = .threeD
    /// Manual alignment: look around by dragging instead of moving the phone.
    var manualAlignment: Bool = false
    /// Named peaks to label (projected onto the rendered terrain).
    var peaks: [Peak] = []
    /// Currently selected peak's id (highlighted), and the tap callback (nil = a tap
    /// that hit no label).
    var selectedPeakID: String?
    var onSelectPeak: (Peak?) -> Void = { _ in }
    var onStatus: (PanoramaViewModel.Status) -> Void = { _ in }
    var onEyeElevation: (Double?) -> Void = { _ in }
    /// Live heading (degrees, 0 = N) and zoom factor (×), throttled, for the HUD.
    var onHeading: (Double) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    /// Fired when the view force-switches to manual (no IMU) so the HUD can match.
    var onForceManual: () -> Void = { }

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
        context.coordinator.setExaggeration(Float(exaggeration))
        context.coordinator.setManualAlignment(manualAlignment)
        context.coordinator.setMode(mode)
        context.coordinator.setPeaks(peaks)
        context.coordinator.onSelectPeak = onSelectPeak
        context.coordinator.setSelectedPeakID(selectedPeakID)
        if let vp = viewpoint {
            context.coordinator.requestViewpoint(lat: vp.latitude, lon: vp.longitude)
        }
    }

    /// Hosts the live-camera preview layer behind the terrain `MTKView`. In 3D mode
    /// the preview is hidden and the metal view is opaque; in AR mode the preview
    /// shows and the metal view goes transparent so terrain composites over it.
    final class TerrainContainerView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
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
            addSubview(metalView)
            addSubview(skyArc)               // sky under the labels
            addSubview(labelOverlay)         // labels on top of the terrain
            addSubview(compassZoom)          // compass + zoom on top
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            metalView.frame = bounds
            skyArc.frame = bounds
            labelOverlay.frame = bounds
            compassZoom.frame = bounds
            if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90    // lock preview to portrait
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: TerrainRenderer?
        private var demTexture: MTLTexture?
        private var dem: DEMTile?
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
        private var deviceBasis: DeviceAttitude.Basis?
        private var smoothedOrientation: simd_quatf?
        var motionAvailable: Bool { motionManager.isDeviceMotionAvailable }

        // Display mode + AR camera.
        let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.example.mountainView.ar.session")
        weak var container: TerrainContainerView?
        private var mode: TerrainViewMode = .threeD
        private var manualAlignment = false
        private var didForceManual = false

        // Peak labels.
        private var peaks: [Peak] = []
        private var labelGeneration = 0
        var onSelectPeak: (Peak?) -> Void = { _ in }
        private var selectedPeakID: String?

        // HUD reporting throttle (heading/zoom).
        private var lastHeadingReport: CFTimeInterval = 0
        private var lastHeading: Double = .nan
        private var lastZoom: Double = .nan

        // Viewpoint bookkeeping.
        private var lastRequested: (lat: Double, lon: Double)?
        private var isReloading = false
        /// Bumped per bake request; a completing bake whose token is stale (a newer
        /// viewpoint/exaggeration was requested) is discarded instead of installed.
        private var bakeGeneration = 0
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
            if let i = args.firstIndex(of: "-az"), i + 1 < args.count, let a = Float(args[i + 1]) { azimuth = a }
            if let i = args.firstIndex(of: "-pitch"), i + 1 < args.count, let p = Float(args[i + 1]) { pitch = p }
            if let i = args.firstIndex(of: "-fov"), i + 1 < args.count, let f = Float(args[i + 1]) { fov = f }
            startMotion()
            // No auto-load: the view model drives the first viewpoint (GPS/demo)
            // via updateUIView → requestViewpoint.
        }

        // MARK: Device motion

        /// Stream device attitude and drive the camera from it. Prefers true-north
        /// referencing so the heading lines up with the panorama's real azimuths,
        /// falling back to magnetic north if true north is unavailable.
        private func startMotion() {
            guard motionManager.isDeviceMotionAvailable else { return }
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            beginMotionUpdates(frame: .xTrueNorthZVertical)
        }

        private func beginMotionUpdates(frame: CMAttitudeReferenceFrame) {
            if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
            motionManager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, error in
                guard let self else { return }
                if error != nil {
                    if frame == .xTrueNorthZVertical {
                        self.beginMotionUpdates(frame: .xMagneticNorthZVertical)
                    }
                    return
                }
                guard let m = motion?.attitude.rotationMatrix else { return }
                self.applyAttitude(m)
            }
        }

        /// Convert an attitude sample to the camera basis and ease toward it
        /// (slerp low-pass) to absorb IMU micro-jitter and sudden magnetometer
        /// yaw corrections, then request a redraw.
        private func applyAttitude(_ m: CMRotationMatrix) {
            let basis = DeviceAttitude.cameraBasis(
                m11: m.m11, m12: m.m12, m13: m.m13,
                m21: m.m21, m22: m.m22, m23: m.m23,
                m31: m.m31, m32: m.m32, m33: m.m33)

            // Build a proper (det +1) rotation for slerp: columns (right, up,
            // -forward) are right-handed; forward = -col2 afterwards.
            let rot = simd_float3x3(basis.right, basis.up, -basis.forward)
            var target = simd_quatf(rot)
            if let current = smoothedOrientation {
                if simd_dot(current.vector, target.vector) < 0 {
                    target = simd_quatf(vector: -target.vector)   // shortest path
                }
                target = simd_normalize(simd_slerp(current, target, 0.35))
            }
            smoothedOrientation = target

            let r = simd_float3x3(target)
            deviceBasis = DeviceAttitude.Basis(
                forward: -r.columns.2, right: r.columns.0, up: r.columns.1)
            view?.setNeedsDisplay()
        }

        func stopMotion() {
            motionManager.stopDeviceMotionUpdates()
        }

        // MARK: AR camera

        /// Switch display mode (3D / AR relief / AR edges). Camera turns on for the
        /// two AR modes; the metal view goes non-opaque so terrain composites over
        /// the preview. The bake and look-around are identical across modes.
        func setMode(_ newMode: TerrainViewMode) {
            guard newMode != mode else { return }
            let wasCamera = mode.usesCamera
            mode = newMode
            let usesCamera = newMode.usesCamera
            container?.previewLayer.isHidden = !usesCamera
            if let v = view {
                v.isOpaque = !usesCamera
                v.backgroundColor = usesCamera ? .clear : .black
                (v.layer as? CAMetalLayer)?.isOpaque = !usesCamera
            }
            if usesCamera && !wasCamera { startCamera() }
            else if !usesCamera && wasCamera { stopCamera() }
            view?.setNeedsDisplay()
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
                    }
                    self.session.commitConfiguration()
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

        /// Stand at a new viewpoint. The eye sits at the EXACT coordinate at
        /// ground + 1.6 m (no summit snap), and the surroundings re-bake.
        ///
        /// Fetch avoidance: each fetch downloads/stitches ~80 km of SRTM tiles, so if
        /// the CURRENT tile already covers this point (with a margin of terrain around
        /// the eye), reuse it and skip the network — exploring or GPS-walking within a
        /// region then costs zero downloads.
        func requestViewpoint(lat: Double, lon: Double) {
            if let last = lastRequested,
               abs(last.lat - lat) < 1e-6, abs(last.lon - lon) < 1e-6 { return }
            if isReloading { return }
            lastRequested = (lat, lon)
            isReloading = true
            report(.preparingTerrain)

            // Reuse fast-path: current tile already covers this viewpoint.
            if let tile = dem, tile.contains(lat: lat, lon: lon, marginMeters: 18_000) {
                let ground = tile.elevation(lat: lat, lon: lon)
                refLat = lat; refLon = lon
                groundElev = ground
                recomputeCamElev()
                rebuildLabelAnchors()
                rebuildSky()
                report(.rendering)
                NSLog("Viewpoint reused current tile (no fetch)")
                bakeProgressive {
                    self.isReloading = false
                    self.report(.ready)
                    self.onEyeElevation(Double(ground) + 1.6)
                }
                return
            }

            guard let device = view?.device else { isReloading = false; return }
            Task { [weak self] in
                let t0 = DispatchTime.now()
                var resolved: DEMTile?
                let failure = "No elevation data for this area — check your connection and try again."
                do {
                    resolved = try await DEMFetcher.fetch(lat: lat, lon: lon, radiusMeters: 40_000)
                } catch {
                    if let bundled = self?.bundledTile(), bundled.contains(lat: lat, lon: lon) {
                        resolved = bundled
                        NSLog("DEM fetch failed; using bundled cascades fallback")
                    } else {
                        NSLog("DEM fetch failed: \(error)")
                    }
                }
                guard let tile = resolved else {
                    await MainActor.run {
                        self?.isReloading = false
                        self?.report(.failed(failure))
                    }
                    return
                }
                let tex = tile.makeTexture(device: device)
                let ground = tile.elevation(lat: lat, lon: lon)
                NSLog("DEM ready in %.0f ms (fetch)", Self.ms(since: t0))
                await MainActor.run {
                    guard let self else { return }
                    self.dem = tile
                    self.demTexture = tex
                    self.renderer?.heightTexture = tex
                    self.refLat = lat; self.refLon = lon
                    self.groundElev = ground
                    self.recomputeCamElev()
                    self.rebuildLabelAnchors()
                    self.rebuildSky()
                    self.report(.rendering)
                    self.bakeProgressive {
                        self.isReloading = false
                        self.report(.ready)
                        self.onEyeElevation(Double(ground) + 1.6)
                    }
                }
            }
        }

        /// Change the vertical exaggeration: rescale the eye to sit above the
        /// scaled ground and re-bake. No-op if unchanged or no DEM yet.
        func setExaggeration(_ value: Float) {
            guard abs(value - exaggeration) > 0.001 else { return }
            exaggeration = value
            guard dem != nil else { return }
            recomputeCamElev()
            rebuildLabelAnchors()
            report(.rendering)
            bakeProgressive { self.report(.ready) }
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

        /// Recompute label anchors for the current viewpoint/exaggeration off the main
        /// thread (DEM-snap each peak, fold in curvature + heightScale, line-of-sight
        /// occlusion), then install on main. A generation token drops stale results.
        private func rebuildLabelAnchors() {
            guard let dem else { container?.labelOverlay.anchors = []; return }
            let peaks = self.peaks
            guard !peaks.isEmpty else { container?.labelOverlay.anchors = []; return }
            let refLat = self.refLat, refLon = self.refLon
            let camElevM = Double(self.camElev), hs = Double(self.exaggeration)
            labelGeneration &+= 1
            let gen = labelGeneration
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let anchors = Self.buildAnchors(
                    peaks: peaks, dem: dem, refLat: refLat, refLon: refLon,
                    camElevMeters: camElevM, heightScale: hs)
                DispatchQueue.main.async {
                    guard let self, gen == self.labelGeneration else { return }
                    self.container?.labelOverlay.anchors = anchors
                    self.view?.setNeedsDisplay()
                }
            }
        }

        /// Compute the sun/moon day paths for this viewpoint (off-main) and hand the
        /// precomputed ENU directions to the sky overlay. Independent of look
        /// direction (the overlay projects per frame).
        private func rebuildSky() {
            let lat = refLat, lon = refLon
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let now = Date()
                let sun = Ephemeris.windowPath(of: .sun, centeredOn: now, latitude: lat, longitude: lon)
                let moon = Ephemeris.windowPath(of: .moon, centeredOn: now, latitude: lat, longitude: lon)
                let sunNow = Ephemeris.sunPosition(date: now, latitude: lat, longitude: lon)
                let moonNow = Ephemeris.moonPosition(date: now, latitude: lat, longitude: lon)
                let sunDirs = sun.samples.map { SkyArcOverlayView.enu(azimuthDeg: $0.position.azimuthDeg, elevationDeg: $0.position.elevationDeg) }
                let moonDirs = moon.samples.map { SkyArcOverlayView.enu(azimuthDeg: $0.position.azimuthDeg, elevationDeg: $0.position.elevationDeg) }
                let sunNowDir = SkyArcOverlayView.enu(azimuthDeg: sunNow.azimuthDeg, elevationDeg: sunNow.elevationDeg)
                let moonNowDir = SkyArcOverlayView.enu(azimuthDeg: moonNow.azimuthDeg, elevationDeg: moonNow.elevationDeg)
                DispatchQueue.main.async {
                    guard let self, let so = self.container?.skyArc else { return }
                    so.sunDirs = sunDirs; so.moonDirs = moonDirs
                    so.sunNowDir = sunNowDir; so.moonNowDir = moonNowDir
                    self.view?.setNeedsDisplay()
                }
            }
        }

        private static func buildAnchors(
            peaks: [Peak], dem: DEMTile, refLat: Double, refLon: Double,
            camElevMeters: Double, heightScale: Double
        ) -> [PeakLabelOverlayView.Anchor] {
            let mLat = 111_320.0
            let mLon = 111_320.0 * max(cos(refLat * .pi / 180), 0.01)
            let earthR = 6_371_000.0, refraction = 0.13
            let curvatureK = (1 - refraction) / (2 * earthR)   // matches the shader
            let maxDist = 45_000.0                              // within the DEM tile
            var out: [PeakLabelOverlayView.Anchor] = []
            for peak in peaks {
                guard dem.contains(lat: peak.latitude, lon: peak.longitude) else { continue }
                // Snap to the highest DEM cell near the catalog coord, and use the DEM
                // elevation — so the label sits on the rendered summit, not the (often
                // offset) catalog point/height.
                let hi = dem.highestNear(lat: peak.latitude, lon: peak.longitude, radiusMeters: 300)
                let east = (hi.lon - refLon) * mLon
                let north = (hi.lat - refLat) * mLat
                let horiz = (east * east + north * north).squareRoot()
                if horiz < 80 || horiz > maxDist { continue }
                let apparentUp = Double(hi.elev) * heightScale - curvatureK * horiz * horiz - camElevMeters
                let sightAngle = atan2(apparentUp, horiz) * 180 / .pi
                let bearing = GeoMath.bearingRad(
                    fromLatitude: refLat, fromLongitude: refLon,
                    toLatitude: hi.lat, toLongitude: hi.lon)
                guard lineOfSightClear(
                    dem: dem, eyeLat: refLat, eyeLon: refLon, eyeElevMeters: camElevMeters,
                    bearingRad: bearing, distanceMeters: horiz, sightAngleDeg: sightAngle,
                    heightScale: heightScale, curvatureK: curvatureK) else { continue }
                out.append(.init(
                    peak: peak,
                    direction: SIMD3<Float>(Float(east), Float(north), Float(apparentUp)),
                    distanceMeters: horiz))
            }
            out.sort { $0.peak.priority > $1.peak.priority }
            return out.count > 400 ? Array(out.prefix(400)) : out
        }

        /// March the DEM along the eye→summit bearing; if any nearer terrain rises
        /// above the sightline to the summit, the peak is occluded.
        private static func lineOfSightClear(
            dem: DEMTile, eyeLat: Double, eyeLon: Double, eyeElevMeters: Double,
            bearingRad: Double, distanceMeters: Double, sightAngleDeg: Double,
            heightScale: Double, curvatureK: Double
        ) -> Bool {
            // Back off only just short of the summit's own slope, and keep it small so
            // even near peaks (<300 m) still get sampled.
            let stopAt = distanceMeters - min(120, max(40, distanceMeters * 0.04))
            // Start CLOSE to the eye so foreground occluders are actually checked (the
            // old 150 m start skipped anything blocking the view within 150 m — and
            // never ran at all for peaks <300 m). The eye sits ~1.6 m above its own
            // ground, so near samples read just below the horizon and can't false-block.
            // Step ~half a DEM cell near the eye so thin close ridges aren't skipped,
            // then grow the step with distance.
            var s = 18.0, step = 18.0
            while s < stopAt {
                let p = GeoMath.destination(
                    latitude: eyeLat, longitude: eyeLon,
                    bearingRad: bearingRad, distanceMeters: s)
                let g = Double(dem.elevation(lat: p.latitude, lon: p.longitude))
                let rise = g * heightScale - curvatureK * s * s - eyeElevMeters
                let a = atan2(rise, s) * 180 / .pi
                if a > sightAngleDeg + 0.12 { return false }
                s += step
                if s >= 1500 { step = min(step * 1.03, 120) }
            }
            return true
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

        /// Two-stage bake (off the main thread): a fast low-res pass installs a
        /// usable image and fires `onReady`, then the full-res pass swaps in
        /// silently. A generation token discards a stale bake if a newer
        /// viewpoint/exaggeration has been requested.
        private func bakeProgressive(onReady: @escaping () -> Void) {
            guard let renderer = renderer, dem != nil else { onReady(); return }
            bakeGeneration &+= 1
            let gen = bakeGeneration
            let t0 = DispatchTime.now()
            renderer.panoramaWidth = Self.quickPanoramaWidth
            bakeOnce { [weak self] tex in
                guard let self, gen == self.bakeGeneration, let tex,
                      let renderer = self.renderer else { onReady(); return }
                renderer.installPanorama(tex)
                self.view?.setNeedsDisplay()                 // usable image now
                onReady()
                NSLog("Quick bake (w=%d) %.0f ms", Self.quickPanoramaWidth, Self.ms(since: t0))
                let t1 = DispatchTime.now()
                renderer.panoramaWidth = Self.fullPanoramaWidth
                self.bakeOnce { tex in
                    guard gen == self.bakeGeneration, let tex else { return }
                    renderer.installPanorama(tex)            // swap in the crisp pano
                    self.view?.setNeedsDisplay()
                    NSLog("Full bake (w=%d) %.0f ms", Self.fullPanoramaWidth, Self.ms(since: t1))
                }
            }
        }

        private func bakeOnce(_ done: @escaping (MTLTexture?) -> Void) {
            guard let renderer = renderer, dem != nil else { done(nil); return }
            var u = makeUniforms(width: 1, height: 1)
            dem?.applyDEMUniforms(to: &u, refLat: refLat, refLon: refLon)
            renderer.bakePanoramaAsync(uniforms: u, completion: done)
        }

        private func makeUniforms(width: Int, height: Int) -> Uniforms {
            var camera = PanoramaCamera(
                position: SIMD3<Float>(0, 0, camElev),
                azimuthDegrees: azimuth,
                pitchDegrees: pitch,
                verticalFovDegrees: fov)
            camera.heightScale = exaggeration
            return camera.makeUniforms(width: width, height: height)
        }

        // MARK: Gestures

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard manualAlignment, let v = view else { return }   // manual look-around only
            if g.state == .began { panStartAz = azimuth; panStartPitch = pitch }
            let t = g.translation(in: v)
            let degPerPoint = fov / Float(v.bounds.height)
            azimuth = panStartAz - Float(t.x) * degPerPoint
            pitch = max(-80, min(80, panStartPitch + Float(t.y) * degPerPoint))
            v.setNeedsDisplay()
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let v = view else { return }
            if g.state == .began { pinchStartFov = fov }
            fov = max(15, min(90, pinchStartFov / Float(g.scale)))
            v.setNeedsDisplay()
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let overlay = container?.labelOverlay else { return }
            onSelectPeak(overlay.peak(at: g.location(in: overlay)))
        }

        func setSelectedPeakID(_ id: String?) {
            guard id != selectedPeakID else { return }
            selectedPeakID = id
            container?.labelOverlay.selectedPeakID = id
            view?.setNeedsDisplay()        // re-project to refresh the highlight
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

            var uniforms = makeUniforms(width: w, height: h)
            // Device alignment overrides the az/pitch basis with the live device
            // orientation (the bake is orientation-independent, so only the per-frame
            // resample changes). Manual alignment keeps the drag-controlled az/pitch.
            if !manualAlignment, let b = deviceBasis {
                uniforms.forward = SIMD4<Float>(b.forward, 0)
                uniforms.right = SIMD4<Float>(b.right, 0)
                uniforms.up = SIMD4<Float>(b.up, 0)
            }
            guard let cb = renderer.commandQueue.makeCommandBuffer() else { return }
            switch mode {
            case .threeD:
                renderer.encodeView(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
            case .arRelief:
                renderer.encodeViewAR(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
            case .arEdges:
                renderer.encodeViewEdges(uniforms: uniforms, into: drawable.texture, commandBuffer: cb)
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
            container?.labelOverlay.project(forward: fwd, right: rgt, up: upv,
                                            tanHalfFovY: uniforms.tanHalfFovY, aspect: uniforms.aspect,
                                            zoom: 60.0 / max(1.0, fov))
            var headingDeg = atan2(Double(fwd.x), Double(fwd.y)) * 180 / .pi
            if headingDeg < 0 { headingDeg += 360 }
            container?.compassZoom.update(headingDeg: headingDeg, zoom: Double(60.0 / max(1.0, fov)))
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
