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
    let onPick: (Peak) -> Void
    let onClose: () -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case elevation = "Elevation"
        case distance = "Distance"
        case heading = "Heading"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var sort: Sort = .distance     // near-first by default
    /// Everything searchable offline: nearby peaks + every downloaded pack/OSM
    /// peak, deduped ONCE off-main. Per-keystroke work is a flat scan of this.
    @State private var baseIndex: [Peak] = []
    /// Whole-world name matches from the bundled DB (instant, offline).
    @State private var globalIndex: [Peak] = []
    /// Displayed results. Computed OFF the main thread (filter + dedup + sort of
    /// a ~100k index blocked typing when it ran in a computed property per
    /// keystroke); each recompute cancels the previous one.
    @State private var rows: [Row] = []
    /// A rows recompute is in flight — suppresses the "no matches" empty state.
    @State private var searchPending = false
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
            resultsArea
            inputBar
        }
        .background(Color(TopoStyle.background), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 500)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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
            searchFocused = true                   // straight to typing
            // Debug: pre-fill the query (the simulator can't type).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-searchQuery"), i + 1 < args.count {
                query = args[i + 1]
            }
        }
        .onChange(of: model.viewpoint) { _, _ in
            reloadDownloadedIndex()
        }
        .onChange(of: query) { _, _ in
            searchGlobal()
            recomputeRows()
        }
        .onChange(of: sort) { _, _ in
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
            .fill(.white.opacity(0.28))
            .frame(width: 36, height: 4.5)
            .padding(.top, 8)
            .padding(.bottom, 1)
    }

    /// Everything above the search field, sized to content: nothing while the
    /// query is empty (the card is just the field), a short message when nothing
    /// matches, up to four rows otherwise (two in landscape) — rest scrolls.
    @ViewBuilder
    private var resultsArea: some View {
        if trimmedQuery.isEmpty || (rows.isEmpty && searchPending) {
            EmptyView()
        } else if rows.isEmpty {
            VStack(spacing: 3) {
                Text("No matches")
                    .font(.subheadline.weight(.semibold))
                Text("Every named peak worldwide is searched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { onPick(row.peak) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.peak.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !row.subtitle.isEmpty {
                                        Text(row.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                            }
                            // Fixed row height: the results detent shows exactly
                            // four of these (56×4 + hairlines + bar = 304).
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 6)
            }
            .frame(height: resultsHeight)
        }
    }

    /// Content-sized results window: exactly as many 56 pt rows as there are,
    /// capped at four (two in landscape, where the keyboard owns the height);
    /// anything past the cap scrolls.
    private var resultsHeight: CGFloat {
        let cap = verticalSizeClass == .compact ? 2 : 4
        return CGFloat(min(rows.count, cap)) * 56 + 8
    }

    /// Bottom search bar: field + clear + sort, one thumb-height row, styled as
    /// a Time-sheet card (white-6% fill, 12 pt corners). Dismissal is the
    /// standard sheet swipe-down, like Time — no close button.
    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search peaks", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            sortMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
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
                .foregroundStyle(.secondary)
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
        guard !needle.isEmpty else { rows = []; searchPending = false; return }
        searchPending = true
        // Base first (dedup keeps the first occurrence), so local results win ties
        // against the whole-world matches.
        let base = baseIndex, global = globalIndex
        let eye = model.viewpoint, sort = sort, cap = maxDisplayedRows
        rowsTask = Task {
            let computed = await Task.detached(priority: .userInitiated) { () -> [Row] in
                let localHits = base.filter { $0.name.localizedCaseInsensitiveContains(needle) }
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
                let mapped = merged.map { peak -> Row in
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
                    return Row(peak: peak, distanceMeters: distance, bearingDeg: bearing,
                               rank: rank(of: peak.name))
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
            searchPending = false
        }
    }

    private func reloadDownloadedIndex() {
        indexTask?.cancel()
        let nearby = model.allNearbyPeaks
        indexTask = Task {
            let peaks = await Task.detached(priority: .utility) {
                let packPeaks = PeakPackService.allCachedPeaks()
                let osmPeaks = OSMPeakService.allCachedPeaks()
                return Self.mergePeaks(nearby + packPeaks + osmPeaks)
            }.value
            guard !Task.isCancelled else { return }
            baseIndex = peaks
            recomputeRows()
        }
    }

    /// Instant whole-world search against the bundled database (no network) —
    /// a raw byte scan of ~1.5M names, debounced per keystroke.
    private func searchGlobal() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard needle.count >= 2 else { globalIndex = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))       // debounce typing
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                GlobalPeakDatabase.shared?.search(nameContains: needle) ?? []
            }.value
            guard !Task.isCancelled else { return }
            globalIndex = hits
            recomputeRows()
        }
    }

    nonisolated private static func mergePeaks(_ peaks: [Peak]) -> [Peak] {
        var merged: [Peak] = []
        var ids = Set<String>()
        var buckets: [String: [Peak]] = [:]

        func bucketKey(_ peak: Peak) -> String {
            let lat = Int((peak.latitude * 200).rounded())
            let lon = Int((peak.longitude * 200).rounded())
            return "\(lat):\(lon)"
        }

        for peak in peaks {
            guard ids.insert(peak.id).inserted else { continue }
            let key = bucketKey(peak)
            let duplicate = buckets[key]?.contains(where: {
                guard $0.name.localizedCaseInsensitiveCompare(peak.name) == .orderedSame else { return false }
                return GeoMath.distanceMeters(
                    fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                    toLatitude: peak.latitude, toLongitude: peak.longitude
                ) < 200
            }) ?? false
            guard !duplicate else { continue }
            merged.append(peak)
            buckets[key, default: []].append(peak)
        }
        return merged
    }
}
