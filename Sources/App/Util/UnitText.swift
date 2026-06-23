import Foundation

/// Locale-aware elevation/distance formatting. (Ported from RidgeLine.)
enum UnitText {
    private static let usesFeet = Locale.current.measurementSystem == .us
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
