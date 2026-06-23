import SwiftUI

/// The app's single-screen experience: mountainView's live raymarched panorama
/// front and center, a quiet status pill while terrain loads, a viewpoint footer,
/// and a corner map that opens the teleport picker. (HUD ported from RidgeLine's
/// RootScreen; the central canvas is mountainView's live Metal view, and the
/// peak/sky/AR chrome is added in later phases.)
struct RootScreen: View {
    @StateObject private var model = PanoramaViewModel()
    @StateObject private var peakLists = PeakListStore()
    @State private var showMap = false
    @State private var showActionMenu = false
    @State private var showDirectory = false
    @State private var showLists = false
    @State private var mode: TerrainViewMode = .threeD
    @State private var manualAlignment = false

    var body: some View {
        ZStack {
            TerrainMetalView(
                viewpoint: model.viewpoint,
                exaggeration: model.terrainExaggeration,
                mode: mode,
                manualAlignment: manualAlignment,
                peaks: model.allNearbyPeaks,
                selectedPeakID: model.selectedPeak?.peak.id,
                onSelectPeak: { model.select($0) },
                onStatus: { model.renderStatusChanged($0) },
                onEyeElevation: { model.eyeElevationResolved($0) },
                onHeading: { model.headingResolved($0) },
                onZoom: { model.zoomResolved($0) },
                onForceManual: { manualAlignment = true }
            )
            .ignoresSafeArea()
            .background(.black)

            if shouldShowInitialLoading {
                InitialLoadingScreen(
                    title: initialLoadingTitle,
                    message: initialLoadingMessage,
                    isFailed: initialLoadingFailed
                )
                .transition(.opacity)
                .zIndex(2)
            } else {
                hud
                centeredStatus
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowInitialLoading)
        .statusBarHidden()
        .onAppear {
            model.start()
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-arEdges") { mode = .arEdges }
            else if args.contains("-arRelief") { mode = .arRelief }
            if args.contains("-manual") { manualAlignment = true }
            // Debug: auto-select a peak (the simulator can't synthesize a tap) to
            // exercise the detail panel.
            if args.contains("-selectTopPeak") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    if let top = model.allNearbyPeaks.max(by: { $0.priority < $1.priority }) {
                        model.select(top)
                    }
                }
            }
        }
        .sheet(isPresented: $showMap) {
            TeleportMapView(currentViewpoint: model.viewpoint) { viewpoint in
                model.teleport(to: viewpoint, manual: true)
            }
        }
        .sheet(isPresented: $showDirectory) {
            PeakDirectoryView(model: model) { peak in
                model.select(peak)
                showDirectory = false
            }
        }
        .sheet(isPresented: $showLists) {
            PeakListsView(store: peakLists, viewpoint: model.viewpoint) { peak in
                model.select(peak)
            }
        }
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                actionRail
            }
            Spacer()
            HStack(alignment: .bottom) {
                if let selected = model.selectedPeak {
                    PeakInfoPanel(
                        peak: selected,
                        isClimbed: peakLists.contains(selected.peak, in: .climbed),
                        isBookmarked: peakLists.contains(selected.peak, in: .wantToClimb),
                        onToggleClimbed: { peakLists.toggle(selected.peak, in: .climbed) },
                        onToggleBookmark: { peakLists.toggle(selected.peak, in: .wantToClimb) },
                        onVisit: { model.standOnPeak(selected) },
                        onDismiss: { model.select(nil) }
                    )
                } else {
                    footer
                    Spacer()
                    if let viewpoint = model.viewpoint {
                        MiniMapView(viewpoint: viewpoint) { showMap = true }
                    }
                }
            }
        }
        .padding()
    }

    private var shouldShowInitialLoading: Bool {
        !model.hasRenderedOnce
    }

    private var initialLoadingFailed: Bool {
        if case .failed = model.status { return true }
        return false
    }

    private var initialLoadingTitle: String {
        initialLoadingFailed ? "Terrain unavailable" : "mountainView"
    }

    private var initialLoadingMessage: String {
        switch model.status {
        case .idle: return "Preparing terrain"
        case .locating: return "Finding your location"
        case .preparingTerrain: return "Loading terrain data"
        case .rendering: return "Drawing the view"
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
                VStack(alignment: .trailing, spacing: 8) {
                    // Cycle 3D → AR → Edges. Stays open so it can be cycled live.
                    controlButton(
                        "View: \(mode.title)",
                        systemName: mode.systemImage,
                        prominence: mode == .threeD ? .secondary : .primary
                    ) {
                        mode = mode.next
                    }

                    // Device heading vs. manual drag look-around.
                    controlButton(
                        manualAlignment ? "Manual" : "Aligned",
                        systemName: manualAlignment ? "hand.draw" : "location.north.line.fill",
                        prominence: manualAlignment ? .warning : .secondary
                    ) {
                        manualAlignment.toggle()
                    }

                    controlButton("Peaks", systemName: "magnifyingglass", prominence: .secondary) {
                        showDirectory = true
                        collapseActionMenu()
                    }

                    controlButton("Lists", systemName: "checklist", prominence: .secondary) {
                        showLists = true
                        collapseActionMenu()
                    }

                    // Stays open so the factor can be cycled and watched live.
                    controlButton(
                        exaggerationTitle,
                        systemName: "arrow.up.and.down",
                        prominence: model.terrainExaggeration > 1.001 ? .primary : .secondary
                    ) {
                        model.cycleTerrainExaggeration()
                    }

                    // The way home after a map drop or a peak visit.
                    if model.isManualViewpoint {
                        controlButton("Use GPS", systemName: "location.fill", prominence: .warning) {
                            model.followGPS()
                            collapseActionMenu()
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// "Relief 1×" / "Relief 1.5×" / "Relief 2×" — trims the trailing ".0".
    private var exaggerationTitle: String {
        let factor = model.terrainExaggeration
        let value = factor.rounded() == factor
            ? String(Int(factor))
            : String(format: "%.1f", factor)
        return "Relief \(value)×"
    }

    private var menuIconColor: Color {
        (model.isManualViewpoint || manualAlignment) ? .orange.opacity(0.95) : .white.opacity(0.9)
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
        case .preparingTerrain:
            pill("Loading terrain data", icon: "square.grid.3x3", isLoading: true)
        case .rendering:
            pill("Drawing the view", icon: "mountain.2", isLoading: true)
        case .failed(let message):
            pill(message, icon: "exclamationmark.triangle.fill", isLoading: false)
        }
    }

    private func pill(_ text: String, icon: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: icon).font(.caption.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.58), in: Capsule())
        .frame(maxWidth: 250, alignment: .leading)
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

// MARK: - Loading screen (ported from RidgeLine)

private struct InitialLoadingScreen: View {
    let title: String
    let message: String
    let isFailed: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.045, green: 0.052, blue: 0.064),
                    Color(red: 0.010, green: 0.012, blue: 0.018),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color.cyan.opacity(0.20), Color.orange.opacity(0.08), .clear],
                center: .topTrailing, startRadius: 40, endRadius: 520
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                LoadingTerrainMark(isFailed: isFailed)
                    .frame(width: 122, height: 86)

                VStack(spacing: 9) {
                    Text(title)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 280)
                }

                if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(.white.opacity(0.08), in: Circle())
                } else {
                    ProgressView()
                        .tint(.cyan)
                        .controlSize(.regular)
                        .padding(12)
                        .background(.white.opacity(0.075), in: Circle())
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 34)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.black.opacity(0.30))
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .padding(28)
        }
    }
}

