import SwiftUI

/// The app's single-screen experience: PeakPeek's live raymarched panorama
/// front and center, a quiet status pill while terrain loads, a viewpoint footer,
/// and a corner map that opens the teleport picker. (HUD ported from RidgeLine's
/// RootScreen; the central canvas is PeakPeek's live Metal view, and the
/// peak/sky/AR chrome is added in later phases.)
struct RootScreen: View {
    @StateObject private var model = PanoramaViewModel()
    @StateObject private var peakLists = PeakListStore()
    @StateObject private var regions = RegionStore()
    /// One sheet at a time, switchable: setting a NEW case while another sheet is
    /// up dismisses it and presents the new one (five independent booleans made a
    /// tap on "Offline" from inside the Time sheet wait until Time was closed).
    private enum ActiveSheet: String, Identifiable {
        case map, directory, lists, time, regions
        var id: String { rawValue }
    }
    @State private var activeSheet: ActiveSheet?
    /// False during an orientation snap: chrome hides instantly, then fades
    /// back in at its new layout (see RotationAnimationDisabler).
    @State private var chromeVisible = true
    /// Immersive view (double tap on the terrain): the whole HUD — footer,
    /// mini-map, controls, compass — fades out for an unobstructed panorama.
    /// Double tap again to bring it back.
    @State private var immersive = false
    @State private var showActionMenu = false
    /// The tapped location card's info card, for viewpoints that are NOT a
    /// catalog feature (GPS spots, map pins): name + coordinates + Save Spot.
    @State private var showLocationCard = false
    @State private var mode: TerrainViewMode = .threeD
    @State private var manualAlignment = false
    /// Label density (All / Sparse / Saved / None), persisted across
    /// launches. Sparse by default: well-separated peaks at 1×, everything
    /// on zoom-in.
    @AppStorage("labelDensity") private var labelDensityRaw = LabelDensity.sparse.rawValue
    private var labelDensity: LabelDensity {
        LabelDensity(rawValue: labelDensityRaw) ?? .all
    }
    /// AR drag calibration: whether an offset is applied, + a token to clear it.
    @State private var arAdjusted = false
    @State private var arRecenterToken = 0
    /// Counts alignment-changing drags — each one re-introduces the Realign
    /// button (expands it back to icon + label for a beat).
    @State private var alignmentNudges = 0
    /// Where the peak info card should RETURN on close when the selection came
    /// from a panel (Lists / Search): closing the card reopens that panel, so
    /// browsing peaks one after another doesn't mean reopening the list each
    /// time. Terrain interactions (tapping the world, "Stand here") clear it —
    /// those mean the user has moved on, not "back to the list".
    @State private var cardReturnSheet: ActiveSheet?
    /// Panel state that must survive the panel closing for the card round-trip:
    /// the search query and the Lists tab live here, not in the panels.
    @State private var searchQuery = ""
    @State private var listsSelection: PeakListKind = .wantToClimb
    /// Photo capture: token requests a capture; flash confirms the save.
    /// The menu's Photo button ARMS the shutter popup rather than firing —
    /// the capture happens on the popup's shutter press, once framed.
    @State private var captureToken = 0
    @State private var captureFlash = false
    @State private var showPhotoShutter = false
    /// Photo-sheet toggles (template's Labels / Compass chips): what gets
    /// composited into the captured image. Persisted across launches.
    @AppStorage("photoIncludesLabels") private var photoIncludesLabels = true
    @AppStorage("photoIncludesCompass") private var photoIncludesCompass = false
    /// "Save Spot": names the current viewpoint and adds it to the Saved list.
    @State private var showSaveLocation = false
    @State private var saveLocationName = ""
    /// Debug (-openSheet): sheet to present once the first render lands —
    /// presenting during the loading→HUD swap gets torn down with it.
    @State private var debugPendingSheet: ActiveSheet?
    /// Debug (-openSaveSpot / -openPhoto): same wait-for-render deal.
    @State private var debugPendingSaveSpot = false
    @State private var debugPendingPhoto = false
    /// Debug (-standOn): feature name to stand on once the render + labels land.
    @State private var debugStandOnName: String?
    /// Debug (-climb/-bookmark): peak names to toggle into the saved lists.
    @State private var debugSaveNames: [(name: String, kind: PeakListKind)] = []
    /// Landscape (short vertical axis): caps the action menu height (see actionRail).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isChromeLandscape: Bool { verticalSizeClass == .compact }
    /// The footer + mini-map hide while an overlay panel occupies their region.
    private var hideBottomChrome: Bool {
        activeSheet != nil && activeSheet != .map
    }

