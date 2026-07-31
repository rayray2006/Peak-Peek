import Foundation

/// Locale-aware 12/24-hour time formatting, with a user override (menu "Time"
/// row). Mirrors `UnitText`: an unset override follows the device locale's own
/// clock convention; "24"/"12" force military / AM-PM.
enum ClockText {
    /// UserDefaults key: "24" / "12"; unset = follow the locale.
    static let overrideKey = "clockOverride"

    /// The device locale's own convention — used as the default and as the
    /// seed when the user first toggles the override.
    static var localeUses24Hour: Bool {
        // The "j" template resolves to the locale's preferred hour field; a
        // 12-hour locale includes the AM/PM designator ("a"), a 24-hour one
        // doesn't. (Foundation's canonical way to read the setting.)
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        return !template.contains("a")
    }

    static var uses24Hour: Bool {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case "24": return true
        case "12": return false
        default: return localeUses24Hour
        }
    }

    /// Point a time-of-day formatter at the current preference (call it right
    /// after setting the formatter's `timeZone`). A set override forces the
    /// hour cycle via a localized template (so separators/placement stay
    /// locale-correct); an unset one lands on the locale's own short style.
    static func applyTimeStyle(to f: DateFormatter) {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case "24": f.setLocalizedDateFormatFromTemplate("Hmm")
        case "12": f.setLocalizedDateFormatFromTemplate("hmma")
        default:
            f.dateFormat = nil
            f.timeStyle = .short
            f.dateStyle = .none
        }
    }
}
