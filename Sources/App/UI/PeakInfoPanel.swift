import SwiftUI

/// The selected-peak card: name, elevation, distance, bearing, list actions, and
/// "Stand here" to view the panorama from the summit. (Ported from RidgeLine;
/// retargeted to PeakPeek's `AnnotatedPeak`.)
struct PeakInfoPanel: View {
    let peak: AnnotatedPeak
    /// Line-of-sight verdict from the renderer's occlusion pass: true = a sightline
    /// from the eye reaches the summit, false = terrain hides it. nil while the
    /// pass for the current viewpoint hasn't finished (no badge shown).
    let isVisible: Bool?
    /// Water feature (lake/reservoir): hides the Climbed/Bookmark list chips —
    /// you don't climb a lake, and the peak lists are summit lists.
    let isWater: Bool
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
                if !isWater {
                    listChip("Climbed", systemImage: "checkmark.seal.fill", active: isClimbed, tint: .green) {
                        onToggleClimbed()
                    }
                    listChip("Bookmark", systemImage: "bookmark.fill", active: isBookmarked, tint: .orange) {
                        onToggleBookmark()
                    }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(peak.peak.name)
                .font(.headline)
            // Elevation, distance, bearing — small accent-tinted icons on each.
            HStack(spacing: 14) {
                if peak.peak.elevationMeters > 0 {
                    stat("mountain.2.fill", UnitText.elevation(meters: peak.peak.elevationMeters))
                }
                stat("ruler.fill", distanceText)
                stat("safari.fill", compassText)
                if let isVisible {
                    visibilityBadge(isVisible)
                }
            }
        }
    }

    /// Green "Visible" / red "Hidden": whether the summit has a clear sightline
    /// from the eye or terrain blocks it (renderer's occlusion verdict).
    private func visibilityBadge(_ visible: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(visible ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(visible ? "Visible" : "Hidden")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
    }

    /// A small stat: an accent-tinted SF Symbol + its value.
    private func stat(_ systemImage: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(TopoStyle.accent))
            Text(value)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
    }

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
