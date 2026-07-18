import SwiftUI

/// The "Saved" / "Been" lists, in the template's language: a pill
/// segmented control (active segment = black capsule), then light rows —
/// name in Space Grotesk, elevation and facts in mono — separated by
/// hairlines. Tap a peak to select it; swipe to remove or promote.
struct PeakListsView: View {
    @ObservedObject var store: PeakListStore
    let viewpoint: PanoramaViewModel.Viewpoint?
    /// Owned by RootScreen so the chosen tab survives the panel closing —
    /// picking a peak opens its card, and closing that returns here with the
    /// same list showing.
    @Binding var selection: PeakListKind
    let onPick: (Peak) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Saved first, as the template orders the tabs.
    private static let tabs: [PeakListKind] = [.wantToClimb, .climbed]

    enum Sort: String, CaseIterable, Identifiable {
        case date = "Date"
        case elevation = "Elevation"
        case distance = "Distance"
        var id: String { rawValue }
    }

    /// Date (newest first) is the store's natural order — the default.
    @State private var sort: Sort = .date

    // Card-embedded only (the hosting PanelCard owns the chrome + grabber +
    // title row).
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                segmentedPill
                sortMenu
            }
            .padding(.horizontal, 20)
            if rows.isEmpty {
                emptyState
            } else {
                rowsList
            }
        }
    }

    /// Same quiet sort control as the Search sheet: a bare ink glyph opening
    /// a checkmarked menu (Elevation / Date / Distance).
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
        .accessibilityLabel("Sort by \(sort.rawValue)")
    }

    /// The template's segmented pill: hairline-gray track, black active capsule.
    private var segmentedPill: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { kind in
                let active = selection == kind
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = kind }
                } label: {
                    Text(kind.title)
                        .font(PPFont.ui(13, .semibold))
                        .foregroundStyle(active ? TopoStyle.paperColor : TopoStyle.inkColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if active {
                                Capsule().fill(TopoStyle.inkColor)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(TopoStyle.inkColor.opacity(0.06), in: Capsule())
    }

    private var rowsList: some View {
        List {
            ForEach(rows) { row in
                Button {
                    onPick(row.saved.peak)
                    dismiss()
                } label: {
                    PeakListRow(row: row, kind: selection)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparatorTint(TopoStyle.hairline(0.08))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.remove(row.saved.peak, from: selection)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                // Saved: swipe right to promote straight to Completed.
                .swipeActions(edge: .leading) {
                    if selection == .wantToClimb {
                        Button {
                            if !store.contains(row.saved.peak, in: .climbed) {
                                store.toggle(row.saved.peak, in: .climbed)
                            }
                            store.remove(row.saved.peak, from: .wantToClimb)
                        } label: {
                            Label("Been", systemImage: "checkmark.seal.fill")
                        }
                        .tint(TopoStyle.visibleColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var rows: [PeakListRowModel] {
        let mapped = store.peaks(in: selection).map { saved in
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
        switch sort {
        case .date:
            return mapped   // the store's order IS newest-first
        case .elevation:
            return mapped.sorted {
                $0.saved.peak.elevationMeters > $1.saved.peak.elevationMeters
            }
        case .distance:
            return mapped.sorted {
                ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: selection.systemImage)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selection == .climbed ? TopoStyle.visibleColor : TopoStyle.goldColor)
            Text("Nothing here yet")
                .font(PPFont.ui(15, .semibold))
                .foregroundStyle(TopoStyle.inkColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

private struct PeakListRowModel: Identifiable {
    let saved: SavedPeak
    let distanceMeters: Double?
    let bearingDeg: Double?

    var id: String { saved.id }
}

/// A template list row: "name ……… elevation", both tabs bare — the tab
/// itself already says which list this is. Hairline below (List supplies it).
private struct PeakListRow: View {
    let row: PeakListRowModel
    let kind: PeakListKind

    var body: some View {
        HStack(spacing: 10) {
            Text(row.saved.peak.displayName)
                .font(PPFont.ui(15, .medium))
                .foregroundStyle(TopoStyle.inkColor)
                .lineLimit(1)
            Spacer(minLength: 12)
            if row.saved.peak.elevationMeters > 0 {
                Text(UnitText.elevation(meters: row.saved.peak.elevationMeters))
                    .font(PPFont.mono(11))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
    }
}
