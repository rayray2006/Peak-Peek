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
    /// Photo capture: token requests a capture; flash confirms the save.
    @State private var captureToken = 0
    @State private var captureFlash = false
    /// Debug (-openSheet): sheet to present once the first render lands —
    /// presenting during the loading→HUD swap gets torn down with it.
    @State private var debugPendingSheet: ActiveSheet?
    /// Debug (-standOn): feature name to stand on once the render + labels land.
    @State private var debugStandOnName: String?
    /// Debug (-climb/-bookmark): peak names to toggle into the saved lists.
    @State private var debugSaveNames: [(name: String, kind: PeakListKind)] = []
    /// Landscape (short vertical axis): caps the action menu height (see actionRail).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isChromeLandscape: Bool { verticalSizeClass == .compact }
    /// The footer + mini-map hide while an overlay panel occupies their region.
    private var hideBottomChrome: Bool {
        activeSheet == .directory || (activeSheet == .time && isChromeLandscape)
    }

    var body: some View {
        ZStack {
            // The render subviews counter-rotate INSIDE TerrainContainerView
            // (same layout transaction as the system rotation — see its
            // layoutSubviews), so the terrain never moves when the interface
            // rotates; RotationAnimationDisabler makes the switch a single frame.
            TerrainMetalView(
                viewpoint: model.viewpoint,
                exaggeration: model.terrainExaggeration,
                displayDate: model.displayDate,
                mode: mode,
                manualAlignment: manualAlignment,
                labelDensity: labelDensity,
                climbedPeakIDs: Set(peakLists.peaks(in: .climbed).map(\.peak.id)),
                bookmarkedPeakIDs: Set(peakLists.peaks(in: .wantToClimb).map(\.peak.id)),
                peaks: model.allNearbyPeaks,
                lakes: model.nearbyLakes,
                selectedPeak: model.selectedPeak,
                onSelectPeak: { model.select($0) },
                onVisibleFeatures: { model.visibleFeaturesResolved($0) },
                onStatus: { model.renderStatusChanged($0) },
                onEyeElevation: { model.eyeElevationResolved($0) },
                onHeading: { model.headingResolved($0) },
                onZoom: { model.zoomResolved($0) },
                onForceManual: { manualAlignment = true },
                arRecenterToken: arRecenterToken,
                onARAdjustedChanged: { arAdjusted = $0 },
                captureToken: captureToken,
                onPhotoCaptured: { ok in
                    guard ok else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.easeOut(duration: 0.08)) { captureFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeIn(duration: 0.25)) { captureFlash = false }
                    }
                }
            )
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
                // hardware exactly as in portrait.
                hud
                centeredStatus
                landscapeTimePanel
                searchPanel
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
        // The info card slides in/out with selection (picking from search runs
        // this together with the panel's activeSheet dismissal above).
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.selectedPeak?.peak.id)
        .statusBarHidden()
        .onAppear {
            model.start()
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-arEdges") { mode = .arEdges }
            else if args.contains("-arRelief") { mode = .arRelief }
            else if args.contains("-arLabels") { mode = .arLabels }
            if args.contains("-manual") { manualAlignment = true }
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
        .sheet(item: sheetItem) { sheet in
            switch sheet {
            case .map:
                TeleportMapView(currentViewpoint: model.viewpoint) { viewpoint in
                    model.teleport(to: viewpoint, manual: true)
                }
            case .directory:
                // Never presented — search renders inline (see `searchPanel`);
                // the case exists because ActiveSheet still models the state.
                EmptyView()
            case .lists:
                PeakListsView(store: peakLists, viewpoint: model.viewpoint) { peak in
                    model.select(peak)
                }
            case .time:
                TimeControlsView(model: model)
            case .regions:
                RegionManagerView(store: regions, currentViewpoint: model.viewpoint)
            }
        }
    }

    /// In landscape the Time panel is NOT a sheet (compact-height sheets ignore
    /// detents and cover the whole screen — you couldn't see the sky you're
    /// scrubbing); it renders as a side card. Search is NEVER a sheet — it's
    /// the inline bottom panel (`searchPanel`). Everything else stays a sheet.
    private var sheetItem: Binding<ActiveSheet?> {
        Binding(
            get: {
                if activeSheet == .directory { return nil }
                return (activeSheet == .time && isChromeLandscape) ? nil : activeSheet
            },
            set: { newValue in
                // Rotating to landscape while the Time SHEET is up dismisses it
                // (the getter goes nil) and SwiftUI writes nil back — that's the
                // hand-off to the side panel, not the user closing Time. Same
                // shape for the inline search panel.
                if newValue == nil, activeSheet == .directory { return }
                if newValue == nil, activeSheet == .time, isChromeLandscape { return }
                activeSheet = newValue
            }
        )
    }

    /// Search: an inline card pinned to the bottom (the keyboard pushes it up),
    /// never a sheet — sheet detents made typing and swipe-dismiss miserable.
    @ViewBuilder private var searchPanel: some View {
        if activeSheet == .directory {
            VStack {
                // Invisible scrim: tapping anywhere above the card closes search
                // (and with it the keyboard) — the standard way out, alongside
                // the card's own swipe-down.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { activeSheet = nil }
                PeakDirectoryView(
                    model: model,
                    onPick: { peak in
                        model.select(peak)
                        activeSheet = nil
                    },
                    onClose: { activeSheet = nil }
                )
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Landscape Time controls: a trailing card over the view, so the sun/moon/
    /// stars visibly react while scrubbing.
    @ViewBuilder private var landscapeTimePanel: some View {
        if activeSheet == .time, isChromeLandscape {
            HStack {
                Spacer()
                TimeControlsView(model: model)
                    .frame(width: 400)
                    .background(Color(TopoStyle.background), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            activeSheet = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 26, height: 26)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .padding(10)
                    }
                    .padding(.trailing, 10)
                    // Vertical-only so it can never steal the slider's
                    // horizontal drags.
                    .gesture(
                        DragGesture(minimumDistance: 25).onEnded { v in
                            if v.translation.height > 40,
                               v.translation.height > abs(v.translation.width) {
                                activeSheet = nil
                            }
                        }
                    )
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
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
            // ALWAYS present (appearing-only-sometimes meant small moves under the
            // recenter threshold, or a stale fix, left no way to come home).
            // Emphasis carries the old signal: accent when tapping will move you,
            // quiet chrome when you're already standing at your position.
            stateButton(
                model.awaitingGPSFix ? "Locating…" : "Use GPS",
                systemImage: "location.fill",
                prominent: model.pendingRecenter != nil || model.isManualViewpoint,
                busy: model.awaitingGPSFix
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
            if arAdjusted || (manualAlignment && !mode.usesCamera) {
                stateButton("Realign", systemImage: "hand.draw") {
                    if arAdjusted { arRecenterToken &+= 1 }
                    manualAlignment = false
                }
            }
            if model.usesSimulatedTime {
                stateButton("Live Time", systemImage: "clock.arrow.circlepath") {
                    model.resetDisplayDateToNow()
                }
            }
        }
    }

    private func stateButton(_ title: String, systemImage: String,
                             prominent: Bool = true, busy: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(prominent ? Color(TopoStyle.accentText) : .white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(prominent ? Color(TopoStyle.accentText) : .white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(prominent ? Color(TopoStyle.accent) : Color.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
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
                // panel leaves and the card arrives in the same beat.
                if let selected = model.selectedPeak, activeSheet != .directory {
                    PeakInfoPanel(
                        peak: selected,
                        isVisible: model.visibleFeatureIDs.map { $0.contains(selected.peak.id) },
                        isWater: model.nearbyLakes.contains { $0.id == selected.peak.id },
                        isClimbed: peakLists.contains(selected.peak, in: .climbed),
                        isBookmarked: peakLists.contains(selected.peak, in: .wantToClimb),
                        onToggleClimbed: { peakLists.toggle(selected.peak, in: .climbed) },
                        onToggleBookmark: { peakLists.toggle(selected.peak, in: .wantToClimb) },
                        onVisit: { model.standOnPeak(selected) },
                        onDismiss: { model.select(nil) }
                    )
                    // Landscape: hug the content instead of spanning the whole
                    // (wide) screen; the card stays bottom-leading.
                    .fixedSize(horizontal: isChromeLandscape, vertical: false)
                    // Arrive from the bottom edge (mirroring the search panel's
                    // exit) so pick-from-search reads as one handoff motion.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    Spacer(minLength: 0)
                } else if !hideBottomChrome {
                    // Hidden while the search panel (or the landscape Time card)
                    // is up: they occupy exactly this region, and both want the
                    // terrain — not chrome — behind them.
                    footer
                    Spacer()
                    if let viewpoint = model.viewpoint {
                        MiniMapView(viewpoint: viewpoint) { activeSheet = .map }
                    }
                }
            }
        }
        .padding()
        // The rail floats above the HUD rows: inside the top row, the OPEN menu's
        // height was capped by whatever the bottom (footer/mini-map) row left over,
        // which in landscape clipped the last item mid-row. Overlapping the
        // mini-map while the menu is open beats cutting a button in half.
        .overlay(alignment: .topTrailing) { actionRail.padding() }
        // Pin the HUD to the TRUE bottom. Without this the bottom row avoids the
        // keyboard, so picking a search result made the info card appear
        // mid-screen (above the keyboard) and then drop once the keyboard left —
        // a two-step jump. Only the search panel should ride the keyboard.
        .ignoresSafeArea(.keyboard)
    }

    private var shouldShowInitialLoading: Bool {
        !model.hasRenderedOnce
    }

    /// Kills the interface-rotation animation: the terrain is counter-rotated in
    /// the SAME layout pass (TerrainContainerView.layoutSubviews), but the system's
    /// animated transition would still visibly swing it mid-flight. Disabling
    /// animations for the transition makes the whole rotation a single-frame snap —
    /// the terrain pixels never move; only the chrome jumps to its new layout.
    private struct RotationAnimationDisabler: UIViewControllerRepresentable {
        final class VC: UIViewController {
            override func viewWillTransition(to size: CGSize,
                                             with coordinator: UIViewControllerTransitionCoordinator) {
                super.viewWillTransition(to: size, with: coordinator)
                UIView.setAnimationsEnabled(false)
                coordinator.animate(alongsideTransition: nil) { _ in
                    UIView.setAnimationsEnabled(true)
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

    private var initialLoadingMessage: String {
        switch model.status {
        case .idle: return "Preparing terrain"
        case .locating: return "Finding your location"
        case let .preparingTerrain(progress):
            guard let progress else { return "Loading terrain data" }
            return "Loading terrain · \(Int(progress * 100))%"
        case let .rendering(progress):
            return "Drawing the view · \(Int(progress * 100))%"
        case .ready: return "Finalizing view"
        case .failed(let message): return message
        }
    }

    private var centeredStatus: some View {
        VStack {
            Spacer()
            statusPill
            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
    }

    // The compass + zoom readout are drawn by `CompassZoomOverlayView` inside the
    // terrain view (RidgeLine-exact), updated from the renderer each frame.

    // MARK: - Action rail

    private var actionRail: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showActionMenu.toggle()
                }
            } label: {
                Image(systemName: showActionMenu ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(menuIconColor)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showActionMenu {
                // Scrollable + height-capped so landscape's short axis can't push
                // the menu (or the ✕ above it) off screen — it scrolls instead.
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 8) {
                    // Cycle 3D → AR → Edges. Stays open so it can be cycled live.
                    controlButton(
                        "View: \(mode.title)",
                        systemName: mode.systemImage,
                        prominence: mode == .threeD ? .secondary : .primary
                    ) {
                        mode = mode.next
                    }

                    // (Recenter moved to the fixed top-left controls.)

                    // Cycle All → Sparse → Saved → None. Stays open so it can be
                    // cycled live.
                    controlButton(
                        "Labels: \(labelDensity.title)",
                        systemName: labelDensity == .none ? "tag.slash"
                            : labelDensity == .saved ? "bookmark" : "tag",
                        prominence: labelDensity == .all ? .secondary : .primary
                    ) {
                        labelDensityRaw = labelDensity.next.rawValue
                    }

                    // Photo: save the current view (camera + overlay in AR; render in 3D).
                    controlButton("Photo", systemName: "camera", prominence: .secondary) {
                        captureToken &+= 1
                        collapseActionMenu()
                    }

                    controlButton("Search", systemName: "magnifyingglass", prominence: .secondary) {
                        // Toggle: a second tap closes the inline panel.
                        activeSheet = activeSheet == .directory ? nil : .directory
                        collapseActionMenu()
                    }

                    controlButton("Lists", systemName: "checklist", prominence: .secondary) {
                        activeSheet = .lists
                        collapseActionMenu()
                    }

                    controlButton("Time", systemName: "clock",
                                  prominence: model.usesSimulatedTime ? .warning : .secondary) {
                        activeSheet = .time
                        collapseActionMenu()
                    }

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

    private var menuIconColor: Color {
        // The menu tint only flags things that live IN the menu (Recenter moved to
        // the fixed top-left controls; alignment states show there instead).
        (model.usesSimulatedTime || regions.isDownloading)
            ? .orange.opacity(0.95) : .white.opacity(0.9)
    }

    private func collapseActionMenu() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            showActionMenu = false
        }
    }

    private enum ControlProminence { case primary, secondary, warning }

    private func controlButton(
        _ title: String,
        systemName: String,
        prominence: ControlProminence,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.2)
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18)
            }
            .foregroundStyle(controlForeground(for: prominence))
            .padding(.horizontal, 4)
            .frame(height: 28)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(prominence == .warning ? Color.orange : Color.white)
                    .frame(width: prominence == .warning ? 34 : 22, height: 1)
                    .opacity(prominence == .secondary ? 0.22 : 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func controlForeground(for prominence: ControlProminence) -> Color {
        switch prominence {
        case .primary: return .white.opacity(0.96)
        case .secondary: return .white.opacity(0.82)
        case .warning: return .orange.opacity(0.95)
        }
    }

    // MARK: - Status pill + footer

    @ViewBuilder
    private var statusPill: some View {
        switch model.status {
        case .idle, .ready:
            EmptyView()
        case .locating:
            pill("Finding your location", icon: "location", isLoading: true)
        case let .preparingTerrain(progress):
            pill(progress.map { "Loading terrain · \(Int($0 * 100))%" } ?? "Loading terrain data",
                 icon: "square.grid.3x3", isLoading: true)
        case let .rendering(progress):
            pill("Drawing the view · \(Int(progress * 100))%", icon: "mountain.2", isLoading: true)
        case .failed(let message):
            pill(message, icon: "exclamationmark.triangle.fill", isLoading: false)
        }
    }

    private func pill(_ text: String, icon: String, isLoading: Bool) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
        // The width cap goes OUTSIDE the capsule: the invisible flexible frame
        // limits the text's proposal (long failure messages wrap at ~300 pt) and
        // centers the content-hugging capsule within itself. Putting a
        // maxWidth+leading frame on the Text (the old way) forced EVERY pill to
        // full width with the text hugging the left — oversized and off-center
        // for short messages like "Drawing the view".
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private var footer: some View {
        if let viewpoint = model.viewpoint, case .ready = model.status {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewpoint.name)
                        .font(.callout.weight(.semibold))
                    if let elevation = model.eyeElevationMeters {
                        Text(UnitText.elevation(meters: elevation))
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
        }
    }
}

// MARK: - Loading screen

private struct InitialLoadingScreen: View {
    let title: String
    let message: String
    /// Unified 0–1 load fraction (continuous across the terrain + render
    /// phases); nil while there's nothing to measure yet (locating, etc.).
    let progress: Double?
    let isFailed: Bool
    /// Landscape (short vertical axis): tighter spacings, smaller mark.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    @State private var glowPulse = false

    var body: some View {
        ZStack {
            // Night-sky backdrop: deep navy fading to black, with a faint warm
            // halo where the logo sun sits.
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.090, blue: 0.141),
                    Color(red: 0.016, green: 0.031, blue: 0.051),
                    Color(red: 0.008, green: 0.012, blue: 0.020),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color(TopoStyle.accent).opacity(glowPulse ? 0.16 : 0.10), .clear],
                center: UnitPoint(x: 0.5, y: isCompact ? 0.42 : 0.36),
                startRadius: 10, endRadius: 340
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: glowPulse)

            // Layered ridge silhouettes grounding the bottom of the screen.
            VStack {
                Spacer()
                LoadingRidgeline()
                    .frame(height: isCompact ? 90 : 170)
            }
            .ignoresSafeArea()

            VStack(spacing: isCompact ? 14 : 22) {
                PeakPeekLogoMark()
                    .frame(width: isCompact ? 84 : 116, height: isCompact ? 84 : 116)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: isCompact ? 28 : 36, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 300)
                        // Message changes shouldn't jump the layout.
                        .frame(minHeight: 36, alignment: .top)
                }

                if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(.white.opacity(0.08), in: Circle())
                } else {
                    LoadingProgressBar(progress: progress)
                        .frame(width: 190)
                }
            }
            .padding(.horizontal, 30)
        }
        .onAppear { glowPulse = true }
    }
}

/// Slim determinate bar; while `progress` is nil a soft segment sweeps
/// left-to-right instead (indeterminate).
private struct LoadingProgressBar: View {
    let progress: Double?
    @State private var sweep = false

    private var fillGradient: LinearGradient {
        LinearGradient(
            colors: [Color(TopoStyle.accent).opacity(0.75), Color(TopoStyle.accent)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if let p = progress {
                    Capsule()
                        .fill(fillGradient)
                        .frame(width: max(8, w * CGFloat(min(max(p, 0), 1))))
                        .animation(.easeOut(duration: 0.3), value: p)
                } else {
                    Capsule()
                        .fill(fillGradient)
                        .frame(width: w * 0.32)
                        .offset(x: sweep ? w * 0.68 : 0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                }
            }
        }
        .frame(height: 4)
        .onAppear { sweep = true }
    }
}

/// The PeakPeek badge: circular night-sky disc, warm sun, and a white
/// two-summit range over a hazed back ridge. (The app icon and website logo
/// render this same geometry.)
private struct PeakPeekLogoMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let ox = (size.width - s) / 2, oy = (size.height - s) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            let badge = Path(ellipseIn: CGRect(x: ox, y: oy, width: s, height: s))

            context.clip(to: badge)
            context.fill(
                badge,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.086, green: 0.196, blue: 0.294),
                                      Color(red: 0.031, green: 0.075, blue: 0.125)]),
                    startPoint: pt(0.5, 0), endPoint: pt(0.5, 1)))

            // Warm sun (brand accent) with a soft halo; the range overlaps it.
            let sun = pt(0.665, 0.335)
            let sunR = 0.115 * s
            context.fill(
                Path(ellipseIn: CGRect(x: sun.x - sunR * 2.6, y: sun.y - sunR * 2.6,
                                       width: sunR * 5.2, height: sunR * 5.2)),
                with: .radialGradient(
                    Gradient(colors: [Color(TopoStyle.accent).opacity(0.38),
                                      Color(TopoStyle.accent).opacity(0)]),
                    center: sun, startRadius: sunR * 0.6, endRadius: sunR * 2.6))
            context.fill(
                Path(ellipseIn: CGRect(x: sun.x - sunR, y: sun.y - sunR,
                                       width: sunR * 2, height: sunR * 2)),
                with: .color(Color(TopoStyle.accent)))

            // Hazed back ridge.
            var back = Path()
            back.move(to: pt(-0.02, 0.78))
            back.addLine(to: pt(0.28, 0.42))
            back.addQuadCurve(to: pt(0.36, 0.42), control: pt(0.32, 0.33))
            back.addLine(to: pt(0.56, 0.66))
            back.addLine(to: pt(0.74, 0.46))
            back.addQuadCurve(to: pt(0.81, 0.46), control: pt(0.775, 0.375))
            back.addLine(to: pt(1.02, 0.72))
            back.addLine(to: pt(1.02, 1.02))
            back.addLine(to: pt(-0.02, 1.02))
            back.closeSubpath()
            context.fill(back, with: .color(Color(red: 0.50, green: 0.60, blue: 0.70).opacity(0.55)))

            // Front two-summit range, softly rounded.
            var front = Path()
            front.move(to: pt(-0.02, 0.92))
            front.addLine(to: pt(0.315, 0.50))
            front.addQuadCurve(to: pt(0.415, 0.50), control: pt(0.365, 0.385))
            front.addLine(to: pt(0.545, 0.70))
            front.addLine(to: pt(0.645, 0.56))
            front.addQuadCurve(to: pt(0.725, 0.56), control: pt(0.685, 0.455))
            front.addLine(to: pt(1.02, 0.92))
            front.addLine(to: pt(1.02, 1.02))
            front.addLine(to: pt(-0.02, 1.02))
            front.closeSubpath()
            context.fill(front, with: .color(.white.opacity(0.96)))

            // Hairline ring keeps the badge crisp on dark backgrounds.
            context.stroke(
                Path(ellipseIn: CGRect(x: ox + 0.01 * s, y: oy + 0.01 * s,
                                       width: 0.98 * s, height: 0.98 * s)),
                with: .color(.white.opacity(0.14)), lineWidth: 0.018 * s)
        }
    }
}

