import SwiftUI

/// Searchable peak directory — a names list, sortable by elevation, distance, or
/// heading. Tapping one selects it. (Ported from RidgeLine; the offline-region
/// backfill and skyline-visibility column are omitted — mountainView keeps its
/// AW3D30 DEM and has no precomputed skyline.)
struct PeakDirectoryView: View {
    @ObservedObject var model: PanoramaViewModel
    let onPick: (Peak) -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case elevation = "Elevation"
        case distance = "Distance"
        case heading = "Heading"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var sort: Sort = .elevation
    @State private var downloadedIndex: [Peak] = []
    @State private var onlineIndex: [Peak] = []
    @State private var loadingOnline = false
    @State private var attemptedOnline = false
    @State private var searchTask: Task<Void, Never>?
    @State private var indexTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private let maxDisplayedRows = 250

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Peaks")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search peaks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if loadingOnline {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching online peaks in viewing range")
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                }
            }
            .task {
                reloadDownloadedIndex()
                startOnlineSearchIfNeeded()
            }
            .onChange(of: model.viewpoint) { _, _ in
                attemptedOnline = false
                onlineIndex = []
                reloadDownloadedIndex()
                startOnlineSearchIfNeeded()
            }
            .onChange(of: query) { _, _ in
                startOnlineSearchIfNeeded()
            }
            .onDisappear {
                searchTask?.cancel()
                indexTask?.cancel()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchLanding
        } else if rows.isEmpty {
            emptyResults
        } else {
            List {
                Section {
                    ForEach(rows) { row in
                        Button { onPick(row.peak) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.peak.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(row.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(resultHeader)
                } footer: {
                    Text("Search includes downloaded peak labels immediately. Online results are added from the possible viewing range when available.")
                }
            }
        }
    }

    private var searchLanding: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text("Search")
                    .font(.title3.weight(.semibold))
            }
            HStack(spacing: 8) {
                statusChip("\(downloadedIndex.count)", "Downloaded")
                statusChip("\(model.allNearbyPeaks.count)", "Nearby")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
            HStack(spacing: 5) {
                Text("Sort by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(sort.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.thinMaterial, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var emptyResults: some View {
        VStack(spacing: 14) {
            Image(systemName: loadingOnline ? "magnifyingglass.circle" : "questionmark.circle")
                .font(.system(size: 46, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(loadingOnline ? .orange : .secondary)
            Text(loadingOnline ? "Searching farther out" : "No matching peaks")
                .font(.headline)
            Text(loadingOnline ? "Downloaded labels are searched now. Online peaks within possible viewing distance will appear as they load." : "Try a different name, or visit the area once with a connection to cache its peaks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusChip(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        let peak: Peak
        let distanceMeters: Double?
        let bearingDeg: Double?
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

    private var rows: [Row] {
        let eye = model.viewpoint
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let filtered = mergedSearchIndex.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        let mapped = filtered.map { peak -> Row in
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
            return Row(peak: peak, distanceMeters: distance, bearingDeg: bearing)
        }
        switch sort {
        case .elevation: return Array(mapped.sorted { $0.peak.elevationMeters > $1.peak.elevationMeters }.prefix(maxDisplayedRows))
        case .distance: return Array(mapped.sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }.prefix(maxDisplayedRows))
        case .heading: return Array(mapped.sorted { ($0.bearingDeg ?? 0) < ($1.bearingDeg ?? 0) }.prefix(maxDisplayedRows))
        }
    }

    private var resultHeader: String {
        let count = rows.count
        let suffix = count == maxDisplayedRows ? "+" : ""
        return "\(count)\(suffix) result\(count == 1 ? "" : "s")"
    }

    private var mergedSearchIndex: [Peak] {
        Self.mergePeaks(model.allNearbyPeaks + downloadedIndex + onlineIndex)
    }

    private func reloadDownloadedIndex() {
        indexTask?.cancel()
        indexTask = Task {
            let peaks = await Task.detached(priority: .utility) {
                let packPeaks = PeakPackService.allCachedPeaks()
                let osmPeaks = OSMPeakService.allCachedPeaks()
                return Self.mergePeaks(packPeaks + osmPeaks)
            }.value
            guard !Task.isCancelled else { return }
            downloadedIndex = peaks
        }
    }

    private func startOnlineSearchIfNeeded() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2,
              !attemptedOnline,
              !loadingOnline,
              let viewpoint = model.viewpoint,
              !ProcessInfo.processInfo.arguments.contains("-noNetwork")
        else { return }

        attemptedOnline = true
        loadingOnline = true
        searchTask?.cancel()
        searchTask = Task {
            do {
                let packPeaks = await PeakPackService.downloadRegion(
                    latitude: viewpoint.latitude,
                    longitude: viewpoint.longitude,
                    radiusKm: PeakSearch.maxRangeMeters / 1000
                )
                let osmPeaks = try await OSMPeakService.peaksTiled(
                    aroundLatitude: viewpoint.latitude,
                    longitude: viewpoint.longitude,
                    radiusKm: PeakSearch.maxRangeMeters / 1000
                )
                let merged = await Task.detached(priority: .utility) {
                    Self.mergePeaks(packPeaks + osmPeaks)
                }.value
                await MainActor.run {
                    onlineIndex = merged
                    downloadedIndex = Self.mergePeaks(downloadedIndex + merged)
                    loadingOnline = false
                    model.reloadNearbyPeaks()
                }
            } catch {
                await MainActor.run { loadingOnline = false }
            }
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
