import Combine
import CoreLocation
import Foundation
import UIKit

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

    /// The peak a "Stand here" visit is standing ON. Carries what the renderer
    /// needs to put the eye on the peak's RENDERED apex — the same cell the
    /// label pass picks for its dot — and to suppress that dot once you're
    /// standing there. Catalog coords are often tens of meters off the true
    /// top, which leaves a shoulder blocking part of the panorama.
    /// GPS fixes and map-pin teleports carry no target and never snap.
    struct SummitTarget: Equatable {
        let peakID: String
        /// Catalog height, 0 when the catalog has none (the snap then falls
        /// back to the nearest-peak-capped highest-cell search).
        let elevationMeters: Double
    }

    struct Viewpoint: Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
        var summitTarget: SummitTarget? = nil
    }

    @Published private(set) var status: Status = .idle
    /// True once the first panorama has finished rendering — gates the full-screen
    /// loading cover (later loads use the small status pill instead).
    @Published private(set) var hasRenderedOnce = false
    @Published private(set) var viewpoint: Viewpoint? {
        didSet {
            guard viewpoint?.latitude != oldValue?.latitude
                || viewpoint?.longitude != oldValue?.longitude else { return }
            resolveViewedTimeZone()
        }
    }
    /// When following GPS and the device has moved far enough that the (frozen)
    /// panorama is stale, this holds the latest fix and the HUD shows a "Recenter"
    /// prompt — instead of re-baking on every GPS update (which made the app reload
    /// endlessly in a moving car). nil = nothing to recenter to.
    @Published private(set) var pendingRecenter: Viewpoint?
    /// Real-world eye elevation (ground + eye height), reported by the renderer.
    @Published private(set) var eyeElevationMeters: Double?
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
        guard let vp = viewpoint else { return .current }
        // Standing at the viewed location (GPS-follow): the device clock IS
        // local civil time, DST included — exact, no lookup needed.
        if !isManualViewpoint { return .current }
        return viewedTimeZone ?? Self.approxTimeZone(longitudeDeg: vp.longitude)
    }

    /// The tz-DATABASE zone of the viewed location (DST-correct), resolved by
    /// reverse geocode after each viewpoint change; nil while unknown/offline
    /// (approxTimeZone then fills in). The approximation alone has no DST: at
    /// Black Peak in July it formatted every sun time an hour early (UTC−8
    /// where the clock says PDT).
    @Published private(set) var viewedTimeZone: TimeZone?
    private let timeZoneGeocoder = CLGeocoder()

    private func resolveViewedTimeZone() {
        viewedTimeZone = nil
        guard let vp = viewpoint else { return }
        timeZoneGeocoder.cancelGeocode()
        let loc = CLLocation(latitude: vp.latitude, longitude: vp.longitude)
        timeZoneGeocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            let tz = placemarks?.first?.timeZone
            Task { @MainActor [weak self] in
                guard let self, let tz,
                      self.viewpoint?.latitude == vp.latitude,
                      self.viewpoint?.longitude == vp.longitude else { return }
                self.viewedTimeZone = tz
            }
        }
    }

    /// Approximate civil timezone for a longitude, OFFLINE from the coordinate alone
    /// (no network, no tz database): 15° of longitude ≈ 1 hour from UTC. Within ~an
    /// hour of a country's official clock — enough to place sunrise in the morning
    /// and sunset in the evening at the viewed location wherever the device sits.
    /// nonisolated: pure longitude math, called from the celestial worker queue.
    nonisolated static func approxTimeZone(longitudeDeg lon: Double) -> TimeZone {
        let secs = Int((lon / 15).rounded()) * 3600
        return TimeZone(secondsFromGMT: max(-12 * 3600, min(14 * 3600, secs)))
            ?? TimeZone(identifier: "UTC")!
    }

    /// Sun events for the day being viewed, computed by the renderer's celestial
    /// pass (it owns the terrain skyline): TRUE sunrise/sunset against the
    /// astronomical horizon, plus the window the sun is actually VISIBLE from
    /// this viewpoint (above the terrain ridge). Shown on the Time card.
    struct SunTimes: Equatable, Sendable {
        var sunrise: Date?
        var sunset: Date?
        var firstVisible: Date?
        var lastVisible: Date?
    }
    @Published private(set) var sunTimes: SunTimes?

    /// The renderer finished a celestial pass for the current day/viewpoint.
    func sunTimesResolved(_ times: SunTimes?) {
        sunTimes = times
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
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    /// When the app last left the foreground — decides below whether a
    /// scrubbed (simulated) sky is still the user's active intent on return.
    private var backgroundedAt: Date?
    private func startLiveClock() {
        liveClock?.invalidate()
        liveClock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.usesSimulatedTime else { return }
            self.displayDate = Date()
        }
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.backgroundedAt = Date() }
            }
        }
        // Timers don't fire while the app is suspended, and the first tick
        // after a long suspension can lag — reopening the app the next morning
        // kept yesterday's sky (arc, disc, day/night) until it fired or the
        // user scrubbed. Snap to the wall clock the moment we return. A
        // SCRUBBED sky is kept across a quick app switch, but after an hour
        // away it has outlived its intent — coming back the next day to
        // yesterday's simulated instant read as "the sky never updates".
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let away = self.backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
                    NSLog("Live clock: foreground (simulated=%d, away %.0f s, displayDate=%@)",
                          self.usesSimulatedTime ? 1 : 0, away, "\(self.displayDate)")
                    if !self.usesSimulatedTime {
                        self.displayDate = Date()
                    } else if away >= 3_600 {
                        NSLog("Live clock: dropping stale simulated time (%.0f s away)", away)
                        self.resetDisplayDateToNow()
                    }
                }
            }
        }
    }

    deinit {
        // Repeating timers are retained by the run loop until invalidated —
        // without this a released VM would leave them firing no-op closures.
        liveClock?.invalidate()
        progressTimer?.invalidate()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    /// Peak overlays (Phase 2). Present so the directory/info UI compiles and the
    /// selection flow works; on-screen labels over the 3D view are deferred.
    @Published private(set) var allNearbyPeaks: [Peak] = []
    /// Named lakes/reservoirs within label range (bundled DB) — water labels only;
    /// they don't join the peak directory/search.
    @Published private(set) var nearbyLakes: [Peak] = []
    @Published var selectedPeak: AnnotatedPeak?
    /// The ONE label pinned open on the terrain (at most a single element):
    /// tapping a dot expands its name label — replacing any other open one —
    /// tapping it again collapses it, and a tap on empty terrain clears it
    /// (see select/tapLabel). The pin outlives the card's ✕, so the name can
    /// stay up after the card is dismissed. A Set only for plumbing symmetry
    /// with the overlay.
    @Published private(set) var pinnedPeakIDs: Set<String> = []
    /// Feature ids with a clear line of sight from the current viewpoint, reported
    /// by the renderer's occlusion pass. nil until the first pass completes, so the
    /// info card can withhold judgment rather than claim "occluded" while loading.
    @Published private(set) var visibleFeatureIDs: Set<String>?

    /// The renderer finished an occlusion pass for the current viewpoint.
    func visibleFeaturesResolved(_ ids: Set<String>) {
        visibleFeatureIDs = ids
    }

    /// The loaded DEM tiles (near ≈ high-res 40 km, far ≈ coarse 160 km),
    /// reported up by the renderer so UI features can sample terrain heights —
    /// the search fills missing catalog elevations from these. Not published:
    /// consumers snapshot them when they compute.
    private(set) var demNear: DEMTile?
    private(set) var demFar: DEMTile?

    func demTilesResolved(near: DEMTile?, far: DEMTile?) {
        demNear = near
        demFar = far
    }

    /// HONEST visibility for a feature: true/false only when the renderer's
    /// occlusion pass actually judged it this viewpoint; nil = unknown (no
    /// pass yet, out of the candidate range, or a class the pipeline never
    /// judges) — the UI shows no badge rather than a false "Hidden".
    func visibilityVerdict(for peak: Peak) -> Bool? {
        guard let ids = visibleFeatureIDs, let viewpoint else { return nil }
        let isWater = nearbyLakes.contains { $0.id == peak.id }
        let isCandidate = isWater || allNearbyPeaks.contains { $0.id == peak.id }
        let distance = GeoMath.distanceMeters(
            fromLatitude: viewpoint.latitude, fromLongitude: viewpoint.longitude,
            toLatitude: peak.latitude, toLongitude: peak.longitude)
        return Self.visibilityVerdict(
            peakID: peak.id, isSaddle: peak.isSaddle,
            elevationMeters: peak.elevationMeters,
            prominenceMeters: peak.prominenceMeters, isWater: isWater,
            distanceMeters: distance, visibleIDs: ids, isCandidate: isCandidate)
    }

    /// The pure verdict logic (also used per-row by the search, off-main).
    /// The badge answers "can you see this from here?", so absence from
    /// `visibleIDs` reads as "Hidden" wherever that answer is settled: the
    /// pass judged it (within the far tile, or a perceptible ring-band
    /// summit), Earth curvature settles it (past the ring's reach), or it's
    /// simply too small to discern at its distance (the old `nil` ring-band
    /// cases — "you can't see it" is the honest practical answer). nil now
    /// means only: no pass yet, you're standing on it (< 100 m), or a
    /// perceptible summit the pipeline genuinely never looked at.
    nonisolated static func visibilityVerdict(
        peakID: String, isSaddle: Bool, elevationMeters: Double,
        prominenceMeters: Double?, isWater: Bool,
        distanceMeters: Double, visibleIDs: Set<String>, isCandidate: Bool
    ) -> Bool? {
        if visibleIDs.contains(peakID) { return true }
        // Past the ring's reach NOTHING terrestrial can crest the horizon —
        // Earth curvature settles it without a render pass, so "Occluded" is
        // honest even for features the pipeline never looked at (a search hit
        // half the world away).
        if distanceMeters > FarHorizon.endMeters { return false }
        guard distanceMeters > 100 else { return nil }
        // Water: judged through the far tile (absence = occluded); beyond it
        // nothing at surface level survives the curvature drop, and no water
        // is drawn or discernible at that range regardless.
        if isWater { return false }
        if isCandidate, distanceMeters <= FarHorizon.farTileMeters { return false }
        // Ring band (far tile → ring reach): too small to perceive at this
        // distance = not visible, whatever the exact geometry.
        if !FarHorizon.perceptible(prominenceMeters: prominenceMeters,
                                   elevationMeters: elevationMeters,
                                   distanceMeters: distanceMeters) { return false }
        // A perceptible ring-band summit the pass looked at and didn't mark
        // visible is occluded; outside the candidate set it was never judged.
        return isCandidate ? false : nil
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
    /// Debug (-noLocationPrompt): simulator screenshot runs must never be
    /// blocked by the location-permission dialog (the same flag also guards the
    /// heading + map location requests). The GPS feed simply stays off.
    private var suppressLocationPrompt: Bool {
        ProcessInfo.processInfo.arguments.contains("-noLocationPrompt")
    }
    /// How far the device must move from the baked viewpoint before the HUD offers a
    /// "Recenter". Big enough that normal driving doesn't nag, small enough that the
    /// held panorama hasn't drifted much (distant terrain barely shifts under this).
    // Very sensitive on purpose: the button appears as soon as the fix is
    // meaningfully off the standing viewpoint (jitter hysteresis: queueGPS
    // clears the offer when the fix drifts back inside).
    private let recenterDistanceMeters: Double = 50

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
            if !saved.manual, !suppressLocationPrompt {
                location.requestWhenInUseAuthorization()
                location.startUpdatingLocation()
            }
            return
        }
        status = .locating
        if !suppressLocationPrompt {
            location.requestWhenInUseAuthorization()
            location.startUpdatingLocation()
        }
        // Safety net for environments with no GPS (e.g. a simulator with no
        // simulated location): if nothing resolves in 12 s, show the demo so the
        // screen isn't blank. A real fix that lands later still replaces it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.viewpoint == nil else { return }
            self.teleport(to: Self.demoViewpoint)
        }
    }

    /// The viewpoint whose scene is actually ON SCREEN, captured as a move
    /// leaves a healthy scene — a move that fails to load (offline teleport)
    /// falls back here instead of stranding the model at a place the terrain
    /// never rendered.
    private var lastGoodViewpoint: (viewpoint: Viewpoint, manual: Bool)?
    private var failedMoveRevertTask: Task<Void, Never>?

    /// The viewpoint whose scene is actually rendered on screen (set on every
    /// `.ready`). UI that depicts "where you ARE" (the mini-map) binds to this;
    /// `viewpoint` flips to the TARGET at the start of a move.
    @Published private(set) var renderedViewpoint: Viewpoint?

    /// Bumped by the switching card's ✕: tells the renderer (via
    /// TerrainMetalView) to abandon its in-flight fetch/bake for the move
    /// being cancelled, in the same update pass that re-requests the old spot.
    @Published private(set) var moveCancelToken = 0

    /// A previously rendered scene exists to return to — the switching card
    /// offers its ✕ only then (a first launch load has nowhere to go back to).
    var canCancelMove: Bool { lastGoodViewpoint != nil }

    /// User tapped ✕ on the switching card: abandon the in-flight move and
    /// stand back at the last scene that actually rendered. The renderer drops
    /// the pending work (token above); the teleport home then re-bakes from
    /// the still-resident tiles — the fast no-fetch path, so cancel is quick
    /// even when the abandoned fetch had many tiles left to download.
    func cancelLocationChange() {
        guard let prior = lastGoodViewpoint else { return }
        failedMoveRevertTask?.cancel()
        moveCancelToken += 1
        lastGoodViewpoint = nil
        isManualViewpoint = prior.manual
        teleport(to: prior.viewpoint)
    }

    /// Jump the eye anywhere. A user-initiated jump (map / peak visit / debug) also
    /// stops GPS auto-follow.
    func teleport(to viewpoint: Viewpoint, manual: Bool = false) {
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
        // Leaving a rendered scene: remember it (with the mode flags as they
        // are NOW, before this move mutates them) so a failed load can return.
        // Chained moves mid-load keep the original good scene.
        if healthy, let current = self.viewpoint, current != viewpoint {
            lastGoodViewpoint = (current, isManualViewpoint)
        }
        if manual { isManualViewpoint = true; location.stopUpdatingLocation() }
        pendingRecenter = nil
        let unchanged = self.viewpoint == viewpoint && healthy
        self.viewpoint = viewpoint
        if !unchanged {
            self.eyeElevationMeters = nil
            self.standingEyeCoordinate = nil  // stale for the new eye; renderer re-reports
            self.visibleFeatureIDs = nil      // stale for the new eye; renderer re-reports
            // A previous load's display sweep (or finish sweep) must not keep
            // publishing over the new load's bar — it made a cancelled move's
            // card jump back to the old percentage before restarting.
            stopProgressSmoothing()
            if case .rendering = status {} else { status = .preparingTerrain(progress: nil) }
        }
        loadPeaks(around: viewpoint)
        reannotateSelection()
        Self.saveViewpoint(viewpoint, manual: isManualViewpoint)
    }

    /// Recompute the selected peak's annotation for the CURRENT eye. Distance,
    /// bearing and the marker direction are baked in at selection time — after
    /// a teleport / Use GPS they went stale, freezing the info card and leaving
    /// the off-screen direction marker floating toward the old viewpoint's sky.
    private func reannotateSelection() {
        guard let peak = selectedPeak?.peak else { return }
        select(peak)
    }

    // MARK: - Last-viewpoint persistence (instant reopen)

    private static let vpDefaultsKey = "lastViewpoint.v1"

    /// Remember where the eye stood so the next launch reopens here immediately.
    private static func saveViewpoint(_ vp: Viewpoint, manual: Bool) {
        var d: [String: Any] = [
            "lat": vp.latitude, "lon": vp.longitude,
            "name": vp.name, "manual": manual,
            "snap": vp.summitTarget != nil,
        ]
        if let t = vp.summitTarget {
            d["snapPeakID"] = t.peakID
            d["snapElev"] = t.elevationMeters
        }
        UserDefaults.standard.set(d, forKey: vpDefaultsKey)
    }

    /// The viewpoint from the previous session, or nil on a first-ever launch.
    static func loadSavedViewpoint() -> (viewpoint: Viewpoint, manual: Bool)? {
        guard let d = UserDefaults.standard.dictionary(forKey: vpDefaultsKey),
              let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
        let name = d["name"] as? String ?? "Last location"
        let manual = d["manual"] as? Bool ?? false
        // A record written before the target existed carries only the flag —
        // it still snaps, just by the fallback (no id, no catalog height).
        let target = (d["snap"] as? Bool ?? false)
            ? SummitTarget(peakID: d["snapPeakID"] as? String ?? "",
                           elevationMeters: d["snapElev"] as? Double ?? 0)
            : nil
        return (Viewpoint(name: name, latitude: lat, longitude: lon, summitTarget: target), manual)
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
            teleport(to: gpsViewpoint(fix.coordinate.latitude, fix.coordinate.longitude))
            resolveGPSName(latitude: fix.coordinate.latitude,
                           longitude: fix.coordinate.longitude)
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
        if status == .ready {
            hasRenderedOnce = true
            // The scene for the CURRENT viewpoint is now on screen — the
            // mini-map tracks this, not `viewpoint`: a teleport retargets
            // `viewpoint` the moment the load starts, and the map pin jumping
            // while "Switching location" was still up read as already-arrived.
            renderedViewpoint = viewpoint
        }
        switch status {
        case let .preparingTerrain(progress?):
            setProgressTarget(progress, rendering: false)
        case let .rendering(progress):
            setProgressTarget(progress, rendering: true)
        case .ready where progressTimer != nil:
            // The load finished while the (rate-capped) display was still
            // mid-flight. Sweep visibly TO the end, then lift the card — a
            // bar that vanishes at 70% reads as broken. ~75 pts/s: from
            // half-bar this holds the cover ~0.35 s, never more than ~0.7 s.
            finishing = true
            targetProgress = 1.0
            inRenderingPhase = true
        case .failed where lastGoodViewpoint != nil:
            // A MOVE failed to load (offline teleport) but the previous scene
            // is still on screen: say so briefly in the status pill, then
            // quietly stand back at the place that actually rendered instead
            // of stranding the model somewhere the terrain never loaded.
            stopProgressSmoothing()
            self.status = .failed("Couldn't load that area — staying where you were.")
            let prior = lastGoodViewpoint
            failedMoveRevertTask?.cancel()
            failedMoveRevertTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.2))
                guard let self, !Task.isCancelled, let prior else { return }
                // A newer move (or retry) has taken over — leave it alone.
                guard case .failed = self.status else { return }
                // One shot: if returning home fails too (tiles somehow gone),
                // fall through to the persistent failure card, not a loop.
                self.lastGoodViewpoint = nil
                self.isManualViewpoint = prior.manual
                self.teleport(to: prior.viewpoint)
            }
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
    /// `.ready` arrived while the display was mid-sweep: run the bar to 100%
    /// at finish speed, THEN publish `.ready` (see progressTick).
    private var finishing = false

    private func setProgressTarget(_ target: Double, rendering: Bool) {
        // A fresh sweep (timer nil) starts at the first report; within one
        // load the shown value NEVER moves backward. Every load begins with a
        // non-progress status (.preparingTerrain(nil)) that stops the previous
        // sweep, so there is no "new load with a lower target" case to catch
        // here. The old extra reset ("target well below shown") misfired
        // MID-load: the creep runs up to 5 pts past the last real report, so
        // any real report landing under the crept value snapped the displayed
        // percent visibly backward.
        if progressTimer == nil {
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
        if finishing {
            // Finish sweep: the scene is ready behind the card — run the bar
            // to the very end fast enough to feel conclusive, slow enough to
            // be seen arriving. The full bar gets (at least) one tick on
            // screen before the card lifts.
            if shownProgress >= 0.9995 {
                stopProgressSmoothing()
                status = .ready
                return
            }
            shownProgress = min(1.0, shownProgress + 0.025)
            publishProgress()
            return
        }
        let gap = targetProgress - shownProgress
        if gap > 0 {
            // Sweep toward real reports at a CAPPED rate. The old spring ate
            // 25% of the gap per tick: a chunky per-tile target jump surged
            // the bar 30+ points in half a second, then slammed to a stop
            // (measured: 47→82% in one second on a cold Rockies load).
            // ≤0.6 pt/tick ≈ 18 pts/s reads as motion, not a teleport —
            // with a faster lane (still smooth) when the display has fallen
            // far behind a burst of real progress, so it can't still be
            // trailing by 30 points when the load completes.
            let cap = gap > 0.12 ? 0.012 : 0.006
            shownProgress = min(targetProgress,
                                shownProgress + min(max(gap * 0.06, 0.0035), cap))
        } else {
            // No fresh signal: creep toward a cap just past the last real
            // report, DECELERATING as it nears — an asymptote, not the old
            // hard stop (which froze the bar dead for ~6 s between tile
            // bursts). While RENDERING the cap stretches to 98.5%: the bake
            // holds its last report at 95% while the label anchors land, and
            // the bar sat visibly frozen there; now it keeps oozing through
            // the wait and .ready closes it out.
            let cap = min(targetProgress + 0.05, inRenderingPhase ? 0.985 : 0.97)
            let headroom = cap - shownProgress
            if headroom > 0 {
                shownProgress = min(cap, shownProgress + max(0.0004, headroom * 0.02))
            }
        }
        publishProgress()
    }

    private func publishProgress() {
        // @Published churn control: publish only when the displayed HALF-
        // point (or the phase message) actually changes. Whole-percent quanta
        // made the slow creep advance in visible once-a-second hops.
        let pct = Int((shownProgress * 200).rounded())
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
        finishing = false
    }

    /// Where the eye ACTUALLY stands, as reported by the renderer once a move
    /// settles. A "Stand here" summit snap moves the eye onto the RENDERED
    /// apex — up to ~600 m from the catalog point the viewpoint records — and
    /// the map pin should mark where you stand, not what you asked for.
    /// Never persisted: the saved viewpoint keeps the catalog request, so a
    /// relaunch re-runs the same deterministic snap instead of snapping from
    /// a snap.
    @Published private(set) var standingEyeCoordinate: CLLocationCoordinate2D?

    func eyeLanded(latitude: Double, longitude: Double) {
        standingEyeCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func eyeElevationResolved(_ meters: Double?) {
        let changed = meters != eyeElevationMeters
        eyeElevationMeters = meters
        // The selected peak's elevation ANGLE depends on the eye height, which
        // only resolves after the new render lands — refresh the annotation.
        if changed { reannotateSelection() }
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
            // .userInitiated: the first reveal waits on labels, and labels wait
            // on this publish — on efficiency cores the 4-source merge visibly
            // stretched the loading screen.
            let (peaks, lakes) = await Task.detached(priority: .userInitiated) {
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
                // GLOBAL FIRST wins duplicate fights: legacy packs and OSM
                // tile caches predate the saddle flag, so their copy of a gap
                // (different id, isSaddle=false) must never shadow the global
                // record. The old id-only dedup let both through — tapping
                // the pack's copy summit-snapped "Stand here" uphill of the
                // gap (Dip Top Gap bug).
                // Normalize the saddle flag by NAME for the LEGACY sources
                // only (bundled directory, packs, OSM tile caches — they
                // predate the flag, so "Easy Pass" drew a plain ink summit
                // dot). The global DB's kind is AUTHORITATIVE and must not be
                // second-guessed: "Heather Pass Peak" is natural=peak there,
                // and the name sweep briefly flipped it to a saddle. Global
                // first also keeps its verdict over any flipped legacy copy.
                let legacy = (bundled + packs + osm).map { p in
                    guard !p.isSaddle, p.nameSuggestsSaddle else { return p }
                    var q = p
                    q.isSaddle = true
                    return q
                }
                let merged = Peak.dedupedKeepingFirst(global + legacy)
                // Lakes: label range only (the far-tile radius — matches the
                // anchor cull), so the published set stays small even in lake
                // country.
                let lakes = GlobalPeakDatabase.lakes?.peaks(
                    nearLatitude: viewpoint.latitude, longitude: viewpoint.longitude,
                    withinMeters: FarHorizon.farTileMeters
                ) ?? []
                return (merged, lakes)
            }.value
            // Gate on COORDINATES, not the whole Viewpoint. `resolveGPSName`
            // replaces the viewpoint with a same-coordinate, renamed copy the
            // moment the reverse-geocode lands — and full-struct equality
            // (which includes `name`) then treated that rename as a location
            // change and dropped this result, so a GPS fix could finish with no
            // peaks and therefore no labels until an unrelated move rebuilt them.
            guard let self, let current = self.viewpoint,
                  current.latitude == viewpoint.latitude,
                  current.longitude == viewpoint.longitude else { return }
            self.allNearbyPeaks = peaks
            self.nearbyLakes = lakes
        }
    }

    /// Resolve a peak against the current viewpoint (distance / bearing / apparent
    /// elevation), pin its label open, and show its card. nil clears the card
    /// AND every pinned label (the empty-terrain tap dismisses everything).
    func select(_ peak: Peak?) {
        guard let peak, let viewpoint else {
            selectedPeak = nil
            pinnedPeakIDs = []
            return
        }
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
        pinnedPeakIDs = [peak.id]   // ONE label at a time: replace, never stack
        selectedPeak = AnnotatedPeak(
            peak: peak, azimuthDeg: bearing, elevationAngleDeg: angle, distanceMeters: distance
        )
    }

    /// A terrain tap on a label: an unpinned label pins open (and shows its
    /// card, like select); a pinned one collapses — losing its card if it was
    /// the selected one. Programmatic picks (search, debug args) use
    /// select(_:), which never collapses.
    func tapLabel(_ peak: Peak) {
        if pinnedPeakIDs.contains(peak.id) {
            pinnedPeakIDs.remove(peak.id)
            if selectedPeak?.peak.id == peak.id { selectedPeak = nil }
        } else {
            select(peak)
        }
    }

    /// The card's ✕: close the card; its label stays pinned on the terrain.
    func closeCard() { selectedPeak = nil }

    /// Stand on a peak: teleport the eye to the summit coordinate.
    func standOnPeak(_ annotated: AnnotatedPeak) {
        selectedPeak = nil
        pinnedPeakIDs = []
        let peak = annotated.peak
        // Saddles/gaps are LOW points: standing "here" means the pass itself,
        // never the neighboring summit the snap would climb to. Lakes are water:
        // the snap climbed the shoreline ridge (up to 250 m of it), leaving you
        // looking DOWN at the lake you asked to stand on — same rule as the
        // label anchors, which never summit-snap water.
        // The tapped record can be a STALE SNAPSHOT that lost the saddle flag
        // (a save from before the flag existed, a legacy pack copy) — so
        // resolve the freshest truth at the decision point: if ANY live-index
        // record for this same feature says saddle, or the name itself says
        // low point ("… Gap"/"… Pass"), the point IS the destination — never
        // climb the neighboring hill.
        // `nearbyLakes` only reaches 160 km from the CURRENT viewpoint, so a
        // lake teleported to from farther away (global search) classified as
        // a peak and summit-snapped onto its shoreline ridge — you arrived
        // ABOVE the lake you asked for (the Wing Lake bug). The bundled
        // global lakes file is the offline truth at any distance: one
        // cell-indexed lookup in the memory-mapped file (~µs, once per tap).
        let isWater = nearbyLakes.contains { $0.id == peak.id }
            || (GlobalPeakDatabase.lakes?.peaks(
                    nearLatitude: peak.latitude, longitude: peak.longitude,
                    withinMeters: 500).contains { $0.id == peak.id } ?? false)
        let liveSaddle = allNearbyPeaks.contains {
            ($0.id == peak.id
             || ($0.name.localizedCaseInsensitiveCompare(peak.name) == .orderedSame
                 && GeoMath.distanceMeters(
                        fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                        toLatitude: peak.latitude, toLongitude: peak.longitude) < 200))
            && $0.isSaddle
        }
        let isSaddle = peak.isSaddle || liveSaddle || peak.nameSuggestsSaddle
        let target = isSaddle || isWater ? nil
            : SummitTarget(peakID: peak.id, elevationMeters: peak.elevationMeters)
        teleport(to: Viewpoint(name: peak.name, latitude: peak.latitude, longitude: peak.longitude,
                               summitTarget: target),
                 manual: true)
    }

    // MARK: - GPS follow

    /// A GPS fix arrived while following. Never re-bake automatically (that's what made
    /// the app reload endlessly in a car). Instead, once the device has moved far enough
    /// from the baked viewpoint, surface a "Recenter" prompt with the latest position;
    /// the panorama stays frozen (and aligned, for distant terrain) until the user taps it.
    // MARK: - GPS viewpoint naming

    /// "47.6205° N, 122.3493° W" — a GPS viewpoint's PROVISIONAL name, shown
    /// until (and unless) the reverse geocoder supplies a friendly one. The
    /// old fixed "My location" told you nothing.
    private static func coordinateName(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.4f° %@, %.4f° %@",
               abs(lat), lat >= 0 ? "N" : "S",
               abs(lon), lon >= 0 ? "E" : "W")
    }

    private func gpsViewpoint(_ lat: Double, _ lon: Double) -> Viewpoint {
        Viewpoint(name: Self.coordinateName(lat, lon), latitude: lat, longitude: lon)
    }

    /// Best-effort friendly name for the spot you're standing (area of
    /// interest → locality → region — deliberately NOT the street address).
    /// Never gates anything: offline the coordinate name simply stays. The
    /// swap only lands if we're still GPS-following at (about) that fix.
    private func resolveGPSName(latitude: Double, longitude: Double) {
        Task { [weak self] in
            let loc = CLLocation(latitude: latitude, longitude: longitude)
            guard let pm = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return }
            let friendly = pm.areasOfInterest?.first
                ?? pm.subLocality ?? pm.locality ?? pm.administrativeArea
            guard let friendly else { return }
            await MainActor.run {
                guard let self, !self.isManualViewpoint, let vp = self.viewpoint,
                      abs(vp.latitude - latitude) < 0.01,
                      abs(vp.longitude - longitude) < 0.01 else { return }
                // Same spot: renderer dedupes by coordinate, so this renames
                // the card without a re-bake.
                self.viewpoint = Viewpoint(name: friendly,
                                           latitude: vp.latitude, longitude: vp.longitude)
            }
        }
    }

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
        resolveGPSName(latitude: next.latitude, longitude: next.longitude)
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
        let next = gpsViewpoint(fix.coordinate.latitude, fix.coordinate.longitude)
        guard viewpoint != nil else {
            awaitingGPSFix = false
            teleport(to: next)
            resolveGPSName(latitude: next.latitude, longitude: next.longitude)
            return
        }
        if awaitingGPSFix {
            // The user explicitly asked to stand at their position — honor the
            // first usable fix regardless of the recenter distance gate.
            awaitingGPSFix = false
            if isMeaningfulMove(to: fix.coordinate) {
                teleport(to: next)
                resolveGPSName(latitude: next.latitude, longitude: next.longitude)
            }
            return
        }
        queueGPS(next)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard viewpoint == nil else { return }
        teleport(to: Self.demoViewpoint)
    }
}