    /// The terrain render view, extracted from `body`: the ~20-argument init
    /// plus its closures pushed the ZStack expression past the type-checker's
    /// complexity budget (a hard build error, not just slow compiles).
    private var terrainView: TerrainMetalView {
        TerrainMetalView(
            viewpoint: model.viewpoint,
            exaggeration: model.terrainExaggeration,
            displayDate: model.displayDate,
            mode: mode,
            manualAlignment: manualAlignment,
            labelDensity: labelDensity,
            climbedPeakIDs: peakLists.climbedIDs,
            bookmarkedPeakIDs: peakLists.bookmarkedIDs,
            peaks: model.allNearbyPeaks,
            lakes: model.nearbyLakes,
            selectedPeak: model.selectedPeak,
            onSelectPeak: { peak in
                // A terrain tap (select or deselect) breaks the panel round-trip.
                cardReturnSheet = nil
                model.select(peak)
                // Terrain taps are also the way OUT of floating chrome: the
                // tap-outside scrims are gone (they blocked pinch/pan on the
                // terrain), so collapse the menu and inline panels here. The
                // map is a real sheet (terrain untappable under it) and search
                // keeps its own keyboard-owning scrim.
                collapseActionMenu()
                if let sheet = activeSheet, sheet != .map, sheet != .directory {
                    activeSheet = nil
                }
            },
            onVisibleFeatures: { model.visibleFeaturesResolved($0) },
            onDEMTiles: { model.demTilesResolved(near: $0, far: $1) },
            onSunTimes: { model.sunTimesResolved($0) },
            onStatus: { model.renderStatusChanged($0) },
            onEyeElevation: { model.eyeElevationResolved($0) },
            onForceManual: { manualAlignment = true },
            arRecenterToken: arRecenterToken,
            cancelMoveToken: model.moveCancelToken,
            onARAdjustedChanged: { arAdjusted = $0 },
            onAlignmentNudged: { alignmentNudges &+= 1 },
            onNightChanged: { isNight = $0 },
            captureToken: captureToken,
            unitsStamp: unitsRaw,
            photoFraming: showPhotoShutter,
            captureIncludesLabels: photoIncludesLabels,
            captureIncludesCompass: photoIncludesCompass,
            onPhotoCaptured: { ok in
                guard ok else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.easeOut(duration: 0.08)) { captureFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeIn(duration: 0.25)) { captureFlash = false }
                }
            },
            immersive: immersive,
            onEmptyTap: { clearedSkyTag in
                // A tap on nothing: its first job is dismissing whatever is
                // open — the reading every open surface already trained. Only
                // a tap with NOTHING to dismiss toggles the immersive
                // chrome-hide (this replaced the old double tap: same
                // feature-tap exclusions, one less gesture to discover).
                var consumed = clearedSkyTag
                if model.selectedPeak != nil { model.select(nil); consumed = true }
                if showLocationCard { showLocationCard = false; consumed = true }
                cardReturnSheet = nil
                if showActionMenu { collapseActionMenu(); consumed = true }
                if let sheet = activeSheet, sheet != .map, sheet != .directory {
                    activeSheet = nil
                    consumed = true
                }
                guard !showPhotoShutter else { return }   // framing owns the chrome
                if !consumed {
                    withAnimation(.easeInOut(duration: 0.22)) { immersive.toggle() }
                }
            }
        )
    }

    var body: some View {
        ZStack {
            // The render subviews counter-rotate INSIDE TerrainContainerView
            // (same layout transaction as the system rotation — see its
            // layoutSubviews), so the terrain never moves when the interface
            // rotates; RotationAnimationDisabler makes the switch a single frame.
            terrainView
                .ignoresSafeArea()
                .background(.black)
                .background(RotationAnimationDisabler())

            if shouldShowInitialLoading {
                InitialLoadingScreen(
                    title: initialLoadingTitle,
                    message: initialLoadingMessage,
                    progress: initialLoadingProgress,
                    isFailed: initialLoadingFailed
                )
                .transition(.opacity)
                .zIndex(2)
            } else {
                // The interface rotates NATIVELY (sheets, menus, safe areas all
                // correct); only the terrain container is counter-rotated below so
                // the device-verified render/attitude pipeline stays glued to the
                // hardware exactly as in portrait. The chrome group fades out for
                // the rotation snap and dissolves back in at its new positions.
                Group {
                    hud
                        // Photo framing hides every non-photo control too —
                        // the frame is the interface.
                        .opacity(immersive || showPhotoShutter ? 0 : 1)
                        .allowsHitTesting(!immersive && !showPhotoShutter)
                    timePanel
                    regionsPanel
                    listsPanel
                    searchPanel
                    saveSpotPanel
                    if showPhotoShutter {
                        photoShutterPopup
                    }
                }
                .opacity(chromeVisible ? 1 : 0)
                if captureFlash {
                    Color.white.ignoresSafeArea().allowsHitTesting(false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowInitialLoading)
        .animation(.easeInOut(duration: 0.25), value: arAdjusted)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.pendingRecenter != nil)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: manualAlignment)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.isManualViewpoint)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.usesSimulatedTime)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.awaitingGPSFix)
        .animation(.easeInOut(duration: 0.2), value: activeSheet)
        // The info card ↔ switching-location swap during a move.
        .animation(.easeInOut(duration: 0.2), value: statusIsReady)
        // After sunset (at the VIEWED location, in simulated time too) the
        // whole theme inverts: ink chrome turns white, paper sheets turn dark —
        // legible against the night render. The dynamic TopoStyle colors and
        // every UIKit-backed view resolve against this scene-wide scheme.
        // Theme mode can pin it Day or Night; Auto follows the sky (fed by
        // the renderer's onNightChanged, in the same beat the sky changes).
        .preferredColorScheme(resolvedScheme)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showPhotoShutter)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSaveLocation)
        // A panel opening takes over the bottom region — the armed shutter and
        // the Save Spot sheet yield.
        .onChange(of: activeSheet) { _, sheet in
            if sheet != nil {
                showPhotoShutter = false
                showSaveLocation = false
                showLocationCard = false
            }
        }
        // The location card describes where you STAND — a move retires it.
        .onChange(of: model.viewpoint) { _, _ in showLocationCard = false }
        // Selecting a feature replaces it with the feature's card; keep it
        // retired so it doesn't pop back when that card closes.
        .onChange(of: model.selectedPeak?.peak.id) { _, id in
            if id != nil { showLocationCard = false }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showLocationCard)
        // The info card slides in/out with selection (picking from search runs
        // this together with the panel's activeSheet dismissal above).
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.selectedPeak?.peak.id)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: RotationAnimationDisabler.willRotate)) { _ in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { chromeVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: RotationAnimationDisabler.didRotate)) { _ in
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true }
        }
        .onAppear {
            model.start()
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-arEdges") { mode = .arEdges }
            else if args.contains("-arRelief") { mode = .arRelief }
            else if args.contains("-arLabels") { mode = .arLabels }
            if args.contains("-manual") { manualAlignment = true }
            // Debug: start in immersive (chrome-hidden) view — the simulator
            // can't synthesize the double tap that toggles it.
            if args.contains("-immersive") { immersive = true }
            // Debug: set label density (all/sparse/none) — the setting persists
            // via AppStorage, so tests reset it explicitly.
            if let i = args.firstIndex(of: "-labels"), i + 1 < args.count {
                labelDensityRaw = (LabelDensity.allCases.first {
                    $0.title.lowercased() == args[i + 1].lowercased()
                } ?? .all).rawValue
            }
            // Debug: open the Time controls on launch (simulator can't tap the menu).
            if args.contains("-openTime") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { activeSheet = .time }
            }
            // Debug: open any sheet by name (map/directory/lists/time/regions), or
            // the action menu — same reason as -openTime.
            if let i = args.firstIndex(of: "-openSheet"), i + 1 < args.count,
               let sheet = ActiveSheet(rawValue: args[i + 1]) {
                debugPendingSheet = sheet
            }
            if args.contains("-openMenu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showActionMenu = true }
                }
            }
            // Debug: open the Save Spot / Photo bottom sheets (they're not
            // ActiveSheet cases, so -openSheet can't reach them).
            if args.contains("-openSaveSpot") { debugPendingSaveSpot = true }
            if args.contains("-openPhoto") { debugPendingPhoto = true }
            // Debug: force landscape (the simulator's rotate menu can't be driven
            // headlessly; the app asks the scene to rotate itself instead).
            // -landscapeDelay <s> delays the request, e.g. to rotate with a sheet up.
            if args.contains("-landscape") || args.contains("-landscapeDelay") {
                var delay = 1.0
                if let i = args.firstIndex(of: "-landscapeDelay"), i + 1 < args.count,
                   let s = Double(args[i + 1]) { delay = s }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                        .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
            if args.contains("-night") {   // simulate 11 PM so stars/Milky Way + moon show
                let t = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
                model.setDisplayDate(t)
            }
            if let i = args.firstIndex(of: "-simHour"), i + 1 < args.count, let h = Double(args[i + 1]) {
                let base = Calendar.current.startOfDay(for: Date())
                model.setDisplayDate(base.addingTimeInterval(h * 3600))
            }
            // Debug: auto-capture a photo (the simulator can't tap the shutter);
            // pair with -captureToDocuments to verify the composited output.
            if let i = args.firstIndex(of: "-autoCaptureAfter"), i + 1 < args.count,
               let s = Double(args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) { captureToken &+= 1 }
            }
            // Debug: auto-select a peak (the simulator can't synthesize a tap) to
            // exercise the detail panel.
            if args.contains("-selectTopPeak") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    if let top = model.allNearbyPeaks.max(by: { $0.priority < $1.priority }) {
                        model.select(top)
                    }
                }
            }
            // Debug: auto-select a NAMED peak/lake for the info card —
            // e.g. -select "Diablo Lake" (lakes have no other headless path).
            if let i = args.firstIndex(of: "-select"), i + 1 < args.count {
                let needle = args[i + 1].lowercased()
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    if let hit = (model.allNearbyPeaks + model.nearbyLakes)
                        .first(where: { $0.name.lowercased() == needle }) {
                        model.select(hit)
                    } else {
                        NSLog("select debug: no feature named '\(needle)' nearby")
                    }
                }
            }
            // Debug: pin the sky to an instant (unix epoch seconds) — makes
            // sunrise/sunset states reproducible, e.g. -displayDate 1789000000.
            if let i = args.firstIndex(of: "-displayDate"), i + 1 < args.count,
               let epoch = Double(args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    model.setDisplayDate(Date(timeIntervalSince1970: epoch))
                }
            }
            // Debug: teleport to raw coordinates on launch — reproduces reports
            // anywhere on Earth (e.g. -viewpoint "-8.8497,-77.5949").
            // -viewpointDelay <s> defers it, so the RESTORED scene renders
            // first and the jump exercises the mid-session move path.
            if let i = args.firstIndex(of: "-viewpoint"), i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                var delay = 0.0
                if let d = args.firstIndex(of: "-viewpointDelay"), d + 1 < args.count {
                    delay = Double(args[d + 1]) ?? 0
                }
                if parts.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        model.teleport(to: .init(name: "Debug viewpoint",
                                                 latitude: parts[0], longitude: parts[1]),
                                       manual: true)
                    }
                }
            }
            // Debug: tap the switching card's ✕ after a delay — exercises the
            // mid-move cancel headlessly (pair with -viewpoint/-viewpointDelay:
            // the delay must land while that move's fetch is still running).
            if let i = args.firstIndex(of: "-cancelMoveAfter"), i + 1 < args.count,
               let delay = Double(args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSLog("debug -cancelMoveAfter: cancelling (canCancel=%d)",
                          model.canCancelMove ? 1 : 0)
                    model.cancelLocationChange()
                }
            }
            // Debug: "Stand here" on a named peak/lake once the render is up —
            // exercises the teleport path headlessly (e.g. -standOn "Lake Ann").
            if let i = args.firstIndex(of: "-standOn"), i + 1 < args.count {
                let needle = args[i + 1].lowercased()
                debugStandOnName = needle
            }
            // Debug: toggle a named peak into the saved lists (the simulator
            // can't tap the info-card chips) — e.g. -climb "Dege Peak".
            for (flag, kind) in [("-climb", PeakListKind.climbed),
                                 ("-bookmark", PeakListKind.wantToClimb)] {
                if let i = args.firstIndex(of: flag), i + 1 < args.count {
                    debugSaveNames.append((args[i + 1].lowercased(), kind))
                }
            }
        }
        .onChange(of: shouldShowInitialLoading) { _, loading in
            guard !loading else { return }
            if let sheet = debugPendingSheet {
                debugPendingSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { activeSheet = sheet }
            }
            if debugPendingSaveSpot {
                debugPendingSaveSpot = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    saveLocationName = model.viewpoint?.name ?? ""
                    showSaveLocation = true
                }
            }
            if debugPendingPhoto {
                debugPendingPhoto = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showPhotoShutter = true }
            }
            if !debugSaveNames.isEmpty {
                let saves = debugSaveNames
                debugSaveNames = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    // Comma-separated names, each optionally "name@year" to
                    // backdate the entry (exercises the year separators):
                    // -bookmark "ruby mountain@2023,colonial peak".
                    for s in saves {
                        for token in s.name.split(separator: ",") {
                            var name = token.trimmingCharacters(in: .whitespaces)
                            var year: Int?
                            if let at = name.lastIndex(of: "@"), let y = Int(name[name.index(after: at)...]) {
                                year = y
                                name = String(name[..<at])
                            }
                            guard let hit = model.allNearbyPeaks.first(where: { $0.name.lowercased() == name }),
                                  !peakLists.contains(hit, in: s.kind) else { continue }
                            peakLists.toggle(hit, in: s.kind)
                            if let year,
                               let d = Calendar.current.date(from: DateComponents(year: year, month: 6, day: 15)) {
                                peakLists.setDate(d, for: hit, in: s.kind)
                            }
                            NSLog("save debug: \(s.kind) ← \(hit.name)\(year.map { " @\($0)" } ?? "")")
                        }
                    }
                }
            }
            if let needle = debugStandOnName {
                debugStandOnName = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    // Nearest match: names repeat across a 120 km radius (three
                    // different "Lake Ann"s fit inside it in the North Cascades).
                    let vp = model.viewpoint
                    if let hit = (model.allNearbyPeaks + model.nearbyLakes)
                        .filter({ $0.name.lowercased() == needle })
                        .min(by: { a, b in
                            guard let vp else { return true }
                            let da = GeoMath.distanceMeters(
                                fromLatitude: vp.latitude, fromLongitude: vp.longitude,
                                toLatitude: a.latitude, toLongitude: a.longitude)
                            let db = GeoMath.distanceMeters(
                                fromLatitude: vp.latitude, fromLongitude: vp.longitude,
                                toLatitude: b.latitude, toLongitude: b.longitude)
                            return da < db
                        }) {
                        NSLog("standOn debug: standing on \(hit.name) @ \(hit.latitude),\(hit.longitude) id=\(hit.id) saddle=\(hit.isSaddle) ele=\(hit.elevationMeters)")
                        model.select(hit)
                        if let sel = model.selectedPeak { model.standOnPeak(sel) }
                    } else {
                        NSLog("standOn debug: no feature named '\(needle)' nearby")
                    }
                }
            }
        }
        .sheet(item: sheetItem) { _ in
            // Only the map picker is ever a sheet (sheetItem yields .map or nil);
            // Time/Lists/Regions render as inline PanelCards and search as the
            // inline bottom panel — see below.
            TeleportMapView(
                currentViewpoint: model.viewpoint,
                isManualViewpoint: model.isManualViewpoint,
                lists: peakLists,
                visibility: { model.visibilityVerdict(for: $0) }
            ) { viewpoint in
                model.teleport(to: viewpoint, manual: true)
            }
            .presentationDragIndicator(.visible)
        }
    }

    /// Only the map presents as a sheet. The panels are inline (PanelCard /
    /// `searchPanel`): compact-height sheets ignore detents and cover the whole
    /// screen, which hid the very sky/terrain the panels adjust.
    private var sheetItem: Binding<ActiveSheet?> {
        Binding(
            get: { activeSheet == .map ? .map : nil },
            set: { newValue in
                // Only the map picker presents as a sheet; the panels manage
                // themselves. Ignore SwiftUI's nil write-backs for them.
                if newValue == nil, activeSheet == .map { activeSheet = nil }
            }
        )
    }


    /// Search: an inline card pinned to the bottom (the keyboard pushes it up),
    /// never a sheet — sheet detents made typing and swipe-dismiss miserable.
    @ViewBuilder private var searchPanel: some View {
        if activeSheet == .directory {
            // GeometryReader: the container's height is what's genuinely left
            // above the keyboard (this panel deliberately rides it) — the card
            // caps its result rows to fit that, whatever the phone size.
            GeometryReader { geo in
                VStack {
                    // Invisible scrim: tapping anywhere above the card closes search
                    // (and with it the keyboard) — the standard way out, alongside
                    // the card's own swipe-down.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { activeSheet = nil }
                    PeakDirectoryView(
                        model: model,
                        query: $searchQuery,
                        savedPeaks: (peakLists.peaks(in: .wantToClimb)
                            + peakLists.peaks(in: .climbed)).map(\.peak),
                        availableHeight: geo.size.height,
                        onPick: { peak in
                            cardReturnSheet = .directory
                            model.select(peak)
                            activeSheet = nil
                        },
                        onClose: { activeSheet = nil }
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Landscape Time controls: a trailing card over the view, so the sun/moon/
    /// stars visibly react while scrubbing.
    @ViewBuilder private var timePanel: some View {
        if activeSheet == .time {
            // The template's landscape Time card is the same stack, 430 pt wide.
            PanelCard(maxWidth: isChromeLandscape ? 430 : 560, title: "Time",
                      onClose: { activeSheet = nil }) {
                TimeControlsView(model: model, compact: isChromeLandscape)
            }
        }
    }

    @ViewBuilder private var listsPanel: some View {
        if activeSheet == .lists {
            PanelCard(maxWidth: 560, height: isChromeLandscape ? 312 : 420,
                      title: "Lists", onClose: { activeSheet = nil }) {
                PeakListsView(store: peakLists, viewpoint: model.viewpoint,
                              selection: $listsSelection,
                              onPick: { peak in
                                  cardReturnSheet = .lists
                                  model.select(peak)
                                  activeSheet = nil
                              })
            }
        }
    }

    @ViewBuilder private var regionsPanel: some View {
        if activeSheet == .regions {
            PanelCard(maxWidth: 720, height: isChromeLandscape ? 336 : 540,
                      title: "Offline", onClose: { activeSheet = nil }) {
                RegionManagerView(store: regions, currentViewpoint: model.viewpoint,
                                  isManualViewpoint: model.isManualViewpoint)
            }
        }
    }

    /// "Save Spot": the template's white bottom sheet — name field, mono
    /// coordinates line, black Save button. (Replaces the old system alert.)
    @ViewBuilder private var saveSpotPanel: some View {
        if showSaveLocation {
            PanelCard(maxWidth: 560, title: "Save Spot",
                      onClose: { showSaveLocation = false }) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Name this spot", text: $saveLocationName)
                        .font(PPFont.ui(15))
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
                        )
                    Text(saveSpotCoordsLine)
                        .font(PPFont.mono(11))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                    Button {
                        saveCurrentLocation()
                        showSaveLocation = false
                    } label: {
                        Text("Save")
                            .font(PPFont.ui(15, .semibold))
                            .foregroundStyle(TopoStyle.paperColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(TopoStyle.inkColor, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
        }
    }

    /// "47.4419° N, 122.1430° W · 50 ft" for the Save Spot sheet.
    private var saveSpotCoordsLine: String {
        guard let vp = model.viewpoint else { return "" }
        var line = String(format: "%.4f° %@, %.4f° %@",
                          abs(vp.latitude), vp.latitude >= 0 ? "N" : "S",
                          abs(vp.longitude), vp.longitude >= 0 ? "E" : "W")
        if let elevation = model.eyeElevationMeters {
            line += " · \(UnitText.elevation(meters: elevation))"
        }
        return line
    }

    /// Top-left "return to reality" controls: hidden until their action applies,
    /// then an accent capsule appears. Whichever are active stack downward from the
    /// same top-left anchor, so one active button sits exactly where two would start.
    /// • Use GPS — POSITION: shown when you're viewing from somewhere other than
    ///   your live location (teleport, or GPS-follow drifted). Tap returns to your
    ///   real position — and resets alignment too, so the view matches reality.
    /// • Realign — ALIGNMENT: shown when the view's heading has been nudged off
    ///   device tracking (a drag calibration offset, or no-IMU manual look-around).
    ///   Tap snaps back to pure device-tracked alignment.
    /// • Live Time — TIME: shown while the sky is simulated (Time scrubber).
    ///   Tap returns to the real current time.
    private var topLeftControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Appears only when it MEANS something — but the trigger is very
            // sensitive (50 m recenter threshold), and the awaiting state keeps
            // it visible while a pressed request waits on a fix.
            if model.pendingRecenter != nil || model.isManualViewpoint || model.awaitingGPSFix {
            StateButton(
                title: model.awaitingGPSFix ? "Locating…" : "Use GPS",
                systemImage: "location.fill",
                prominent: model.pendingRecenter != nil || model.isManualViewpoint,
                busy: model.awaitingGPSFix,
                // Every move re-introduces the button (teleports change the
                // viewpoint; drifting past the recenter threshold flips
                // pending). statusIsReady folds in so the announcement lands
                // AFTER the load — not burned during the switching card.
                signal: AnyHashable("\(model.viewpoint?.latitude ?? 0)|\(model.viewpoint?.longitude ?? 0)|\(model.pendingRecenter != nil)|\(statusIsReady)"),
                // …and gates it: the signal also changes the moment a move
                // STARTS (viewpoint/status flip), which used to expand the
                // label right away — stay collapsed until the move completes.
                announce: statusIsReady
            ) {
                // Returning to your real position also returns to DEVICE-driven
                // alignment — keeping the earlier drag offset would show your own
                // location pointing somewhere you aren't looking.
                if arAdjusted { arRecenterToken &+= 1 }
                if model.pendingRecenter != nil, !model.isManualViewpoint {
                    model.recenter()
                } else {
                    manualAlignment = false
                    model.followGPS()
                }
            }
            }
            if arAdjusted || (manualAlignment && !mode.usesCamera) {
                StateButton(title: "Realign", systemImage: "hand.draw",
                            prominent: true, busy: false,
                            // Each alignment-changing drag re-introduces it.
                            signal: AnyHashable(alignmentNudges)) {
                    if arAdjusted { arRecenterToken &+= 1 }
                    manualAlignment = false
                }
            }
            if model.usesSimulatedTime {
                StateButton(title: "Live Time", systemImage: "clock.arrow.circlepath",
                            prominent: true, busy: false,
                            // Each Time-sheet scrub re-introduces it (collapse
                            // waits 3.6 s after the LAST change).
                            signal: AnyHashable(model.displayDate)) {
                    model.resetDisplayDateToNow()
                }
            }
        }
    }

    /// The app's ONE menu-card style, both orientations: the template's white
    /// bottom sheet — grabber, optional "Title + ✕" row, radius 24, soft drop
    /// shadow, terrain visible around it — with interactive swipe-down. Drag
    /// displacement lives HERE so a swipe re-renders only the card, not the
    /// whole root (which made MapKit jitter).
    private struct PanelCard<C: View>: View {
        let maxWidth: CGFloat
        var height: CGFloat? = nil
        var title: String? = nil
        let onClose: () -> Void
        @ViewBuilder let content: () -> C
        @State private var drag: CGFloat = 0

        var body: some View {
            ZStack(alignment: .bottom) {
                // Layout filler only (keeps the card bottom-anchored) — NOT a
                // tap scrim: hit-testing here blocked pinch-zoom and look-around
                // on the terrain while a panel was up. Terrain taps close the
                // panel instead (onSelectPeak in terrainView); the card also
                // swipes down.
                Color.clear
                VStack(spacing: 0) {
                    Capsule()
                        .fill(TopoStyle.hairline(0.15))
                        .frame(width: 36, height: 4)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    if let title {
                        HStack {
                            Text(title)
                                .font(PPFont.ui(16, .semibold))
                                .foregroundStyle(TopoStyle.inkColor)
                            Spacer()
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                                    .contentShape(Rectangle().inset(by: -12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    content()
                }
                .frame(maxWidth: maxWidth)
                .frame(height: height)
                .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
                .padding(.horizontal, 16)   // 12 read cramped on narrow phones
                .padding(.bottom, 12)
                // Displacement + swipe live on the CARD (not the scrim): the
                // swipe re-renders only the card, and the scrim stays put.
                .offset(y: max(0, drag))
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { v in
                            let h = v.translation.height
                            drag = h >= 0 ? h : -12 * (1 - 1 / (1 - h / 50))
                        }
                        .onEnded { v in
                            if v.translation.height > 70 || v.predictedEndTranslation.height > 180 {
                                onClose()
                                drag = 0
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    drag = 0
                                }
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// A state capsule that introduces itself: appears with icon + label, then
    /// after a beat shrinks leftward to just the icon — the user learns what
    /// the glyph means without the button permanently costing that width.
    /// While busy ("Locating…") the label stays until the work resolves.
    private struct StateButton: View {
    let title: String
    let systemImage: String
    var prominent = true
    var busy = false
    /// Re-introduces the button (expands icon → icon + label, then collapses
    /// again after a beat) every time this value changes — so "the related
    /// thing changed again" always re-announces what the button undoes.
    var signal: AnyHashable = AnyHashable(0)
    /// Gates the announcement: while false, signal changes (and the button's
    /// own first appearance) keep it COLLAPSED instead of expanding — used
    /// mid-move so the label only lands when the move completes, not when it
    /// starts.
    var announce = true
    let action: () -> Void
    @State private var expanded = true

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(TopoStyle.inkColor)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                // Collapse by CLIPPING in place (width -> 0, anchored at its
                // leading edge): the text fades where it stands instead of
                // sliding leftward across the icon.
                Text(title)
                    .font(PPFont.ui(13, .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 6)
                    .frame(width: expanded || busy ? nil : 0, alignment: .leading)
                    .clipped()
                    .opacity(expanded || busy ? 1 : 0)
            }
            // Paper pill, ink content — white with black glyphs by day,
            // inverting after sunset like the peak-label pills.
            .foregroundStyle(TopoStyle.inkColor.opacity(prominent ? 1 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TopoStyle.paperColor.opacity(prominent ? 1 : 0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1))
            // Icon-only is a small target: generous invisible slop.
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
        // Restarts whenever `signal` changes: expand (back) to the labelled
        // form, then collapse 3.6 s after the LAST change. A gated change
        // (`announce == false`, e.g. a move just STARTED) collapses instead —
        // the announcement belongs to the completion signal.
        .task(id: signal) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expanded = announce
            }
            guard announce else { return }
            try? await Task.sleep(for: .seconds(3.6))
            // A signal change mid-sleep CANCELS this task; `try?` swallows
            // that, so without this guard the dying task collapsed the button
            // while its replacement expanded it — a visible jitter on every
            // Time-scrub tick.
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expanded = false
            }
        }
    }
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                topLeftControls
                Spacer()
            }
            Spacer()
            HStack(alignment: .bottom) {
                // The search panel owns the bottom region while it's up — the
                // card would otherwise peek out from behind it. On pick, the
                // panel leaves and the card arrives in the same beat. During a
                // move (Use GPS / "Stand here" while a peak is selected), the
                // card yields this slot to the footer's "Switching location"
                // progress card and returns once the new view is up.
                if let selected = model.selectedPeak, activeSheet != .directory,
                   statusIsReady {
                    PeakInfoPanel(
                        peak: selected,
                        isVisible: model.visibilityVerdict(for: selected.peak),
                        isClimbed: peakLists.contains(selected.peak, in: .climbed),
                        beenDate: peakLists.peaks(in: .climbed)
                            .first { $0.peak.id == selected.peak.id }?.climbedAt,
                        isBookmarked: peakLists.contains(selected.peak, in: .wantToClimb),
                        onToggleClimbed: { peakLists.toggle(selected.peak, in: .climbed) },
                        onToggleBookmark: { peakLists.toggle(selected.peak, in: .wantToClimb) },
                        onVisit: {
                            cardReturnSheet = nil          // moving on, not going back
                            model.standOnPeak(selected)
                        },
                        onDismiss: {
                            model.select(nil)
                            // Return to the panel the pick came from — unless some
                            // other panel opened in the meantime.
                            if activeSheet == nil, let back = cardReturnSheet {
                                activeSheet = back
                            }
                            cardReturnSheet = nil
                        }
                    )
                    // Landscape: cap the width instead of spanning the whole
                    // (wide) screen; the card still hugs its content below the
                    // cap and stays bottom-leading. (A width cap, NOT
                    // fixedSize: the card's adaptive rows (ViewThatFits) need
                    // a real width proposal — under fixedSize's ideal-size
                    // query they collapsed to their narrowest variant.)
                    .frame(maxWidth: isChromeLandscape ? 400 : .infinity, alignment: .leading)
                    // Arrive from the bottom edge (mirroring the search panel's
                    // exit) so pick-from-search reads as one handoff motion.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // (No mini-map beside the card: it owns the full width so
                    // long peak names fit on one line.)
                    Spacer(minLength: 0)
                } else if showLocationCard, let vp = model.viewpoint,
                          activeSheet != .directory, statusIsReady {
                    // Tapping the location card opens THIS when the eye stands
                    // somewhere without a catalog feature: name, coordinates,
                    // elevation, and the way into the Save Spot sheet.
                    LocationInfoCard(
                        viewpoint: vp,
                        elevationMeters: model.eyeElevationMeters,
                        onSave: {
                            showLocationCard = false
                            saveLocationName = vp.name
                            showSaveLocation = true
                        },
                        onDismiss: { showLocationCard = false }
                    )
                    .frame(maxWidth: isChromeLandscape ? 400 : .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    Spacer(minLength: 0)
                } else if !hideBottomChrome {
                    // Hidden while the search panel (or the landscape Time card)
                    // is up: they occupy exactly this region, and both want the
                    // terrain — not chrome — behind them.
                    footer
                    Spacer()
                    // In landscape the OPEN action menu reaches down into the
                    // mini-map's corner — yield it while the menu is up rather
                    // than stacking the two.
                    // `renderedViewpoint`, not `viewpoint`: the map pin moves
                    // when the scene actually swaps, not the moment a move
                    // starts loading.
                    if let viewpoint = model.renderedViewpoint ?? model.viewpoint,
                       !(showActionMenu && isChromeLandscape) {
                        MiniMapView(viewpoint: viewpoint, isManualViewpoint: model.isManualViewpoint) {
                            activeSheet = .map
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        // 20 pt sides (not the default 16): on narrower phones (iPhone 13
        // class) the chrome read cramped against the screen edges.
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // (No tap-outside scrim for the open menu: it swallowed EVERY touch, so
        // pinch-zoom and look-around died while the menu was up. Terrain taps
        // collapse it instead — see the onSelectPeak closure in terrainView.)
        // The rail floats above the HUD rows: inside the top row, the OPEN menu's
        // height was capped by whatever the bottom (footer/mini-map) row left over,
        // which in landscape clipped the last item mid-row. The mini-map yields
        // (above) while the landscape menu is open, so nothing stacks.
        // Top padding 24 (not the default 16) centres the ☰ glyph on the
        // compass TRACK line (safe-area top + 12 + 27 in CompassZoomOverlayView
        // vs. the button's 15 pt half-height) — at 16 it floated awkwardly
        // between the heading text and the line.
        .overlay(alignment: .topTrailing) {
            actionRail.padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 24)
        }
        // Pin the HUD to the TRUE bottom. Without this the bottom row avoids the
        // keyboard, so picking a search result made the info card appear
        // mid-screen (above the keyboard) and then drop once the keyboard left —
        // a two-step jump. Only the search panel should ride the keyboard.
        .ignoresSafeArea(.keyboard)
    }

    /// Photo capture, armed by the menu's Photo button: nothing but the
    /// camera-style shutter floating over the terrain, a quiet ✕ above it —
    /// no sheet, no chrome, the shot being framed IS the interface.
    /// Capturing the very moment the menu item was tapped saved a frame with
    /// the menu still animating away — and gave no chance to frame the shot.
    private var photoShutterPopup: some View {
        ZStack {
            // Tap anywhere off the controls to stand down.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { showPhotoShutter = false }
            VStack {
                Spacer()
                VStack(spacing: 18) {
                    Button {
                        showPhotoShutter = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TopoStyle.inkColor.opacity(0.7))
                            .frame(width: 34, height: 34)
                            .contentShape(Circle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel photo")

                    // Shutter centered; what-goes-in-the-photo checkboxes on
                    // its sides. They preview LIVE: toggling shows/hides the
                    // overlay on screen, so the frame is exactly the capture.
                    HStack {
                        photoCheck("Labels", isOn: $photoIncludesLabels)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            captureToken &+= 1
                            showPhotoShutter = false
                        } label: {
                            ZStack {
                                Circle().stroke(TopoStyle.inkColor, lineWidth: 3)
                                    .frame(width: 62, height: 62)
                                Circle().fill(TopoStyle.inkColor)
                                    .frame(width: 50, height: 50)
                            }
                            .contentShape(Circle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take photo")
                        photoCheck("Compass", isOn: $photoIncludesCompass)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                }
                // Clear the footer/mini-map row: the shutter floats in the
                // free center ABOVE them (a wide location card can reach the
                // screen's middle, so the lift is generous).
                .padding(.bottom, 56)
            }
            .padding()
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// A minimal checkbox: 14 pt hairline square, ink check when on, mono
    /// label — quiet enough to live beside the shutter.
    private func photoCheck(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(TopoStyle.inkColor.opacity(0.6), lineWidth: 1.25)
                        .frame(width: 14, height: 14)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TopoStyle.inkColor)
                    }
                }
                Text(title)
                    .font(PPFont.mono(11))
                    .tracking(0.5)
            }
            .foregroundStyle(TopoStyle.inkColor.opacity(0.85))
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var shouldShowInitialLoading: Bool {
        !model.hasRenderedOnce
    }

    /// No load in flight: the peak info card may hold the bottom-left slot.
    /// Anything else (locating, terrain prep, render, failure) hands it to
    /// the footer's status card.
    private var statusIsReady: Bool {
        if case .ready = model.status { return true }
        return false
    }

    /// The displayed sky is night — drives the Auto theme inversion. Set by
    /// the renderer's `onNightChanged` in the SAME beat the live sky sun
    /// applies (scene swaps, time scrubs, month jumps), so the theme can
    /// never lag the scene or flash against stale sunrise/sunset data.
    @State private var isNight = false

    /// Theme: Auto follows the displayed sky (the signature inversion);
    /// Day / Night pin it. (Raw values stay `light`/`dark` — they're what
    /// existing installs have persisted in AppStorage.)
    enum ThemeMode: String, CaseIterable {
        case auto, light, dark
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .light: return "Day"
            case .dark: return "Night"
            }
        }
        var systemImage: String {
            switch self {
            case .auto: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }
        var next: ThemeMode {
            switch self {
            case .auto: return .light
            case .light: return .dark
            case .dark: return .auto
            }
        }
    }
    @AppStorage("themeMode") private var themeModeRaw = ThemeMode.auto.rawValue
    private var themeMode: ThemeMode { ThemeMode(rawValue: themeModeRaw) ?? .auto }

    /// Units override ("" = follow locale) — the menu toggles ft ↔ m.
    @AppStorage(UnitText.overrideKey) private var unitsRaw = ""

    private var resolvedScheme: ColorScheme {
        switch themeMode {
        case .auto: return isNight ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Kills the interface-rotation animation: the terrain is counter-rotated in
    /// the SAME layout pass (TerrainContainerView.layoutSubviews), but the system's
    /// animated transition would still visibly swing it mid-flight. Disabling
    /// animations for the transition makes the whole rotation a single-frame snap —
    /// the terrain pixels never move; only the chrome jumps to its new layout.
    private struct RotationAnimationDisabler: UIViewControllerRepresentable {
        static let willRotate = Notification.Name("pp.rotation.will")
        static let didRotate = Notification.Name("pp.rotation.did")

        final class VC: UIViewController {
            override func viewWillTransition(to size: CGSize,
                                             with coordinator: UIViewControllerTransitionCoordinator) {
                super.viewWillTransition(to: size, with: coordinator)
                // No animated sweep: the terrain is counter-rotated in the same
                // layout pass, so the world never moves. The CHROME hides for
                // the single-frame snap and dissolves back in at its new
                // positions (RootScreen listens) — a hard teleporting cut was
                // the jarring part.
                NotificationCenter.default.post(name: RotationAnimationDisabler.willRotate, object: nil)
                UIView.setAnimationsEnabled(false)
                coordinator.animate(alongsideTransition: nil) { _ in
                    UIView.setAnimationsEnabled(true)
                    NotificationCenter.default.post(name: RotationAnimationDisabler.didRotate, object: nil)
                }
            }
        }
        func makeUIViewController(context: Context) -> VC { VC() }
        func updateUIViewController(_ vc: VC, context: Context) {}
    }

    private var initialLoadingFailed: Bool {
        if case .failed = model.status { return true }
        return false
    }

    private var initialLoadingTitle: String {
        initialLoadingFailed ? "Terrain unavailable" : "PeakPeek"
    }

    /// Unified load fraction for the loading bar (continuous across the
    /// terrain + render phases — see PanoramaViewModel's progress smoothing).
    private var initialLoadingProgress: Double? {
        switch model.status {
        case let .preparingTerrain(progress): return progress
        case let .rendering(progress): return progress
        default: return nil
        }
    }

    /// nil while the terrain loads/renders — the loading screen cycles its
    /// whimsy lines then (with the percent appended from `progress`).
    private var initialLoadingMessage: String? {
        switch model.status {
        case .idle: return "Preparing terrain…"
        case .locating: return "Finding your location…"
        case .preparingTerrain, .rendering: return nil
        case .ready: return "Finalizing view…"
        case .failed(let message): return message
        }
    }

    // The compass + zoom readout are drawn by `CompassZoomOverlayView` inside the
    // terrain view (RidgeLine-exact), updated from the renderer each frame.

    // MARK: - Action rail

    private var actionRail: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showActionMenu.toggle()
                }
            } label: {
                Image(systemName: showActionMenu ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(menuIconColor)
                    .frame(width: 30, height: 30)
                    // Generous invisible hit slop (58 pt target) — the visual
                    // stays a 30 pt glyph but the tap area extends well past it.
                    .contentShape(Rectangle().inset(by: -14))
            }
            .buttonStyle(.plain)

            if showActionMenu {
                // Scrollable + height-capped so landscape's short axis can't push
                // the menu (or the ✕ above it) off screen — it scrolls instead.
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 0) {
                    // Cycle 3D → AR → Edges. Stays open so it can be cycled live.
                    controlButton(
                        "View: \(mode.title)",
                        systemName: mode.systemImage,
                        prominence: mode == .threeD ? .secondary : .primary
                    ) {
                        mode = mode.next
                    }
                    menuDivider

                    // (Recenter moved to the fixed top-left controls.)

                    // Cycle All → Sparse → Saved → None. Stays open so it can be
                    // cycled live.
                    controlButton(
                        "Points: \(labelDensity.title)",
                        systemName: labelDensity == .none ? "circle.slash"
                            : labelDensity == .saved ? "bookmark"
                            : labelDensity == .sparse ? "circle.grid.2x2" : "circle.grid.3x3",
                        prominence: labelDensity == .all ? .secondary : .primary
                    ) {
                        labelDensityRaw = labelDensity.next.rawValue
                    }
                    menuDivider

                    // Cycle Auto → Day → Night. Stays open for live cycling.
                    controlButton(
                        "Theme: \(themeMode.title)",
                        systemName: themeMode.systemImage,
                        prominence: themeMode == .auto ? .secondary : .primary
                    ) {
                        themeModeRaw = themeMode.next.rawValue
                    }
                    menuDivider

                    // Toggle ft ↔ m (seeded from the locale on first toggle).
                    controlButton(
                        "Units: \(UnitText.usesFeet ? "ft" : "m")",
                        systemName: "ruler",
                        prominence: unitsRaw.isEmpty ? .secondary : .primary
                    ) {
                        unitsRaw = UnitText.usesFeet ? "metric" : "imperial"
                    }
                    menuDivider

                    // Photo: arm the shutter popup (capture on ITS button, not here —
                    // the user frames the shot first). Arming takes over the
                    // screen, so any open panel yields — the same one-thing-
                    // at-a-time rule the panels apply to the shutter.
                    controlButton("Photo", systemName: "camera", prominence: .secondary) {
                        activeSheet = nil
                        showSaveLocation = false
                        showPhotoShutter = true
                        collapseActionMenu()
                    }
                    menuDivider

                    // Save the current viewpoint as a named Saved location.
                    // Same takeover rule as Photo: open panels yield first.
                    controlButton("Save Spot", systemName: "bookmark", prominence: .secondary) {
                        activeSheet = nil
                        showPhotoShutter = false
                        saveLocationName = model.viewpoint?.name ?? ""
                        showSaveLocation = true
                        collapseActionMenu()
                    }
                    menuDivider

                    controlButton("Search", systemName: "magnifyingglass", prominence: .secondary) {
                        // Toggle: a second tap closes the inline panel.
                        activeSheet = activeSheet == .directory ? nil : .directory
                        collapseActionMenu()
                    }
                    menuDivider

                    controlButton("Lists", systemName: "checklist", prominence: .secondary) {
                        activeSheet = .lists
                        collapseActionMenu()
                    }
                    menuDivider

                    controlButton("Time", systemName: "clock",
                                  prominence: model.usesSimulatedTime ? .warning : .secondary) {
                        activeSheet = .time
                        collapseActionMenu()
                    }
                    menuDivider

                    controlButton("Offline", systemName: "arrow.down.circle",
                                  prominence: regions.isDownloading ? .warning : .secondary) {
                        activeSheet = .regions
                        collapseActionMenu()
                    }
                }
                }
                .frame(maxHeight: isChromeLandscape ? 290 : .infinity)
                .fixedSize(horizontal: false, vertical: !isChromeLandscape)
                // Grow out of the ☰ button (top-trailing corner, right above
                // this menu) rather than sliding in from the screen's top edge.
                .transition(.scale(scale: 0.1, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    /// The template's short trailing-aligned hairline between menu rows.
    private var menuDivider: some View {
        Rectangle()
            .fill(TopoStyle.hairline(0.15))
            .frame(width: 28, height: 1)
    }

    private var menuIconColor: Color {
        // Plain ink, always — active states show inside the menu rows
        // (semibold), not on the toggle glyph.
        TopoStyle.inkColor
    }

    /// Save the current viewpoint as a custom Saved location: a synthetic Peak
    /// (id "loc_…") that then flows through the lists, search, the info card,
    /// and the map's saved badges exactly like a saved summit. Elevation is the
    /// eye's resolved ground height, so the card and rows have a real number.
    private func saveCurrentLocation() {
        guard let vp = model.viewpoint else { return }
        let trimmed = saveLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let peak = Peak(
            id: "loc_\(UUID().uuidString)",
            name: trimmed.isEmpty ? vp.name : trimmed,
            latitude: vp.latitude, longitude: vp.longitude,
            elevationMeters: model.eyeElevationMeters ?? 0,
            prominenceMeters: nil
        )
        peakLists.toggle(peak, in: .wantToClimb)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Location-card tap: standing ON a catalog feature (a "Stand here" visit
    /// keeps its name) opens that feature's full card; anywhere else opens the
    /// plain location card.
    private func showLocationInfo(_ viewpoint: PanoramaViewModel.Viewpoint) {
        if let hit = (model.allNearbyPeaks + model.nearbyLakes).first(where: {
            $0.name == viewpoint.name &&
            GeoMath.distanceMeters(
                fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                toLatitude: viewpoint.latitude, toLongitude: viewpoint.longitude) < 1_000
        }) {
            model.select(hit)
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showLocationCard = true
            }
        }
    }

    private func collapseActionMenu() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            showActionMenu = false
        }
    }

    private enum ControlProminence { case primary, secondary, warning }

    /// A menu row, straight from the template: "Label + icon", Space Grotesk 15,
    /// ink, right-aligned, 44 pt tall. Active states (non-default cycles,
    /// simulated time, a running download) simply read semibold — no accent.
    private func controlButton(
        _ title: String,
        systemName: String,
        prominence: ControlProminence,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(PPFont.ui(15, prominence == .secondary ? .medium : .semibold))
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .regular))
                    // 26, not 20: wide glyphs (mountain.2) overflowed a 20 pt
                    // box and the ScrollView clipped them at the row's edge.
                    .frame(width: 26)
            }
            .foregroundStyle(TopoStyle.inkColor)
            .frame(height: 44)
            .contentShape(Rectangle())
            // Cycling rows swap their title + icon INSTANTLY and together —
            // inherited transactions animated the width change first and the
            // glyph swap after, a two-step stutter on some rows.
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
    }

    /// The info card for a viewpoint that is NOT a catalog feature (GPS spot,
    /// map pin, saved location): name over the coordinates + elevation in
    /// mono, and a single Save Spot action — PeakInfoPanel's language without
    /// the peak-only rows.
    private struct LocationInfoCard: View {
        let viewpoint: PanoramaViewModel.Viewpoint
        let elevationMeters: Double?
        let onSave: () -> Void
        let onDismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(viewpoint.name)
                    .font(PPFont.ui(18, .semibold))
                    .foregroundStyle(TopoStyle.inkColor)
                    .lineLimit(1)
                    .padding(.trailing, 28)
                Text(statsLine)
                    .font(PPFont.mono(12))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                    .lineLimit(1)
                Button(action: onSave) {
                    HStack(spacing: 7) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(TopoStyle.inkColor.opacity(0.8))
                        Text("Save Spot")
                            .font(PPFont.ui(14, .semibold))
                            .foregroundStyle(TopoStyle.inkColor)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
            .overlay(alignment: .topTrailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(2)
            }
        }

        /// "48.5000° N, 121.0800° W · 5,547 ft"
        private var statsLine: String {
            var parts = [String(
                format: "%.4f° %@, %.4f° %@",
                abs(viewpoint.latitude), viewpoint.latitude >= 0 ? "N" : "S",
                abs(viewpoint.longitude), viewpoint.longitude >= 0 ? "E" : "W")]
            if let elevationMeters {
                parts.append(UnitText.elevation(meters: elevationMeters))
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Location / status card (bottom-left black card)

    /// The template's black bottom-left card. Ready: viewpoint name + mono
    /// elevation. Loading (teleports, "Stand here"): "Switching location" with
    /// the thin white progress line and a cycling mono whimsy line. Failure:
    /// the error, in the same card.
    @ViewBuilder
    private var footer: some View {
        switch model.status {
        case .ready:
            if let viewpoint = model.viewpoint {
                statusCard {
                    Text(viewpoint.name)
                        .font(PPFont.ui(15, .semibold))
                        .lineLimit(1)
                    if let elevation = model.eyeElevationMeters {
                        Text(UnitText.elevation(meters: elevation))
                            .font(PPFont.mono(11))
                            .opacity(0.6)
                    }
                }
                .contentShape(Rectangle())
                // Tap: the full info card for where you stand — the catalog
                // feature's card when standing ON one, else the plain
                // location card (coordinates + Save Spot).
                .onTapGesture { showLocationInfo(viewpoint) }
            }
        case .locating:
            statusCard(spacing: 6) {
                Text("Finding your location")
                    .font(PPFont.ui(15, .semibold))
                Text("Waiting for a GPS fix…")
                    .font(PPFont.mono(11))
                    .opacity(0.6)
            }
        case let .preparingTerrain(progress):
            switchingCard(progress: progress ?? 0)
        case let .rendering(progress):
            switchingCard(progress: progress)
        case .failed(let message):
            statusCard(spacing: 6) {
                // With a scene still up this is a failed MOVE (offline
                // teleport) about to fall back — connection is the story.
                // With nothing rendered it's the launch-load failure.
                Text(model.hasRenderedOnce ? "No connection" : "Terrain unavailable")
                    .font(PPFont.ui(15, .semibold))
                Text(message)
                    .font(PPFont.mono(11))
                    .opacity(0.6)
                    .frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .idle:
            EmptyView()
        }
    }

    /// Hugs its content — the card is only as wide as its longest line.
    /// Paper with ink text, same polarity as every other pill in the chrome
    /// (it used to be the one inverted black card by day).
    private func statusCard<C: View>(
        spacing: CGFloat = 2, @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .foregroundStyle(TopoStyle.inkColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1)
            )
    }

    private func switchingCard(progress: Double) -> some View {
        // Bar and status line span the card's full content width — they used
        // to float small (130 pt bar, 11 pt text) inside a much wider pill.
        // 180 pt (not 220): this card shares its row with the 104 pt mini-map,
        // and at 220 the fixed content overflowed the row on narrow phones —
        // the whole HUD pressed against the screen edges (and the title
        // wrapped) for the duration of every switch.
        statusCard(spacing: 8) {
            Text("Switching location")
                .font(PPFont.ui(16, .semibold))
                .lineLimit(1)
                .fixedSize()
            PPProgressLine(progress: progress, width: 180, height: 2)
            WhimsyLine(style: .card)
        }
        // ✕ = abandon the move and stand back at the previous scene. Only
        // offered when there IS one (a first launch load can't go back).
        .overlay(alignment: .topTrailing) {
            if model.canCancelMove {
                Button { model.cancelLocationChange() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(1)
            }
        }
    }
}

// MARK: - Loading whimsy

/// The loading lines — mountain chores, three words apiece; each is a cute
/// version of something the pipeline really does. Shuffled once per launch.
/// Shared by the initial loading screen AND the in-app status pill, so every
/// load (first open, teleports, "Stand here") gets the same playful readout.
private enum LoadingWhimsy {
    static let lines: [String] = [
        "Stitching tiles",
        "Carving valleys",
        "Raising the mountains",
        "Dropping shadows",
        "Filling the lakes",
        "Sharpening the ridgelines",
        "Untangling contour lines",
        "Consulting a marmot",
        "Aligning the compass",
        "Measuring the prominence",
        "Naming the peaks",
        "Placing the sun",
        "Shooing the clouds",
        "Smoothing the foothills",
        "Counting the switchbacks",
        "Pitching base camp",
        "Sliding down glaciers",
        "Polishing the horizon",
        "Herding stray boulders",
        "Triangulating the summits",
        "Tuning the alpenglow",
        "Lifting the fog",
        "Fluffing the clouds",
        "Seeding the meadows",
        "Planting wildflowers",
        "Bridging creeks",
        "Stacking cairns",
        "Charting the ridges",
        "Combing the treeline",
        "Growing the forests",
        "Raking the scree",
        "Rolling the moraine",
        "Deepening the gorges",
        "Widening the vistas",
        "Aging the granite",
        "Triggering the avalanches",
        "Chilling the snowfields",
        "Hanging the stars",
        "Feeding the chipmunks",
        "Petting the goats",
        "Calibrating the altimeter",
        "Drawing the map",
        "Brewing summit coffee",
        "Tightening guylines",
        "Skipping some stones",
        "Flagging false summits",
        "Dusting the peaks",
        "Booping mushrooms",
        "Picking berries",
        "Losing the trail",
        "Trusting the cairns",
        "Swatting mosquitos",
        "Spraying dew",
        "Following the bootpack",
        "Going glissading",
    ]
}

/// The whimsy rotation's shared cursor. WhimsyLine used to keep its shuffled
/// order and timer in per-instance @State, but SwiftUI freely recreates the
/// view (the status card is a different `switch` branch per load phase, and
/// each branch is a fresh structural identity) — every recreation reshuffled
/// and swapped the line immediately, so lines visibly rotated early. One
/// process-wide cursor instead: a recreated instance shows the line already
/// up and waits out the REMAINDER of its interval, and the timestamp guard
/// means even two live instances can't double-advance the rotation.
@MainActor
private enum WhimsyClock {
    static let interval: TimeInterval = 2.0
    /// Random per-launch palette start, so the first line isn't always coral.
    static let colorOffset = Int.random(in: 0..<6)
    private(set) static var order = LoadingWhimsy.lines.shuffled()
    private(set) static var index = 0
    /// When the current line went up — recreated views resume this countdown.
    private(set) static var shownAt = Date.now

    static var currentLine: String { order[index] }

    static var remaining: TimeInterval {
        max(0.05, interval - Date.now.timeIntervalSince(shownAt))
    }

    /// Advance to the next line, unless another instance just did (its reset
    /// timestamp makes this a no-op). Exhausting the pool reshuffles, with the
    /// new first line guaranteed to differ from the last one shown (no
    /// back-to-back repeats, ever).
    static func advanceIfDue() {
        guard Date.now.timeIntervalSince(shownAt) >= interval - 0.1 else { return }
        if index + 1 >= order.count {
            var next = LoadingWhimsy.lines.shuffled()
            if next.first == order.last, next.count > 1 { next.swapAt(0, 1) }
            order = next
            index = 0
        } else {
            index += 1
        }
        shownAt = .now
    }
}

/// One cycling whimsy line ("Carving the valleys…"), in the template's IBM
/// Plex Mono. Cross-fades to the next line every ~2 s through the shared
/// WhimsyClock order. Colors rotate through the soft warm-to-cool set —
/// pastels on dark, deeper siblings on paper so they read on white.
private struct WhimsyLine: View {
    enum Style {
        /// Centered on the launch screen.
        case paper
        /// Leading inside the switching-location card.
        case card
    }
    var style: Style = .paper
    @Environment(\.colorScheme) private var scheme
    /// Render trigger only — the line/color come from WhimsyClock; bumping
    /// this re-evaluates body after each advance.
    @State private var tick = 0

    /// Coral → amber → sage → sky → lavender → rose, one per message.
    /// Pastels for dark surfaces (the original launch-screen set)…
    private static let pastel: [Color] = [
        Color(red: 1.00, green: 0.66, blue: 0.51),   // coral
        Color(red: 1.00, green: 0.80, blue: 0.55),   // amber
        Color(red: 0.68, green: 0.90, blue: 0.72),   // sage
        Color(red: 0.62, green: 0.84, blue: 1.00),   // sky
        Color(red: 0.79, green: 0.75, blue: 1.00),   // lavender
        Color(red: 1.00, green: 0.72, blue: 0.82),   // rose
    ]
    /// …and ink-deep siblings that hold up on paper white.
    private static let deep: [Color] = [
        Color(red: 0.78, green: 0.33, blue: 0.20),   // coral
        Color(red: 0.70, green: 0.49, blue: 0.10),   // amber
        Color(red: 0.24, green: 0.53, blue: 0.32),   // sage
        Color(red: 0.16, green: 0.44, blue: 0.68),   // sky
        Color(red: 0.42, green: 0.36, blue: 0.74),   // lavender
        Color(red: 0.72, green: 0.29, blue: 0.44),   // rose
    ]

    var body: some View {
        let palette = scheme == .dark ? Self.pastel : Self.deep
        let line = WhimsyClock.currentLine
        // A ZStack of id-keyed Texts, NOT contentTransition(.opacity): the
        // in-place glyph cross-fade laid the incoming line out against the
        // outgoing line's width, so it appeared offset (and mis-scaled via
        // minimumScaleFactor) and snapped into place as the fade settled.
        // Separate Texts each get their final layout before fading.
        return ZStack(alignment: style == .paper ? .center : .leading) {
            Text("\(line)…")
                .font(PPFont.mono(12))
                .foregroundStyle(palette[(WhimsyClock.index + WhimsyClock.colorOffset) % palette.count])
                .lineLimit(1)
                .minimumScaleFactor(0.85)     // safety net; lines are sized to fit
                .transition(.opacity)
                .id(line)
        }
        // Fixed width so the hosting surface doesn't resize with every
        // line — the paper size fits the longest chore; the card size matches
        // the switching card's slimmed 180 pt bar (minimumScaleFactor absorbs
        // the few longest lines).
        .frame(width: style == .paper ? 232 : 180,
               alignment: style == .paper ? .center : .leading)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WhimsyClock.remaining))
                guard !Task.isCancelled else { break }
                WhimsyClock.advanceIfDue()
                withAnimation(.easeInOut(duration: 0.35)) { tick += 1 }
            }
        }
    }
}

// MARK: - Loading screen

/// The template's launch screen: paper white, the ink mark, the wordmark, a
/// 1 px 200 pt progress line, a cycling mono status line, and the quiet
/// versioned caption pinned to the bottom.
private struct InitialLoadingScreen: View {
    let title: String
    /// Fixed status line ("Finding your location", errors). nil while terrain
    /// loads — the screen cycles the whimsy lines instead.
    let message: String?
    /// Unified 0-1 load fraction (continuous across the terrain + render
    /// phases); nil while there's nothing to measure yet (locating, etc.).
    let progress: Double?
    let isFailed: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    /// The climber mark (white on transparent, bundled with the resources) —
    /// drawn as a template so it renders in ink on the paper screen.
    private static let mark: UIImage? = Bundle.main
        .path(forResource: "logo_mark", ofType: "png")
        .flatMap { UIImage(contentsOfFile: $0) }
        .map { $0.withRenderingMode(.alwaysTemplate) }

    var body: some View {
        ZStack {
            TopoStyle.paperColor.ignoresSafeArea()

            VStack(spacing: isCompact ? 14 : 24) {
                if let mark = Self.mark {
                    Image(uiImage: mark)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(TopoStyle.inkColor)
                        .frame(width: isCompact ? 80 : 110, height: isCompact ? 80 : 110)
                }
                Text(title)
                    .font(PPFont.ui(25, .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(TopoStyle.inkColor)

                VStack(spacing: 16) {
                    if !isFailed {
                        PPProgressLine(progress: progress ?? 0, width: 200)
                    }
                    Group {
                        if isFailed {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(message ?? "")
                                    .multilineTextAlignment(.center)
                            }
                            .font(PPFont.mono(12))
                            .foregroundStyle(TopoStyle.occludedColor)
                        } else if let message {
                            Text(message)
                                .font(PPFont.mono(12))
                                .foregroundStyle(TopoStyle.inkColor)
                        } else {
                            WhimsyLine()
                        }
                    }
                }
                .padding(.top, isCompact ? 2 : 12)
            }
            .padding(.horizontal, 32)

            if !isCompact {
                VStack {
                    Spacer()
                    PPMicroLabel(text: "v1.0", opacity: 0.3)
                        .padding(.bottom, 34)
                }
            }
        }
    }
}
