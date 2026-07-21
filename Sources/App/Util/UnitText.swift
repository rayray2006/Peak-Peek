import Foundation

/// Locale-aware elevation/distance formatting, with a user override
/// (menu "Units" row). (Ported from RidgeLine.)
enum UnitText {
    /// UserDefaults key: "imperial" / "metric"; unset = follow the locale.
    static let overrideKey = "unitsOverride"

    static var usesFeet: Bool {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case "imperial": return true
        case "metric": return false
        default: return Locale.current.measurementSystem == .us
        }
    }
    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Elevation in feet (US) or meters — NEVER auto-scaled to miles.
    static func elevation(meters: Double) -> String {
        let value = usesFeet ? meters * 3.28084 : meters
        let digits = number.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
        return digits + (usesFeet ? " ft" : " m")
    }

    /// Nearest 8-point compass direction ("N", "NE", …) for a bearing in degrees.
    /// One home for the table — it was copy-pasted in three views.
    static func compassDirection(bearingDeg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        var h = bearingDeg.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return dirs[Int((h / 45).rounded()) % 8]
    }

    /// Distance in mi (US) or km, with one decimal under 10 and meters under ~1 km.
    static func distance(meters: Double) -> String {
        if usesFeet {
            let miles = meters / 1609.344
            return miles < 0.1
                ? "\(Int(meters * 3.28084)) ft"
                : String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
        }
        if meters < 1000 { return "\(Int(meters)) m" }
        let km = meters / 1000
        return String(format: km < 10 ? "%.1f km" : "%.0f km", km)
    }
}
