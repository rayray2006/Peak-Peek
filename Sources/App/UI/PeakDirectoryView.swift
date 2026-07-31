import SwiftUI

/// Searchable peak directory — an INLINE bottom panel over the terrain, not a
/// sheet. (The sheet version was hostile in practice: its detents fought the
/// keyboard, which balloons a sheet to its largest detent, and swipe-dismiss
/// stopped at every detent on the way down.) One Time-style card: up to four
/// result rows above the search field, best match on top, rest scrolling. The
/// keyboard simply pushes the card up; one swipe down anywhere on the card
/// (grabber, field, message — the rows scroll) closes it in a single gesture.
struct PeakDirectoryView: View {
    @ObservedObject var model: PanoramaViewModel
    /// Owned by RootScreen so the query survives the panel closing — picking a
    /// result opens the peak card, and closing THAT returns here with the
    /// search exactly as it was left.
    @Binding var query: String
    /// The user's Saved/Completed entries — included in the search index so
    /// custom saved locations (not in any peak database) are findable by name.
    let savedPeaks: [Peak]
    /// Vertical space actually available to the card (the hosting container's
    /// height, which the keyboard already shrinks). Caps how many result rows
    /// show: the fixed 4/2-row caps overflowed small screens in landscape,
    /// pushing the card's top rows off-screen while the keyboard was up.
    let availableHeight: CGFloat
    let onPick: (Peak) -> Void
    let onClose: () -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case elevation = "Elevation"
        case distance = "Distance"
        case heading = "Heading"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .distance     // near-first by default
    /// Everything searchable offline: nearby peaks + lakes + every downloaded
    /// pack/OSM peak, deduped ONCE off-main. Per-keystroke work is a flat scan.
    @State private var baseIndex: [Peak] = []
    /// Whole-world name matches from the bundled DBs (instant, offline).
    @State private var globalIndex: [Peak] = []
    /// Which indexed features are WATER (nearby lakes + global lake DB hits) —
    /// drives the honest visibility verdict per row.
    @State private var baseWaterIDs: Set<String> = []
    @State private var globalWaterIDs: Set<String> = []
    /// Displayed results. Computed OFF the main thread (filter + dedup + sort of
    /// a ~100k index blocked typing when it ran in a computed property per
    /// keystroke); each recompute cancels the previous one.
    @State private var rows: [Row] = []

    /// The last computed results, kept across panel instances (main-thread
    /// only, like all of SwiftUI). Reopening with the restored query seeds
    /// `rows` in the FIRST body pass, so the card arrives at full height in
    /// one motion instead of opening as a bare field and then expanding when
    /// the async recompute lands.
    private static var lastSession: (query: String, sort: Sort, rows: [Row],
                                     globalIndex: [Peak], globalWaterIDs: Set<String>)?

