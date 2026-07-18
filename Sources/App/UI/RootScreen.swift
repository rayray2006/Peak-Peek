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
    @State private var mode: TerrainViewMode = .threeD
    @State private var manualAlignment = false
    /// Label density (All / Sparse / None), persisted across launches.
    @AppStorage("labelDensity") private var labelDensityRaw = LabelDensity.all.rawValue
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
            onSunTimes: { model.sunTimesResolved($0) },
            onStatus: { model.renderStatusChanged($0) },
            onEyeElevation: { model.eyeElevationResolved($0) },
            onForceManual: { manualAlignment = true },
            arRecenterToken: arRecenterToken,
            onARAdjustedChanged: { arAdjusted = $0 },
            onAlignmentNudged: { alignmentNudges &+= 1 },
            captureToken: captureToken,
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
            onToggleImmersive: {
                withAnimation(.easeInOut(duration: 0.22)) { immersive.toggle() }
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
                        .opacity(immersive ? 0 : 1)
                        .allowsHitTesting(!immersive)
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
        .preferredColorScheme(isNight ? .dark : .light)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showPhotoShutter)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSaveLocation)
        // A panel opening takes over the bottom region — the armed shutter and
        // the Save Spot sheet yield.
        .onChange(of: activeSheet) { _, sheet in
            if sheet != nil {
                showPhotoShutter = false
                showSaveLocation = false
            }
        }
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
            // Debug: teleport to raw coordinates on launch — reproduces reports
            // anywhere on Earth (e.g. -viewpoint "-8.8497,-77.5949").
            if let i = args.firstIndex(of: "-viewpoint"), i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 {
                    model.teleport(to: .init(name: "Debug viewpoint",
                                             latitude: parts[0], longitude: parts[1]),
                                   manual: true)
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
                    for s in saves {
                        if let hit = model.allNearbyPeaks.first(where: { $0.name.lowercased() == s.name }),
                           !peakLists.contains(hit, in: s.kind) {
                            peakLists.toggle(hit, in: s.kind)
                            NSLog("save debug: \(s.kind) ← \(hit.name)")
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
                        NSLog("standOn debug: standing on \(hit.name) @ \(hit.latitude),\(hit.longitude)")
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
                RegionManagerView(store: regions, currentViewpoint: model.viewpoint)
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
                signal: AnyHashable("\(model.viewpoint?.latitude ?? 0)|\(model.viewpoint?.longitude ?? 0)|\(model.pendingRecenter != nil)|\(statusIsReady)")
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
                .padding(.horizontal, 12)
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
        // form, then collapse 3.6 s after the LAST change.
        .task(id: signal) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expanded = true
            }
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
                } else if !hideBottomChrome {
                    // Hidden while the search panel (or the landscape Time card)
                    // is up: they occupy exactly this region, and both want the
                    // terrain — not chrome — behind them.
                    footer
                    Spacer()
                    // In landscape the OPEN action menu reaches down into the
                    // mini-map's corner — yield it while the menu is up rather
                    // than stacking the two.
                    if let viewpoint = model.viewpoint,
                       !(showActionMenu && isChromeLandscape) {
                        MiniMapView(viewpoint: viewpoint, isManualViewpoint: model.isManualViewpoint) {
                            activeSheet = .map
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding()
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
            actionRail.padding([.horizontal, .bottom]).padding(.top, 24)
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

    /// The displayed sky is night: the display time (live or simulated) falls
    /// outside the viewed location's sunrise–sunset window. Drives the theme
    /// inversion. Defaults to day until the celestial pass lands (and in
    /// polar edge cases where the sun never crosses the horizon).
    private var isNight: Bool {
        guard let sun = model.sunTimes,
              let sunrise = sun.sunrise, let sunset = sun.sunset else { return false }
        return model.displayDate < sunrise || model.displayDate > sunset
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

                    // Photo: arm the shutter popup (capture on ITS button, not here —
                    // the user frames the shot first).
                    controlButton("Photo", systemName: "camera", prominence: .secondary) {
                        showPhotoShutter = true
                        collapseActionMenu()
                    }
                    menuDivider

                    // Save the current viewpoint as a named Saved location.
                    controlButton("Save Spot", systemName: "bookmark", prominence: .secondary) {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                    .frame(width: 20)
            }
            .foregroundStyle(TopoStyle.inkColor)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text("Terrain unavailable")
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
        statusCard(spacing: 8) {
            Text("Switching location")
                .font(PPFont.ui(16, .semibold))
            PPProgressLine(progress: progress, width: 220, height: 2)
            WhimsyLine(style: .card)
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
        "Stitching terrain tiles",
        "Carving the valleys",
        "Raising the mountains",
        "Dropping the shadows",
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
        "Waking the glaciers",
        "Polishing the horizon",
        "Herding stray boulders",
        "Triangulating the summits",
        "Tuning the alpenglow",
        "Lifting the fog",
        "Fluffing the clouds",
        "Seeding the meadows",
        "Planting the wildflowers",
        "Watering the rivers",
        "Bridging the creeks",
        "Stacking the cairns",
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
    ].shuffled()
}

/// One cycling whimsy line ("Carving the valleys…"), in the template's IBM
/// Plex Mono. Cross-fades to the next line every ~3.2 s. Starts at a random
/// spot in the (launch-shuffled) pool so back-to-back loads don't always open
/// on the same chore.
private struct WhimsyLine: View {
    enum Style {
        /// Centered on the launch screen.
        case paper
        /// Leading inside the switching-location card.
        case card
    }
    var style: Style = .paper
    @State private var index = Int.random(in: 0..<LoadingWhimsy.lines.count)

    var body: some View {
        Text("\(LoadingWhimsy.lines[index % LoadingWhimsy.lines.count])…")
            .font(PPFont.mono(12))
            .foregroundStyle(style == .paper
                ? TopoStyle.inkColor : TopoStyle.inkColor.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.85)     // safety net; lines are sized to fit
            .contentTransition(.opacity)
            // Fixed width so the hosting surface doesn't resize with every
            // line — sized to the longest chore in the pool.
            .frame(width: style == .paper ? 232 : 220,
                   alignment: style == .paper ? .center : .leading)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
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
                    PPMicroLabel(text: "v1.0 · surveying the range", opacity: 0.3)
                        .padding(.bottom, 34)
                }
            }
        }
    }
}
