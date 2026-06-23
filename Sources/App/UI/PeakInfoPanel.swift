import SwiftUI

/// The selected-peak card: name, elevation, distance, bearing, list actions, and
/// "Stand here" to view the panorama from the summit. (Ported from RidgeLine;
/// retargeted to mountainView's `AnnotatedPeak`.)
struct PeakInfoPanel: View {
    let peak: AnnotatedPeak
    let isClimbed: Bool
    let isBookmarked: Bool
    let onToggleClimbed: () -> Void
    let onToggleBookmark: () -> Void
    let onVisit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                titleBlock
                Spacer()
            }
            .padding(.trailing, 28)

            HStack(spacing: 8) {
                listChip("Climbed", systemImage: "checkmark.seal.fill", active: isClimbed, tint: .green) {
                    onToggleClimbed()
                }
                listChip("Bookmark", systemImage: "bookmark.fill", active: isBookmarked, tint: .orange) {
                    onToggleBookmark()
                }
                Button(action: onVisit) {
                    actionLabel("Stand here", systemImage: "figure.stand")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .padding(7)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(peak.peak.name)
                .font(.headline)
            HStack(spacing: 10) {
                if peak.peak.elevationMeters > 0 {
                    label(UnitText.elevation(meters: peak.peak.elevationMeters))
                }
                label(distanceText)
                label(compassText)
            }
            .font(.caption)
            .opacity(0.8)
        }
    }

    private func label(_ text: String) -> some View { Text(text) }

    private func actionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(.white)
    }

    private func listChip(
        _ text: String,
        systemImage: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? .black : .white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(active ? tint : Color.white.opacity(0.13), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var distanceText: String {
        UnitText.distance(meters: peak.distanceMeters)
    }

    private var compassText: String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int((peak.azimuthDeg / 45).rounded()) % 8
        return "\(dirs[idx]) \(Int(peak.azimuthDeg.rounded()))°"
    }
}