private struct LoadingTerrainMark: View {
    let isFailed: Bool

    var body: some View {
        Canvas { context, size in
            let ridge = Path { path in
                path.move(to: CGPoint(x: size.width * 0.05, y: size.height * 0.70))
                path.addCurve(
                    to: CGPoint(x: size.width * 0.34, y: size.height * 0.44),
                    control1: CGPoint(x: size.width * 0.16, y: size.height * 0.68),
                    control2: CGPoint(x: size.width * 0.23, y: size.height * 0.38)
                )
                path.addCurve(
                    to: CGPoint(x: size.width * 0.58, y: size.height * 0.34),
                    control1: CGPoint(x: size.width * 0.43, y: size.height * 0.51),
                    control2: CGPoint(x: size.width * 0.47, y: size.height * 0.32)
                )
                path.addCurve(
                    to: CGPoint(x: size.width * 0.94, y: size.height * 0.60),
                    control1: CGPoint(x: size.width * 0.72, y: size.height * 0.38),
                    control2: CGPoint(x: size.width * 0.77, y: size.height * 0.62)
                )
            }

            context.stroke(
                ridge,
                with: .color(isFailed ? .orange : .white.opacity(0.92)),
                style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
            )

            for index in 0..<5 {
                let offset = CGFloat(index + 1) * size.height * 0.075
                context.translateBy(x: 0, y: offset)
                context.stroke(
                    ridge,
                    with: .color(.white.opacity(0.08 - Double(index) * 0.01)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )
                context.translateBy(x: 0, y: -offset)
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: size.width * 0.58 - 4, y: size.height * 0.34 - 4, width: 8, height: 8
                )),
                with: .color(isFailed ? .orange : .cyan)
            )
        }
    }
}

