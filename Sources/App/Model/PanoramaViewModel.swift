import Combine
import CoreLocation
import Foundation

/// Drives the viewpoint: GPS or a manual teleport sets where the eye stands; the
/// `TerrainMetalView` renderer takes the viewpoint + exaggeration and reports its
/// load status and eye elevation back here. The render pipeline itself is
/// PeakPeek's live Metal raymarch — this model only decides *where* to stand
/// and surfaces PeakFinder-style status. (App-shell + viewpoint logic ported from
/// RidgeLine's PanoramaViewModel; its silhouette/relief pipeline is intentionally
/// dropped since PeakPeek renders live.)
@MainActor
final class PanoramaViewModel: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case locating
        /// Fetching + assembling the DEM. `progress` spans the WHOLE load — tile
        /// downloads and the decode/stitch both tick it (each degree tile counts
        /// once per phase), so cached tiles no longer slam the readout to 100%
        /// while the stitch still runs. nil while the total is unknown (or the
        /// terrain is being reused from cache): the UI shows a generic message.
        case preparingTerrain(progress: Double?)
        /// Panorama bake (GPU, no incremental signal) — `progress` is the fixed
        /// tail of the same 0–1 scale so the readout keeps climbing, not resets.
        case rendering(progress: Double)
        case ready
        case failed(String)
    }

    struct Viewpoint: Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
        /// "Stand here" on a peak: once the DEM loads, the eye snaps to the TRUE
        /// summit (highest DEM cell nearby) instead of the catalog coordinate —
        /// which is often tens of meters off, leaving a blocked view in one
        /// direction. GPS fixes and map-pin teleports never snap.
        var snapToSummit: Bool = false
    }

    @Published private(set) var status: Status = .idle
    /// True once the first panorama has finished rendering — gates the full-screen
    /// loading cover (later loads use the small status pill instead).
    @Published private(set) var hasRenderedOnce = false
    @Published private(set) var viewpoint: Viewpoint?
    /// When following GPS and the device has moved far enough that the (frozen)
    /// panorama is stale, this holds the latest fix and the HUD shows a "Recenter"
    /// prompt — instead of re-baking on every GPS update (which made the app reload
    /// endlessly in a moving car). nil = nothing to recenter to.
    @Published private(set) var pendingRecenter: Viewpoint?
    /// Real-world eye elevation (ground + eye height), reported by the renderer.
    @Published private(set) var eyeElevationMeters: Double?
    /// Live look direction (compass degrees) and zoom factor (×), reported (~15 Hz)
    /// by the renderer. NOT `@Published`: the compass/zoom HUD is drawn by the
    /// `CompassZoomOverlayView` CALayer (updated directly in the renderer), so nothing
    /// in SwiftUI reads these — publishing them fired `objectWillChange` 15×/s and
    /// re-rendered the whole HUD (incl. the MapKit mini-map, which then struggled to
    /// load tiles) while looking around. Kept as plain vars for any future read.
    private(set) var headingDeg: Double?
    private(set) var zoomFactor: Double = 1
    /// Vertical exaggeration fed to the renderer's `heightScale`. Fixed at 1.0 (true
    /// scale) — the user-facing Relief adjustment was removed.
    let terrainExaggeration: Double = 1.0

    /// Date/time used to place the sun, moon, stars and Milky Way. Scrubbed via the
    /// Time controls; `usesSimulatedTime` is true while it differs from the live clock
    /// (drives the orange "Time" indicator). Terrain shading is fixed/baked, so this
    /// only re-lights the sky overlay — no re-bake.
    @Published private(set) var displayDate = Date()
    @Published private(set) var usesSimulatedTime = false

    /// Timezone used to DISPLAY sun/moon times and drive the time scrubber, derived
    /// from the viewed location — NOT the device. Sun/moon instants are absolute, but
    /// formatting them in the device's zone made a teleport read another region's
    /// times shifted by the UTC gap (e.g. Iceland's morning sunrise showing at 10pm
    /// on a US-Pacific phone, so sunrise looked later than sunset). Falls back to the
    /// device zone only before a viewpoint exists.
    var displayTimeZone: TimeZone {
        guard let lon = viewpoint?.longitude else { return .current }
        return Self.approxTimeZone(longitudeDeg: lon)
    }

    /// Approximate civil timezone for a longitude, OFFLINE from the coordinate alone
    /// (no network, no tz database): 15° of longitude ≈ 1 hour from UTC. Within ~an
    /// hour of a country's official clock — enough to place sunrise in the morning
    /// and sunset in the evening at the viewed location wherever the device sits.
    static func approxTimeZone(longitudeDeg lon: Double) -> TimeZone {
        let secs = Int((lon / 15).rounded()) * 3600
        return TimeZone(secondsFromGMT: max(-12 * 3600, min(14 * 3600, secs)))
            ?? TimeZone(identifier: "UTC")!
    }

    /// Scrub to a chosen instant (enters simulated-time mode).
    func setDisplayDate(_ date: Date) {
        displayDate = date
        usesSimulatedTime = true
    }

    /// Back to the live clock.
    func resetDisplayDateToNow() {
        displayDate = Date()
        usesSimulatedTime = false
    }

    /// While on the live clock, advance `displayDate` to the wall clock periodically so
    /// the sun (and the dynamic sky colour) keep up with real time. The sun moves only
    /// ~0.25°/min, so a coarse tick is plenty and cheap.
    private var liveClock: Timer?
    private func startLiveClock() {
        liveClock?.invalidate()
        liveClock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.usesSimulatedTime else { return }
            self.displayDate = Date()
        }
    }

    /// Peak overlays (Phase 2). Present so the directory/info UI compiles and the
    /// selection flow works; on-screen labels over the 3D view are deferred.
    @Published private(set) var allNearbyPeaks: [Peak] = []
    /// Named lakes/reservoirs within label range (bundled DB) — water labels only;
    /// they don't join the peak directory/search.
    @Published private(set) var nearbyLakes: [Peak] = []
    @Published var selectedPeak: AnnotatedPeak?
    /// Feature ids with a clear line of sight from the current viewpoint, reported
    /// by the renderer's occlusion pass. nil until the first pass completes, so the
    /// info card can withhold judgment rather than claim "occluded" while loading.
    @Published private(set) var visibleFeatureIDs: Set<String>?

    /// The renderer finished an occlusion pass for the current viewpoint.
    func visibleFeaturesResolved(_ ids: Set<String>) {
        visibleFeatureIDs = ids
    }

    /// True once the user explicitly teleported (map pin / peak visit / debug) —
    /// then we stop auto-following GPS so we don't yank them back.
    @Published private(set) var isManualViewpoint = false
    /// "Use GPS" was pressed without a usable fix: the button shows "Locating…"
    /// and the next fix teleports unconditionally (see followGPS).
    @Published private(set) var awaitingGPSFix = false

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
    /// How far the device must move from the baked viewpoint before the HUD offers a
    /// "Recenter". Big enough that normal driving doesn't nag, small enough that the
    /// held panorama hasn't drifted much (distant terrain barely shifts under this).
    private let recenterDistanceMeters: Double = 600

    init(peakStore: PeakStore = PeakStore()) {
        self.peakStore = peakStore
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    // MARK: - Entry points

    func start() {
        startLiveClock()
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
        // Instant open: restore the last viewpoint right away so the saved region
        // redraws from disk (no wait for a GPS fix or a network stitch). If we were
        // following GPS last time, keep following — a later fix far from here just
        // raises the Recenter pill instead of reloading.
        if let saved = Self.loadSavedViewpoint() {
            teleport(to: saved.viewpoint, manual: saved.manual)
            if !saved.manual {
                location.requestWhenInUseAuthorization()
                location.startUpdatingLocation()
            }
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
        pendingRecenter = nil
        // Re-standing on the EXACT spot already rendered (double-tap "Stand
        // here"): the renderer dedupes identical coordinates and won't bake or
        // report .ready, so flipping to a loading status here would show
        // "Loading terrain data" forever. Keep the healthy state untouched.
        // (After a FAILURE the renderer clears its dedupe memory, so the same
        // spot correctly goes the full loading path again.)
        let healthy: Bool = {
            if case .ready = status { return true }
            if case .rendering = status { return true }
            return false
        }()
        let unchanged = self.viewpoint == viewpoint && healthy
        self.viewpoint = viewpoint
        if !unchanged {
            self.eyeElevationMeters = nil
            self.visibleFeatureIDs = nil      // stale for the new eye; renderer re-reports
            if case .rendering = status {} else { status = .preparingTerrain(progress: nil) }
        }
        loadPeaks(around: viewpoint)
        Self.saveViewpoint(viewpoint, manual: isManualViewpoint)
    }

    // MARK: - Last-viewpoint persistence (instant reopen)

    private static let vpDefaultsKey = "lastViewpoint.v1"

    /// Remember where the eye stood so the next launch reopens here immediately.
    private static func saveViewpoint(_ vp: Viewpoint, manual: Bool) {
        UserDefaults.standard.set([
            "lat": vp.latitude, "lon": vp.longitude,
            "name": vp.name, "manual": manual, "snap": vp.snapToSummit,
        ] as [String: Any], forKey: vpDefaultsKey)
    }

    /// The viewpoint from the previous session, or nil on a first-ever launch.
    static func loadSavedViewpoint() -> (viewpoint: Viewpoint, manual: Bool)? {
        guard let d = UserDefaults.standard.dictionary(forKey: vpDefaultsKey),
              let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
        let name = d["name"] as? String ?? "Last location"
        let manual = d["manual"] as? Bool ?? false
        let snap = d["snap"] as? Bool ?? false
        return (Viewpoint(name: name, latitude: lat, longitude: lon, snapToSummit: snap), manual)
    }

    /// Come home: drop manual mode and (re)stand at the device's position. With a
    /// fresh fix this is immediate; otherwise `awaitingGPSFix` keeps the button in
    /// a visible "Locating…" state and the NEXT fix teleports unconditionally —
    /// pressing this must never silently do nothing (it used to, whenever the
    /// cached fix was stale, and the button vanished with no feedback).
    func followGPS() {
        let wasManual = isManualViewpoint
        isManualViewpoint = false
        pendingRecenter = nil
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if let fix = location.location, fix.horizontalAccuracy <= 200,
           fix.timestamp.timeIntervalSinceNow > -120 {
            // Already standing on (or within GPS noise of) the fix: a rebake
            // would cost seconds and change nothing. A manual viewpoint always
            // comes home, even if home is nearby (the name/mode must reset).
            if !wasManual, !isMeaningfulMove(to: fix.coordinate) { return }
            teleport(to: Viewpoint(
                name: "My location",
                latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude
            ))
        } else {
            if viewpoint == nil { status = .locating }
            awaitingGPSFix = true
            // Give up visibly if no fix lands (denied, airplane mode, indoors).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.awaitingGPSFix = false
            }
        }
    }

    // MARK: - Renderer callbacks

    /// The renderer reports its load progress here so the HUD can mirror it.
    /// Progress values are SMOOTHED for display: the shown percent eases toward
    /// the latest real report (tiles + bake bands) and creeps a bounded few
    /// points between ticks, so the readout moves continuously instead of
    /// jumping tile-by-tile and freezing during unsignalled stretches. The creep
    /// is capped (+5 pts over the last real value, ≤97%) — it can trail reality
    /// slightly, never race ahead of it.
    func renderStatusChanged(_ status: Status) {
        if status == .ready { hasRenderedOnce = true }
        switch status {
        case let .preparingTerrain(progress?):
            setProgressTarget(progress, rendering: false)
        case let .rendering(progress):
            setProgressTarget(progress, rendering: true)
        default:
            stopProgressSmoothing()
            self.status = status
        }
    }

    private var progressTimer: Timer?
    private var targetProgress = 0.0
    private var shownProgress = 0.0
    private var inRenderingPhase = false
    private var lastPublishedPct = -1

    private func setProgressTarget(_ target: Double, rendering: Bool) {
        // A fresh load (first report, or a target well below what's shown)
        // resets the sweep; within one load progress only moves forward.
        if progressTimer == nil || target + 0.02 < shownProgress {
            shownProgress = target
            targetProgress = target
        }
        targetProgress = max(targetProgress, target)
        inRenderingPhase = rendering
        publishProgress()
        if progressTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.progressTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        }
    }

    private func progressTick() {
        let gap = targetProgress - shownProgress
        if gap > 0 {
            // Catch up to real reports quickly (spring-like), never overshooting.
            shownProgress = min(targetProgress, shownProgress + max(gap * 0.25, 0.004))
        } else {
            // No fresh signal: creep, capped just past the last real value.
            let cap = min(targetProgress + 0.05, 0.97)
            shownProgress = min(cap, shownProgress + 0.0025)   // ≈7.5 pts/s
        }
        publishProgress()
    }

    private func publishProgress() {
        // @Published churn control: publish only when the DISPLAYED integer
        // percent (or the phase message) actually changes.
        let pct = Int((shownProgress * 100).rounded())
        let phaseMatches: Bool
        switch status {
        case .preparingTerrain: phaseMatches = !inRenderingPhase
        case .rendering: phaseMatches = inRenderingPhase
        default: phaseMatches = false
        }
        guard !phaseMatches || pct != lastPublishedPct else { return }
        lastPublishedPct = pct
        status = inRenderingPhase
            ? .rendering(progress: shownProgress)
            : .preparingTerrain(progress: shownProgress)
    }

    private func stopProgressSmoothing() {
        progressTimer?.invalidate()
        progressTimer = nil
        targetProgress = 0
        shownProgress = 0
        lastPublishedPct = -1
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

    /// Entirely local: the bundled global database (every named OSM peak on Earth,
    /// see `GlobalPeakDatabase`) plus anything previously downloaded (OSM cache +
    /// packs). No network in the label path — labels are ready in milliseconds and
    /// the old multi-tile Overpass sweep (30-90 s of "Loading labels…") is gone.
    /// To refresh the dataset, rerun `Tools/PeakDB/build_peak_db.py`.
    private func loadPeaks(around viewpoint: Viewpoint) {
        let store = peakStore
        Task { [weak self] in
            // Peaks and lakes resolve in ONE task and publish together: the lakes
            // query (120 km, one file) finishes well before the peak merge (500 km
            // across four sources), and publishing them separately made lakes pop
            // in first and triggered a throwaway anchor rebuild.
            let (peaks, lakes) = await Task.detached(priority: .utility) {
                let t0 = DispatchTime.now()
                defer {
                    NSLog("Peak+lake sources resolved in %.0f ms",
                          Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
                }
                let radiusKm = PeakSearch.maxRangeMeters / 1000
                let global = GlobalPeakDatabase.shared?.peaks(
                    nearLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    withinMeters: PeakSearch.maxRangeMeters
                ) ?? []
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
                for peak in global + bundled + packs + osm where ids.insert(peak.id).inserted {
                    merged.append(peak)
                }
                // Lakes: label range only (120 km — matches the anchor cull), so
                // the published set stays small even in lake country.
                let lakes = GlobalPeakDatabase.lakes?.peaks(
                    nearLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    withinMeters: 120_000
                ) ?? []
                return (merged, lakes)
            }.value
            guard let self, self.viewpoint == viewpoint else { return }
            self.allNearbyPeaks = peaks
            self.nearbyLakes = lakes
        }
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
        // Saddles/gaps are LOW points: standing "here" means the pass itself,
        // never the neighboring summit the snap would climb to. Lakes are water:
        // the snap climbed the shoreline ridge (up to 250 m of it), leaving you
        // looking DOWN at the lake you asked to stand on — same rule as the
        // label anchors, which never summit-snap water.
        let isWater = nearbyLakes.contains { $0.id == peak.id }
        teleport(to: Viewpoint(name: peak.name, latitude: peak.latitude, longitude: peak.longitude,
                               snapToSummit: !peak.isSaddle && !isWater),
                 manual: true)
    }

    // MARK: - GPS follow

    /// A GPS fix arrived while following. Never re-bake automatically (that's what made
    /// the app reload endlessly in a car). Instead, once the device has moved far enough
    /// from the baked viewpoint, surface a "Recenter" prompt with the latest position;
    /// the panorama stays frozen (and aligned, for distant terrain) until the user taps it.
    private func queueGPS(_ next: Viewpoint) {
        guard !isManualViewpoint, let current = viewpoint else { return }
        let moved = GeoMath.distanceMeters(
            fromLatitude: current.latitude, fromLongitude: current.longitude,
            toLatitude: next.latitude, toLongitude: next.longitude)
        if moved < recenterDistanceMeters {
            if pendingRecenter != nil { pendingRecenter = nil }   // drifted back (GPS jitter)
        } else {
            pendingRecenter = next                                // offer recenter; keep latest fix
        }
    }

    /// Re-bake at the latest GPS position (the user tapped "Recenter"). Stays in
    /// GPS-follow mode, so it will prompt again after the next big move.
    func recenter() {
        guard let next = pendingRecenter else { return }
        pendingRecenter = nil
        teleport(to: next)
    }

    /// Whether standing at `coordinate` would show anything new: beyond ~30 m
    /// (GPS noise) of the current viewpoint. Manual viewpoints always count —
    /// "Use GPS" from a teleport must come home even if home is nearby.
    private func isMeaningfulMove(to coordinate: CLLocationCoordinate2D) -> Bool {
        guard !isManualViewpoint, let current = viewpoint else { return true }
        return GeoMath.distanceMeters(
            fromLatitude: current.latitude, fromLongitude: current.longitude,
            toLatitude: coordinate.latitude, toLongitude: coordinate.longitude) > 30
    }
}

extension PanoramaViewModel: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !isManualViewpoint { manager.startUpdatingLocation() }
        case .denied, .restricted:
            awaitingGPSFix = false
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
        guard viewpoint != nil else { awaitingGPSFix = false; teleport(to: next); return }
        if awaitingGPSFix {
            // The user explicitly asked to stand at their position — honor the
            // first usable fix regardless of the recenter distance gate.
            awaitingGPSFix = false
            if isMeaningfulMove(to: fix.coordinate) { teleport(to: next) }
            return
        }
        queueGPS(next)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard viewpoint == nil else { return }
        teleport(to: Self.demoViewpoint)
    }
}
