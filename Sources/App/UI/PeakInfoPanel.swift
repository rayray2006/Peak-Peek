import SwiftUI

/// The selected-peak card, in the template's language: a white card with the
/// peak name and a row of glyph badges (gold bookmark = Saved, green seal =
/// Completed, standing figure = "Stand here"), a mono stats line
/// ("6,259 ft · 4.2 mi · SE 141°"), and the Visible/Occluded dot.
struct PeakInfoPanel: View {
    let peak: AnnotatedPeak
    /// Line-of-sight verdict from the renderer's occlusion pass: true = a sightline
    /// from the eye reaches the summit, false = terrain hides it. nil while the
    /// pass for the current viewpoint hasn't finished (no badge shown).
    let isVisible: Bool?
    let isClimbed: Bool
    /// When the feature was marked "Been" — a quiet calendar note on the card.
    let beenDate: Date?
    let isBookmarked: Bool
    let onToggleClimbed: () -> Void
    let onToggleBookmark: () -> Void
    let onVisit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name left; the quiet been-date rides the row's free space
            // (stats row stays single-line whatever badges it carries).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                nameText
                Spacer(minLength: 8)
                if let beenDate {
                    // Small and quiet: when you were here.
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9, weight: .medium))
                        Text(Self.beenText(beenDate))
                            .font(PPFont.mono(10))
                    }
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.45))
                    .fixedSize()
                }
            }
            .padding(.trailing, 28)

            // Facts left, sightline verdict right — one row.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(statsLine)
                    .font(PPFont.mono(12))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let isVisible {
                    PPVisibilityBadge(visible: isVisible)
                }
            }

            // Three real buttons sharing the card's width.
            HStack(spacing: 8) {
                actionButton("Save",
                             systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                             tint: TopoStyle.goldColor, active: isBookmarked,
                             action: onToggleBookmark)
                actionButton("Been",
                             systemImage: isClimbed ? "checkmark.circle.fill" : "checkmark.circle",
                             tint: TopoStyle.visibleColor, active: isClimbed,
                             action: onToggleClimbed)
                actionButton("Stand here", systemImage: "figure.stand",
                             tint: nil, active: false, action: onVisit)
            }
        }
        // The card owns the whole row (the mini-map yields while it's up), so
        // it stretches to the full width — long peak names get every point.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }

    private var nameText: some View {
        Text(peak.peak.displayName)
            .font(PPFont.ui(18, .semibold))
            .foregroundStyle(TopoStyle.inkColor)
            .lineLimit(1)
    }

    /// A full-height bordered action button: icon + label, equal share of the
    /// card's width. Active state tints the icon and washes the fill (gold =
    /// saved, green = been); "Stand here" stays plain ink.
    private func actionButton(
        _ title: String, systemImage: String,
        tint: Color?, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(active ? (tint ?? TopoStyle.inkColor)
                        : TopoStyle.inkColor.opacity(0.8))
                    // Fixed, centered glyph box: the filled symbol variants
                    // are a hair larger than the outlines, and without this
                    // the whole row re-laid out from its top-leading corner —
                    // the "grows toward bottom-right" toggle jitter.
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(PPFont.ui(14, .semibold))
                    .foregroundStyle(TopoStyle.inkColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                if active, let tint {
                    RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.14))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(active && tint != nil
                        ? (tint ?? TopoStyle.inkColor).opacity(0.5)
                        : TopoStyle.hairline(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// "Jul 12" this year, "Jul 2025" otherwise — enough to place the memory.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f
    }()
    private static func beenText(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? dayFormatter.string(from: date) : yearFormatter.string(from: date)
    }

    /// "6,259 ft · 4.2 mi · SE 141°" — elevation, distance, bearing in one
    /// mono line, exactly as the template lays it out.
    private var statsLine: String {
        var parts: [String] = []
        if peak.peak.elevationMeters > 0 {
            parts.append(UnitText.elevation(meters: peak.peak.elevationMeters))
        }
        parts.append(UnitText.distance(meters: peak.distanceMeters))
        parts.append("\(UnitText.compassDirection(bearingDeg: peak.azimuthDeg)) \(Int(peak.azimuthDeg.rounded()))°")
        return parts.joined(separator: " · ")
    }
}
