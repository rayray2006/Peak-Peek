import SwiftUI
import UIKit

/// PeakPeek's "field instrument" design language (from the PeakPeek Claude
/// Design template): near-black ink on paper white, 1 px hairlines, Space
/// Grotesk for UI text and IBM Plex Mono for data readouts. Chrome floating
/// over the terrain is ink with a soft paper halo (the mock's pale-gray world
/// can't promise a pale sky at night); solid surfaces are the black location
/// card and white bottom sheets. Only SEMANTIC colors break the monochrome:
/// visible green, occluded red, saved gold, climbed green, water blue.
enum TopoStyle {
    // MARK: Core palette

    /// The raw template values. After sunset the roles swap (see `ink`/`paper`):
    /// ink chrome turns white so it reads over the dark night render.
    private static let inkLight = UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
    private static let inkDark = UIColor(white: 0.96, alpha: 1)

    /// Near-black ink — every stroke, glyph and solid dark surface. DYNAMIC:
    /// resolves to near-white in dark mode (RootScreen switches the scene to
    /// dark after sunset at the viewed location).
    static let ink = UIColor { tc in
        tc.userInterfaceStyle == .dark ? inkDark : inkLight
    }
    /// Paper — sheets, cards, and the halo behind floating ink chrome.
    /// DYNAMIC: near-black in dark mode (the inverse of `ink`).
    static let paper = UIColor { tc in
        tc.userInterfaceStyle == .dark ? inkLight : .white
    }

    /// Legacy aliases (older call sites): the accent surface is now the ink
    /// pill, content on it paper.
    static let background = paper
    static let accent = ink
    static let accentText = paper

    // MARK: Semantic accents (template values)

    /// Sightline clear (template #2f9e44).
    static let visibleGreen = UIColor(red: 0x2f / 255, green: 0x9e / 255, blue: 0x44 / 255, alpha: 1)
    /// Sightline blocked (template #d64545).
    static let occludedRed = UIColor(red: 0xd6 / 255, green: 0x45 / 255, blue: 0x45 / 255, alpha: 1)
    /// Saved/bookmarked (template #f0b429).
    static let savedGold = UIColor(red: 0xf0 / 255, green: 0xb4 / 255, blue: 0x29 / 255, alpha: 1)
    /// Water features keep a deep lake blue that reads against snow and paper.
    static let waterBlue = UIColor(red: 0x2b / 255, green: 0x6c / 255, blue: 0xb0 / 255, alpha: 1)
    /// Passes/saddles: a deep muted pine green — darker and duller than
    /// visibleGreen so a gap's dot never reads as a sightline verdict.
    static let saddleGreen = UIColor(red: 0x2d / 255, green: 0x6a / 255, blue: 0x4f / 255, alpha: 1)

    // MARK: SwiftUI colors

    static let inkColor = Color(ink)
    static let paperColor = Color(paper)
    static let visibleColor = Color(visibleGreen)
    static let occludedColor = Color(occludedRed)
    static let goldColor = Color(savedGold)
    static let waterColor = Color(waterBlue)
    static let saddleColor = Color(saddleGreen)

    /// Hairline strokes on paper: 1 px at the template's opacities.
    static func hairline(_ opacity: Double = 0.14) -> Color { inkColor.opacity(opacity) }
}

/// Space Grotesk (UI) + IBM Plex Mono (data), with system fallbacks so a
/// missing font degrades gracefully instead of rendering blank.
enum PPFont {
    // MARK: UIFont (CALayer overlays)

    static func grotesk(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black:
            name = weight == .semibold ? "SpaceGrotesk-SemiBold" : "SpaceGrotesk-Bold"
        case .medium:
            name = "SpaceGrotesk-Medium"
        default:
            name = "SpaceGrotesk-Regular"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func plexMono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let name = weight == .medium || weight == .semibold || weight == .bold
            ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return UIFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: SwiftUI Font

    static func ui(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> Font {
        Font(grotesk(size, weight))
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> Font {
        Font(plexMono(size, weight))
    }
}

// MARK: - Shared components

/// A mono micro-label: the template's uppercase, letterspaced tag
/// ("MAP", "V1.0 · SURVEYING THE RANGE").
struct PPMicroLabel: View {
    let text: String
    var size: CGFloat = 9
    var opacity: Double = 0.5

    var body: some View {
        Text(text.uppercased())
            .font(PPFont.mono(size))
            .tracking(size * 0.16)
            .foregroundStyle(TopoStyle.inkColor.opacity(opacity))
    }
}

/// The template's thin progress line: hairline track, ink (or custom) fill.
struct PPProgressLine: View {
    let progress: Double
    var width: CGFloat = 200
    var height: CGFloat = 1
    var tint: Color = TopoStyle.inkColor
    var track: Color = TopoStyle.hairline()

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(track)
            Rectangle().fill(tint)
                .frame(width: width * CGFloat(min(1, max(0, progress))))
        }
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

/// The template's visibility badge: green filled dot = visible, red outlined
/// dot = occluded, with a letterspaced mono caption.
struct PPVisibilityBadge: View {
    let visible: Bool
    var ink: Color = TopoStyle.inkColor

    var body: some View {
        HStack(spacing: 6) {
            if visible {
                Circle().fill(TopoStyle.visibleColor).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(TopoStyle.occludedColor, lineWidth: 1.5)
                    .frame(width: 6, height: 6)
            }
            Text(visible ? "Visible" : "Occluded")
                .font(PPFont.mono(10))
                .tracking(0.8)
                .foregroundStyle(ink.opacity(0.55))
        }
        .fixedSize()
    }
}

// (The old "ink halo" glow behind floating chrome is gone: the theme now
// inverts with the sky — ink by day, paper by night — so the text no longer
// needs a contrast glow, and the glow read as a smudge around black text.)
