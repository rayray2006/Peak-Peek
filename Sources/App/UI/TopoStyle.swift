import UIKit

/// Topo color language shared by the UI chrome. (Ported from RidgeLine.)
enum TopoStyle {
    static let background = UIColor(red: 0.161, green: 0.176, blue: 0.180, alpha: 1.0)
    static let terrainWhite = UIColor(white: 0.95, alpha: 1.0)
    /// UI accent — the warm orange already used by the HUD's warning states
    /// (simulated time, active downloads), now the app-wide accent. Matches
    /// SwiftUI's `.orange` so accent chrome and warning tints read as one family.
    static let accent = UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1.0)
    static let water = UIColor(red: 0.35, green: 0.69, blue: 0.96, alpha: 1.0)
    static let capsuleDark = UIColor(red: 0.231, green: 0.255, blue: 0.275, alpha: 1.0)
    /// Dark text/glyph color for content sitting ON an accent-filled capsule.
    static let accentText = UIColor(red: 0.212, green: 0.110, blue: 0.0, alpha: 1.0)
    static let leader = UIColor(white: 0.78, alpha: 0.55)
    static let sunArc = UIColor(red: 0.93, green: 0.78, blue: 0.25, alpha: 1.0)
    static let moonArc = UIColor(red: 0.76, green: 0.36, blue: 0.82, alpha: 1.0)
    static let moonDisc = UIColor(red: 0.91, green: 0.91, blue: 0.95, alpha: 1.0)
    static let timePill = UIColor(red: 0.10, green: 0.15, blue: 0.21, alpha: 1.0)
}
