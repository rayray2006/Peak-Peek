import SwiftUI

/// Saved "Climbed" / "Bookmarks" lists. Tap a peak to select it. (Ported from
/// RidgeLine.)
struct PeakListsView: View {
    @ObservedObject var store: PeakListStore
    let viewpoint: PanoramaViewModel.Viewpoint?
    let onPick: (Peak) -> Void

    @State private var selection: PeakListKind = .wantToClimb
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $selection) {
                        ForEach(PeakListKind.allCases) { kind in
                            Text("\(kind.title) \(store.count(in: kind))").tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    .listRowBackground(Color.clear)
                }

                if rows.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(rows) { row in
                            Button {
                                onPick(row.saved.peak)
                                dismiss()
                            } label: {
                                PeakListRow(row: row, kind: selection)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.remove(row.saved.peak, from: selection)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(selection.title)
                    } footer: {
                        Text("Tap a peak to select it. Peaks stay saved offline because mountainView stores the peak snapshot when you add it.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Peak Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var rows: [PeakListRowModel] {
        store.peaks(in: selection).map { saved in
            PeakListRowModel(
                saved: saved,
                distanceMeters: viewpoint.map {
                    GeoMath.distanceMeters(
                        fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                        toLatitude: saved.peak.latitude, toLongitude: saved.peak.longitude
                    )
                },
                bearingDeg: viewpoint.map {
                    GeoMath.bearingRad(
                        fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                        toLatitude: saved.peak.latitude, toLongitude: saved.peak.longitude
                    ) * 180 / .pi
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selection.systemImage)
                .font(.system(size: 42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selection == .climbed ? .green : .orange)
            Text("No peaks yet")
                .font(.headline)
            Text("Open Peaks, select a summit, then add it to \(selection.title.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct PeakListRowModel: Identifiable {
    let saved: SavedPeak
    let distanceMeters: Double?
    let bearingDeg: Double?

    var id: String { saved.id }
}

private struct PeakListRow: View {
    let row: PeakListRowModel
    let kind: PeakListKind

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.headline)
                .foregroundStyle(kind == .climbed ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.saved.peak.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if row.saved.peak.elevationMeters > 0 {
            parts.append(UnitText.elevation(meters: row.saved.peak.elevationMeters))
        }
        if let distanceMeters = row.distanceMeters {
            parts.append(UnitText.distance(meters: distanceMeters))
        }
        if let bearingDeg = row.bearingDeg {
            parts.append(compassText(bearingDeg))
        }
        if let date = row.saved.date(for: kind) {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func compassText(_ bearing: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int((bearing / 45).rounded()) % 8
        return dirs[idx]
    }
}
