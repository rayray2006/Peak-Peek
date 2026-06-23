import Combine
import CoreLocation
import Foundation

/// Drives the viewpoint: GPS or a manual teleport sets where the eye stands; the
/// `TerrainMetalView` renderer takes the viewpoint + exaggeration and reports its
/// load status and eye elevation back here. The render pipeline itself is
/// mountainView's live Metal raymarch — this model only decides *where* to stand
/// and surfaces PeakFinder-style status. (App-shell + viewpoint logic ported from
/// RidgeLine's PanoramaViewModel; its silhouette/relief pipeline is intentionally
/// dropped since mountainView renders live.)
@MainActor
final class PanoramaViewModel: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case locating
        case preparingTerrain
        case rendering
        case ready
        case failed(String)
    }

    struct Viewpoint: Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    @Published private(set) var status: Status = .idle
    /// True once the first panorama has finished rendering — gates the full-screen
    /// loading cover (later loads use the small status pill instead).
    @Published private(set) var hasRenderedOnce = false
    @Published private(set) var viewpoint: Viewpoint?
    /// Real-world eye elevation (ground + eye height), reported by the renderer.
    @Published private(set) var eyeElevationMeters: Double?
    /// Live look direction (compass degrees) and zoom factor (×) for the HUD,
    /// reported (throttled) by the renderer.
    @Published private(set) var headingDeg: Double?
    @Published private(set) var zoomFactor: Double = 1
    /// Vertical exaggeration cycled by the Relief button; fed to the renderer's
    /// `heightScale` so the bake re-runs at the new scale.
    @Published private(set) var terrainExaggeration: Double = 1.0
    static let exaggerationSteps: [Double] = [1.0, 1.5, 2.0, 2.5]

    /// Peak overlays (Phase 2). Present so the directory/info UI compiles and the
    /// selection flow works; on-screen labels over the 3D view are deferred.
    @Published private(set) var allNearbyPeaks: [Peak] = []
    @Published var selectedPeak: AnnotatedPeak?
    @Published private(set) var isLoadingDistantPeaks = false

    /// True once the user explicitly teleported (map pin / peak visit / debug) —
    /// then we stop auto-following GPS so we don't yank them back.
    @Published private(set) var isManualViewpoint = false

    // MARK: - Viewpoints

    /// Demo viewpoint inside the bundled `cascades` DEM — works with zero network,
    /// which is also what the simulator and unit-test hosts exercise.
    static let demoViewpoint = Viewpoint(name: "North Cascades", latitude: 48.50, longitude: -121.08)

    /// Diverse real viewpoints for multi-location testing (`-viewpointIndex N`).
    static let testViewpoints: [Viewpoint] = [
        Viewpoint(name: "Zermatt (Matterhorn)", latitude: 46.020, longitude: 7.749),
        Viewpoint(name: "Chamonix (Mont Blanc)", latitude: 45.924, longitude: 6.870),
        Viewpoint(name: "Grand Canyon South Rim", latitude: 36.057, longitude: -112.140),
        Viewpoint(name: "Lauterbrunnen Valley", latitude: 46.593, longitude: 7.909),
        Viewpoint(name: "Big Sur Coast", latitude: 36.270, longitude: -121.807),
        Viewpoint(name: "Aoraki / Mt Cook", latitude: -43.595, longitude: 170.141),
        Viewpoint(name: "Fuji Five Lakes", latitude: 35.500, longitude: 138.760),
    ]

    private let peakStore: PeakStore
    private let location = CLLocationManager()
    private var pendingGPSViewpoint: Viewpoint?
    private let locationRefreshDistanceMeters: Double = 60

    init(peakStore: PeakStore = PeakStore()) {
        self.peakStore = peakStore
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    // MARK: - Entry points

    func start() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-viewpointIndex"),
           i + 1 < args.count, let index = Int(args[i + 1]),
           Self.testViewpoints.indices.contains(index) {
            teleport(to: Self.testViewpoints[index], manual: true)
            return
        }
        if let i = args.firstIndex(of: "-viewpointLatLon"),
           i + 2 < args.count, let lat = Double(args[i + 1]), let lon = Double(args[i + 2]) {
            let name = args.firstIndex(of: "-viewpointName")
                .flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "Custom viewpoint"
            teleport(to: Viewpoint(name: name, latitude: lat, longitude: lon), manual: true)
            return
        }
        if args.contains("-demoViewpoint") {
            teleport(to: Self.demoViewpoint, manual: true)
            return
        }
        status = .locating
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        // Safety net for environments with no GPS (e.g. a simulator with no
        // simulated location): if nothing resolves in 12 s, show the demo so the
        // screen isn't blank. A real fix that lands later still replaces it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.viewpoint == nil else { return }
            self.teleport(to: Self.demoViewpoint)
        }
    }

    /// Jump the eye anywhere. A user-initiated jump (map / peak visit / debug) also
    /// stops GPS auto-follow.
    func teleport(to viewpoint: Viewpoint, manual: Bool = false) {
        if manual { isManualViewpoint = true; location.stopUpdatingLocation() }
        self.viewpoint = viewpoint
        self.eyeElevationMeters = nil
        if status != .rendering { status = .preparingTerrain }
        loadPeaks(around: viewpoint)
    }

    /// Come home: drop manual mode and resume following the device's position.
    func followGPS() {
        isManualViewpoint = false
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if let fix = location.location, fix.horizontalAccuracy <= 200,
           fix.timestamp.timeIntervalSinceNow > -120 {
            teleport(to: Viewpoint(
                name: "My location",
                latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude
            ))
        } else if viewpoint == nil {
            status = .locating
        }
    }

    func cycleTerrainExaggeration() {
        let steps = Self.exaggerationSteps
        let index = steps.firstIndex { abs($0 - terrainExaggeration) < 0.01 } ?? 0
        terrainExaggeration = steps[(index + 1) % steps.count]
    }

    // MARK: - Renderer callbacks

    /// The renderer reports its load progress here so the HUD can mirror it.
    func renderStatusChanged(_ status: Status) {
        self.status = status
        if status == .ready { hasRenderedOnce = true }
    }

    func eyeElevationResolved(_ meters: Double?) {
        eyeElevationMeters = meters
    }

    func headingResolved(_ deg: Double) {
        headingDeg = deg
    }

    func zoomResolved(_ factor: Double) {
        zoomFactor = factor
    }

    // MARK: - Peaks (Phase 2 wiring; no on-screen labels yet)

    /// Re-pull nearby peaks (bundled directory + downloaded OSM/pack caches) for
    /// the current viewpoint — called after the directory downloads a region.
    func reloadNearbyPeaks() {
        guard let viewpoint else { return }
        loadPeaks(around: viewpoint)
    }

    private func loadPeaks(around viewpoint: Viewpoint) {
        let store = peakStore
        Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) {
                let radiusKm = PeakSearch.maxRangeMeters / 1000
                let bundled = store.peaks(
                    nearLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    withinMeters: PeakSearch.maxRangeMeters
                )
                // Include anything already downloaded for this area (OSM + packs).
                let osm = OSMPeakService.cachedPeaks(
                    aroundLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    radiusKm: radiusKm
                ) ?? []
                let packs = PeakPackService.cachedPeaks(
                    aroundLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    radiusKm: radiusKm
                )
                var merged: [Peak] = []
                var ids = Set<String>()
                for peak in bundled + packs + osm where ids.insert(peak.id).inserted {
                    merged.append(peak)
                }
                return merged
            }.value
            guard let self, self.viewpoint == viewpoint else { return }
            self.allNearbyPeaks = peaks
            await self.fetchOnlinePeaks(around: viewpoint, base: peaks)
        }
    }

    /// Pull OSM peaks for the area (keyless Overpass, ~45 km — the label range) and
    /// merge them in, so labels populate densely on first visit and cache for later.
    private func fetchOnlinePeaks(around viewpoint: Viewpoint, base: [Peak]) async {
        guard !ProcessInfo.processInfo.arguments.contains("-noNetwork") else { return }
        let fetched = (try? await OSMPeakService.peaks(
            aroundLatitude: viewpoint.latitude, longitude: viewpoint.longitude, radiusKm: 45)) ?? []
        guard !fetched.isEmpty, self.viewpoint == viewpoint else { return }
        var ids = Set(base.map(\.id))
        var merged = base
        for p in fetched where ids.insert(p.id).inserted { merged.append(p) }
        allNearbyPeaks = merged
    }

    /// Resolve a peak against the current viewpoint (distance / bearing / apparent
    /// elevation), for the info panel and selection.
    func select(_ peak: Peak?) {
        guard let peak, let viewpoint else { selectedPeak = nil; return }
        let distance = GeoMath.distanceMeters(
            fromLatitude: viewpoint.latitude, fromLongitude: viewpoint.longitude,
            toLatitude: peak.latitude, toLongitude: peak.longitude
        )
        let bearing = GeoMath.bearingRad(
            fromLatitude: viewpoint.latitude, fromLongitude: viewpoint.longitude,
            toLatitude: peak.latitude, toLongitude: peak.longitude
        ) * 180 / .pi
        let eye = eyeElevationMeters ?? 0
        let apparent = GeoMath.apparentRise(
            groundMeters: peak.elevationMeters, eyeMeters: eye,
            distanceMeters: distance, exaggeration: terrainExaggeration
        )
        let angle = atan2(apparent, max(1, distance)) * 180 / .pi
        selectedPeak = AnnotatedPeak(
            peak: peak, azimuthDeg: bearing, elevationAngleDeg: angle, distanceMeters: distance
        )
    }

    func selectAnnotated(_ annotated: AnnotatedPeak?) {
        selectedPeak = annotated
    }

    /// Stand on a peak: teleport the eye to the summit coordinate.
    func standOnPeak(_ annotated: AnnotatedPeak) {
        selectedPeak = nil
        let peak = annotated.peak
        teleport(to: Viewpoint(name: peak.name, latitude: peak.latitude, longitude: peak.longitude),
                 manual: true)
    }

    // MARK: - GPS follow

    private func queueGPS(_ next: Viewpoint) {
        guard !isManualViewpoint else { return }
        if let current = viewpoint,
           GeoMath.distanceMeters(
               fromLatitude: current.latitude, fromLongitude: current.longitude,
               toLatitude: next.latitude, toLongitude: next.longitude
           ) < locationRefreshDistanceMeters {
            return
        }
        teleport(to: next)
    }
}

extension PanoramaViewModel: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !isManualViewpoint { manager.startUpdatingLocation() }
        case .denied, .restricted:
            if viewpoint == nil { teleport(to: Self.demoViewpoint) }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isManualViewpoint, let fix = locations.last, fix.horizontalAccuracy <= 200 else { return }
        let next = Viewpoint(
            name: "My location",
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude
        )
        guard viewpoint != nil else { teleport(to: next); return }
        queueGPS(next)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard viewpoint == nil else { return }
        teleport(to: Self.demoViewpoint)
    }
}