/// Two stacked ridge silhouettes across the full width of the loading screen.
private struct LoadingRidgeline: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var back = Path()
            back.move(to: CGPoint(x: 0, y: h * 0.55))
            back.addLine(to: CGPoint(x: w * 0.18, y: h * 0.18))
            back.addLine(to: CGPoint(x: w * 0.34, y: h * 0.50))
            back.addLine(to: CGPoint(x: w * 0.52, y: h * 0.08))
            back.addLine(to: CGPoint(x: w * 0.71, y: h * 0.52))
            back.addLine(to: CGPoint(x: w * 0.86, y: h * 0.26))
            back.addLine(to: CGPoint(x: w, y: h * 0.55))
            back.addLine(to: CGPoint(x: w, y: h))
            back.addLine(to: CGPoint(x: 0, y: h))
            back.closeSubpath()
            context.fill(back, with: .color(.white.opacity(0.045)))

            var front = Path()
            front.move(to: CGPoint(x: 0, y: h * 0.82))
            front.addLine(to: CGPoint(x: w * 0.14, y: h * 0.52))
            front.addLine(to: CGPoint(x: w * 0.30, y: h * 0.78))
            front.addLine(to: CGPoint(x: w * 0.47, y: h * 0.40))
            front.addLine(to: CGPoint(x: w * 0.64, y: h * 0.80))
            front.addLine(to: CGPoint(x: w * 0.80, y: h * 0.58))
            front.addLine(to: CGPoint(x: w, y: h * 0.86))
            front.addLine(to: CGPoint(x: w, y: h))
            front.addLine(to: CGPoint(x: 0, y: h))
            front.closeSubpath()
            context.fill(front, with: .color(.white.opacity(0.075)))
        }
    }
}