    init(model: PanoramaViewModel, query: Binding<String>, savedPeaks: [Peak],
         availableHeight: CGFloat,
         onPick: @escaping (Peak) -> Void, onClose: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._query = query
        self.savedPeaks = savedPeaks
        self.availableHeight = availableHeight
        self.onPick = onPick
        self.onClose = onClose
        let trimmed = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let cached = Self.lastSession, cached.query == trimmed {
            _rows = State(initialValue: cached.rows)
            _sort = State(initialValue: cached.sort)
            // The global DB hits too: the first index-load recompute then merges
            // against them and reproduces the same rows, instead of briefly
            // dropping the whole-world matches until searchGlobal's debounce lands.
            _globalIndex = State(initialValue: cached.globalIndex)
            _globalWaterIDs = State(initialValue: cached.globalWaterIDs)
        }
    }
    @State private var searchTask: Task<Void, Never>?
    @State private var indexTask: Task<Void, Never>?
    @State private var rowsTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    /// Live swipe-to-dismiss displacement; the card tracks the finger.
    @State private var dragOffset: CGFloat = 0
    /// Landscape shows fewer rows — the keyboard owns most of the short axis.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let maxDisplayedRows = 250

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            titleRow
            inputBar
            resultsArea
        }
        .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
        .frame(maxWidth: 500)
        .padding(.horizontal, 16)   // 12 read cramped on narrow phones
        .padding(.bottom, 8)
        // Interactive swipe-down: the card FOLLOWS the finger (upward pulls
        // rubber-band like a sheet), then commits past a distance/velocity
        // threshold or springs back. The results scroll view consumes its own
        // drags, so this fires on the grabber, field, and empty areas.
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    let h = v.translation.height
                    dragOffset = h >= 0 ? h : -18 * (1 - 1 / (1 - h / 60))
                }
                .onEnded { v in
                    if v.translation.height > 90 || v.predictedEndTranslation.height > 220 {
                        searchFocused = false
                        onClose()          // exit transition continues from here
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear { dragOffset = 0 }   // in case a dismissed card's offset survives
        .task {
            reloadDownloadedIndex()
            // Debug: pre-fill the query (the simulator can't type).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-searchQuery"), i + 1 < args.count {
                query = args[i + 1]
            }
            // A RESTORED query (reopening after the peak card closes) arrives
            // with the view, so onChange(of: query) never fires — search it now.
            // No eager recomputeRows here: the indexes are still loading, so it
            // would find nothing and wipe the seeded rows (the card visibly
            // collapsed and re-expanded). reloadDownloadedIndex and searchGlobal
            // each recompute when their data lands.
            if !trimmedQuery.isEmpty {
                searchGlobal()
            }
            // Focus AFTER the card's entrance settles: focusing in the same
            // beat stacked the keyboard's system animation — and its infamous
            // first-use warm-up stall — on the panel transition, freezing and
            // jittering the whole screen. The card now lands instantly; the
            // keyboard follows a beat later.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onChange(of: model.viewpoint) { old, new in
            // The index merges ~100k cached peaks; while GPS-following every
            // small fix change republishes the viewpoint, so gate the rebuild
            // on a move that could actually change the nearby set.
            guard let old, let new else { reloadDownloadedIndex(); return }
            let moved = GeoMath.distanceMeters(
                fromLatitude: old.latitude, fromLongitude: old.longitude,
                toLatitude: new.latitude, toLongitude: new.longitude)
            if moved > 500 { reloadDownloadedIndex() }
        }
        .onChange(of: query) { _, _ in
            searchGlobal()
            recomputeRows()
        }
        .onChange(of: sort) { _, _ in
            recomputeRows()
        }
        // The occlusion pass lands a beat after the render — refresh the
        // visibility badges when its verdict set arrives or changes.
        .onChange(of: model.visibleFeatureIDs) { _, _ in
            recomputeRows()
        }
        .onDisappear {
            searchTask?.cancel()
            indexTask?.cancel()
            rowsTask?.cancel()
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(TopoStyle.hairline(0.15))
            .frame(width: 36, height: 4)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    /// The template's sheet header: "Search" + quiet ✕.
    private var titleRow: some View {
        HStack {
            Text("Search")
                .font(PPFont.ui(16, .semibold))
                .foregroundStyle(TopoStyle.inkColor)
            Spacer()
            Button {
                searchFocused = false
                onClose()
            } label: {
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

    /// Everything above the search field, sized to content: nothing while the
    /// query is empty (the card is just the field), a short message when nothing
    /// matches, up to four rows otherwise (two in landscape) — rest scrolls.
    @ViewBuilder
    private var resultsArea: some View {
        if trimmedQuery.isEmpty {
            EmptyView()
        } else if rows.isEmpty {
            // (No "Searching…" spinner: the local-index searches resolve in
            // milliseconds, so the spinner only ever FLASHED before this block
            // replaced it — reading as flicker, not progress.)
            VStack(spacing: 5) {
                Text("No matches")
                    .font(PPFont.ui(15, .semibold))
                    .foregroundStyle(TopoStyle.inkColor)
            }
            .padding(.top, 2)
            .padding(.bottom, 20)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { onPick(row.peak) } label: {
                            // Template row: name over the sightline badge on
                            // the left, the mono facts on the right.
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.peak.displayName)
                                        .font(PPFont.ui(15, .medium))
                                        .foregroundStyle(TopoStyle.inkColor)
                                        .lineLimit(1)
                                    if let visible = row.isVisible {
                                        PPVisibilityBadge(visible: visible)
                                    }
                                }
                                Spacer(minLength: 12)
                                if !row.subtitle.isEmpty {
                                    Text(row.subtitle)
                                        .font(PPFont.mono(11))
                                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                            // Fixed row height (template rows are 52 pt); the
                            // results window shows up to four.
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id {
                            Divider().overlay(TopoStyle.hairline(0.08))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
            }
            .frame(height: resultsHeight)
            .padding(.bottom, 10)
        }
    }

    /// Content-sized results window: exactly as many 52 pt rows as there are,
    /// capped at four (fewer when the space above the keyboard can't fit them —
    /// small phones in landscape fit just one); anything past the cap scrolls.
    private var resultsHeight: CGFloat {
        let cap = verticalSizeClass == .compact ? 2 : 4
        // Chrome around the rows: grabber + title + field + card paddings, plus
        // a little clearance so the card never kisses the screen edge.
        let chrome: CGFloat = 170
        let fitting = max(1, Int((availableHeight - chrome) / 52))
        return CGFloat(min(rows.count, min(cap, fitting))) * 52 + 6
    }

    /// Bottom search bar: field + clear + sort, one thumb-height row, styled as
    /// a Time-sheet card (white-6% fill, 12 pt corners). Dismissal is the
    /// standard sheet swipe-down, like Time — no close button.
    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.65))
            TextField("Search", text: $query)
                .font(PPFont.ui(15))
                .foregroundStyle(TopoStyle.inkColor)
                .tint(TopoStyle.inkColor)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            sortMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Sort control: plain glyph, no circle — the circled ✕ next to it is the
    /// sheet's close button, and two identical gray discs (plus the in-field
    /// clear) read as three interchangeable buttons.
    private var sortMenu: some View {
        Menu {
            ForEach(Sort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    if sort == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.65))
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        let peak: Peak
        let distanceMeters: Double?
        let bearingDeg: Double?
        /// Match relevance: 0 = the name starts with the query, 1 = a word in it
        /// does, 2 = mid-word substring ("Ja[lake]"). Primary sort key — mid-word
        /// noise stays below real matches whatever the chosen sort.
        let rank: Int
        /// Renderer's sightline verdict from the current viewpoint; nil = never
        /// judged (out of range / no pass yet) — no badge, not a false "Hidden".
        let isVisible: Bool?
        var id: String { peak.id }
        var subtitle: String {
            var parts: [String] = []
            if peak.elevationMeters > 0 {
                parts.append(UnitText.elevation(meters: peak.elevationMeters))
            }
            if let d = distanceMeters {
                parts.append(UnitText.distance(meters: d))
            }
            return parts.joined(separator: "  ·  ")
        }
    }

    /// Recompute the displayed rows off-main: filter the base index by the query,
    /// fold in the global DB hits, dedup the (small) combined match set, resolve
    /// distance/bearing against the eye, sort, cap. Cancels any in-flight
    /// recompute — only the newest keystroke's result lands.
    private func recomputeRows() {
        rowsTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            rows = []
            return
        }
        // Base first (dedup keeps the first occurrence), so local results win ties
        // against the whole-world matches.
        let base = baseIndex, global = globalIndex, globalWater = globalWaterIDs
        let eye = model.viewpoint, sort = sort, cap = maxDisplayedRows
        // Loaded DEM tiles: fill in missing catalog elevations (OSM peaks
        // without an `ele` tag) by sampling the terrain at the coordinate.
        let demNear = model.demNear, demFar = model.demFar
        // Visibility badge inputs, snapshotted on main: the renderer's verdict
        // set plus the candidate lists that were actually judged.
        let visibleIDs = model.visibleFeatureIDs
        let candidatePeaks = model.allNearbyPeaks
        let candidateLakes = model.nearbyLakes
        let waterIDs = baseWaterIDs.union(globalWaterIDs)
        rowsTask = Task {
            let computed = await Task.detached(priority: .userInitiated) { () -> [Row] in
                let candidateIDs = Set(candidatePeaks.map(\.id))
                    .union(candidateLakes.map(\.id))
                // Match against displayName, not the raw name: non-Latin names
                // carry their transliteration there ("富士山 (Fu Shi Shan)"),
                // so the Latin spelling finds them too. Latin names hit
                // displayName's quick-reject and cost the same as before.
                let localHits = base.filter { $0.displayName.localizedCaseInsensitiveContains(needle) }
                let merged = Self.mergePeaks(localHits + global)
                // Relevance: a match at the start of the name or a word beats a
                // mid-word hit ("Lake Serene" over "Condor Ja[lake] Loma"),
                // whatever the chosen sort.
                let needleLower = needle.lowercased()
                func rank(of name: String) -> Int {
                    let l = name.lowercased()
                    guard let r = l.range(of: needleLower) else { return 3 }
                    if r.lowerBound == l.startIndex { return 0 }
                    let prev = l[l.index(before: r.lowerBound)]
                    return (prev.isLetter || prev.isNumber) ? 2 : 1
                }
                // Catalog elevation 0 = "unknown": substitute the DEM height at
                // the coordinate wherever the loaded tiles cover it — the same
                // rule the label anchors use. The filled peak flows onward
                // (row subtitle, sorts, verdict, and the card via onPick).
                func filled(_ p: Peak) -> Peak {
                    guard p.elevationMeters <= 0 else { return p }
                    let tile: DEMTile? = (demNear?.contains(lat: p.latitude, lon: p.longitude) ?? false)
                        ? demNear
                        : (demFar?.contains(lat: p.latitude, lon: p.longitude) ?? false) ? demFar : nil
                    guard let tile else { return p }
                    let elev = Double(tile.elevation(lat: p.latitude, lon: p.longitude))
                    guard elev > 0 else { return p }
                    return Peak(id: p.id, name: p.name,
                                latitude: p.latitude, longitude: p.longitude,
                                elevationMeters: elev, prominenceMeters: p.prominenceMeters,
                                isSaddle: p.isSaddle)
                }
                let mapped = merged.map(filled).map { peak -> Row in
                    let distance = eye.map {
                        GeoMath.distanceMeters(
                            fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                            toLatitude: peak.latitude, toLongitude: peak.longitude)
                    }
                    let bearing = eye.map {
                        GeoMath.bearingRad(
                            fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                            toLatitude: peak.latitude, toLongitude: peak.longitude) * 180 / .pi
                    }
                    let visible: Bool? = if let visibleIDs, let distance {
                        PanoramaViewModel.visibilityVerdict(
                            peakID: peak.id, isSaddle: peak.isSaddle,
                            elevationMeters: peak.elevationMeters,
                            prominenceMeters: peak.prominenceMeters,
                            isWater: waterIDs.contains(peak.id),
                            distanceMeters: distance, visibleIDs: visibleIDs,
                            isCandidate: candidateIDs.contains(peak.id))
                    } else { nil }
                    return Row(peak: peak, distanceMeters: distance, bearingDeg: bearing,
                               rank: rank(of: peak.displayName), isVisible: visible)
                }
                switch sort {
                case .elevation: return Array(mapped.sorted {
                    ($0.rank, -$0.peak.elevationMeters) < ($1.rank, -$1.peak.elevationMeters) }.prefix(cap))
                case .distance: return Array(mapped.sorted {
                    ($0.rank, $0.distanceMeters ?? .infinity) < ($1.rank, $1.distanceMeters ?? .infinity) }.prefix(cap))
                case .heading: return Array(mapped.sorted {
                    ($0.rank, $0.bearingDeg ?? 0) < ($1.rank, $1.bearingDeg ?? 0) }.prefix(cap))
                }
            }.value
            guard !Task.isCancelled else { return }
            rows = computed
            // Seed for the next open: reopening with this query renders these
            // rows synchronously (see init).
            Self.lastSession = (needle, sort, computed, global, globalWater)
        }
    }

    private func reloadDownloadedIndex() {
        indexTask?.cancel()
        // Saved entries first: dedup keeps the first occurrence, so a saved
        // location's user-given name wins over a database twin at the same spot.
        let saved = savedPeaks
        let nearby = model.allNearbyPeaks
        let lakes = model.nearbyLakes
        indexTask = Task {
            let peaks = await Task.detached(priority: .utility) {
                let packPeaks = PeakPackService.allCachedPeaks()
                let osmPeaks = OSMPeakService.allCachedPeaks()
                return Self.mergePeaks(saved + nearby + lakes + packPeaks + osmPeaks)
            }.value
            guard !Task.isCancelled else { return }
            baseIndex = peaks
            baseWaterIDs = Set(lakes.map(\.id))
            recomputeRows()
        }
    }

    /// Instant whole-world search against the bundled databases (no network) —
    /// raw byte scans of ~1.5M peak names + the lake DB, debounced per keystroke.
    private func searchGlobal() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard needle.count >= 2 else { globalIndex = []; globalWaterIDs = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))       // debounce typing
            guard !Task.isCancelled else { return }
            let (peakHits, lakeHits) = await Task.detached(priority: .userInitiated) {
                (GlobalPeakDatabase.shared?.search(nameContains: needle) ?? [],
                 GlobalPeakDatabase.lakes?.search(nameContains: needle) ?? [])
            }.value
            guard !Task.isCancelled else { return }
            globalIndex = peakHits + lakeHits
            globalWaterIDs = Set(lakeHits.map(\.id))
            recomputeRows()
        }
    }

    nonisolated private static func mergePeaks(_ peaks: [Peak]) -> [Peak] {
        Peak.dedupedKeepingFirst(peaks)   // one shared implementation
    }
}
