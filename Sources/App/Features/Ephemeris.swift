import Foundation

/// Local sun and moon ephemeris (Jean Meeus' "Astronomical Algorithms"). No network.
///   - Sun: NOAA's low-accuracy algorithm (±0.01°).
///   - Moon: truncated Meeus ch. 47 series (±0.3°) + topocentric parallax.
/// Azimuth is compass convention (0 = north, clockwise); elevation APPARENT
/// (atmospheric refraction included). The terrain is rendered with refraction
/// folded in (the 0.87 curvature factor), so sky positions must be apparent too
/// — geometric ones sat up to a solar diameter below the real sun at the
/// horizon and mis-timed rise/set against the rendered ridge by ~2 minutes.
/// (Ported from RidgeLine; refraction added.)
enum Ephemeris {

    enum Body: Sendable {
        case sun, moon
    }

    struct SkyPosition: Sendable {
        let azimuthDeg: Double
        let elevationDeg: Double
    }

    struct PathSample: Sendable {
        let date: Date
        let position: SkyPosition
    }

    struct Path: Sendable {
        let body: Body
        let samples: [PathSample]

        /// Whether `date` falls inside the sampled lap — the caller's guarantee
        /// that the body's disc at `date` lies ON the drawn arc.
        func covers(_ date: Date) -> Bool {
            guard let first = samples.first?.date, let last = samples.last?.date else { return false }
            return date >= first && date <= last
        }
    }

    struct MoonPhase: Sendable {
        let name: String
        let illuminatedFraction: Double
        let ageDays: Double
    }

    /// Atmospheric refraction (degrees) lifting a body at TRUE altitude `h`
    /// (degrees): Sæmundsson's standard-atmosphere formula (Meeus ch. 16),
    /// ~0.48° at the true horizon falling to ~0.02° at 45°. Below −1°, where the
    /// formula diverges, the −1° value is held — such objects are culled or far
    /// below any skyline anyway, and a smooth constant keeps windowPath's
    /// culmination scan and crossing interpolation well-behaved.
    static func refractionDeg(trueAltitudeDeg: Double) -> Double {
        let h = max(trueAltitudeDeg, -1.0)
        return 1.02 / tan((h + 10.3 / (h + 5.11)) * .pi / 180) / 60.0
    }

    /// Apply refraction: geometric → apparent position.
    private static func apparent(_ p: SkyPosition) -> SkyPosition {
        SkyPosition(azimuthDeg: p.azimuthDeg,
                    elevationDeg: p.elevationDeg + refractionDeg(trueAltitudeDeg: p.elevationDeg))
    }

    static func position(of body: Body, date: Date, latitude: Double, longitude: Double) -> SkyPosition {
        switch body {
        case .sun: return sunPosition(date: date, latitude: latitude, longitude: longitude)
        case .moon: return moonPosition(date: date, latitude: latitude, longitude: longitude)
        }
    }

    static func sunPosition(date: Date, latitude: Double, longitude: Double) -> SkyPosition {
        let jd = julianDay(date)
        let T = (jd - 2451545.0) / 36525.0
        let L0 = normalizeDeg(280.46646 + T * (36000.76983 + T * 0.0003032))
        let M = (357.52911 + T * (35999.05029 - T * 0.0001537)) * .pi / 180
        let C = (1.914602 - T * (0.004817 + 0.000014 * T)) * sin(M)
            + (0.019993 - 0.000101 * T) * sin(2 * M)
            + 0.000289 * sin(3 * M)
        let omega = (125.04 - 1934.136 * T) * .pi / 180
        let lambda = (L0 + C - 0.00569 - 0.00478 * sin(omega)) * .pi / 180
        let eps = obliquityRad(T) + 0.00256 * cos(omega) * .pi / 180
        let dec = asin(sin(eps) * sin(lambda))
        let ra = atan2(cos(eps) * sin(lambda), cos(lambda))
        return apparent(horizontal(raRad: ra, decRad: dec, jd: jd, latitude: latitude, longitude: longitude))
    }

    static func moonPosition(date: Date, latitude: Double, longitude: Double) -> SkyPosition {
        let jd = julianDay(date)
        let T = (jd - 2451545.0) / 36525.0
        func rad(_ deg: Double) -> Double { normalizeDeg(deg) * .pi / 180 }
        let Lp = normalizeDeg(218.3164477 + 481267.88123421 * T)
        let D = rad(297.8501921 + 445267.1114034 * T)
        let M = rad(357.5291092 + 35999.0502909 * T)
        let Mp = rad(134.9633964 + 477198.8675055 * T)
        let F = rad(93.2720950 + 483202.0175233 * T)
        let lonDeg = Lp
            + 6.288774 * sin(Mp) + 1.274027 * sin(2 * D - Mp) + 0.658314 * sin(2 * D)
            + 0.213618 * sin(2 * Mp) - 0.185116 * sin(M) - 0.114332 * sin(2 * F)
            + 0.058793 * sin(2 * D - 2 * Mp) + 0.057066 * sin(2 * D - M - Mp)
            + 0.053322 * sin(2 * D + Mp) + 0.045758 * sin(2 * D - M)
        let latDeg = 5.128122 * sin(F) + 0.280602 * sin(Mp + F) + 0.277693 * sin(Mp - F)
            + 0.173237 * sin(2 * D - F) + 0.055413 * sin(2 * D + F - Mp)
            + 0.046271 * sin(2 * D - F - Mp)
        let lambda = lonDeg * .pi / 180
        let beta = latDeg * .pi / 180
        let eps = obliquityRad(T)
        let dec = asin(sin(beta) * cos(eps) + cos(beta) * sin(eps) * sin(lambda))
        let ra = atan2(sin(lambda) * cos(eps) - tan(beta) * sin(eps), cos(lambda))
        let geocentric = horizontal(raRad: ra, decRad: dec, jd: jd, latitude: latitude, longitude: longitude)
        let parallax = 0.95 * cos(geocentric.elevationDeg * .pi / 180)
        // Order matters: parallax lowers the TRUE altitude first, refraction then
        // lifts the topocentric result.
        let el = geocentric.elevationDeg - parallax
        return SkyPosition(
            azimuthDeg: geocentric.azimuthDeg,
            elevationDeg: el + refractionDeg(trueAltitudeDeg: el)
        )
    }

    static func moonPhase(date: Date) -> MoonPhase {
        let epoch = Date(timeIntervalSince1970: 947_182_440)
        let synodicMonthDays = 29.530588853
        var age = date.timeIntervalSince(epoch) / 86_400
        age = age.truncatingRemainder(dividingBy: synodicMonthDays)
        if age < 0 { age += synodicMonthDays }

        let angle = 2 * Double.pi * age / synodicMonthDays
        let illuminated = (1 - cos(angle)) * 0.5
        let names = [
            "New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
            "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent",
        ]
        let index = Int(((age / synodicMonthDays) * 8 + 0.5).rounded(.down)) % 8
        return MoonPhase(name: names[index], illuminatedFraction: illuminated, ageDays: age)
    }

    /// One full diurnal lap CONTAINING `date`, anchored at the body's LOWER
    /// CULMINATION so the open seam sits at the bottom of the sky.
    ///
    /// The lap is anchored to the culmination (an instant intrinsic to the sky,
    /// refined to the minute grid), NOT to the exact `date`, so scrubbing the
    /// time of day leaves the arc fixed — only the disc moves along it; the arc
    /// re-anchors only when the scrub crosses the culmination itself, at the
    /// bottom of the sky. It used to be anchored to the CALENDAR day instead
    /// (back-scan from local noon), which broke the moon: its lap is ~24h50m,
    /// so an evening `date` could fall AFTER the day-anchored lap ended and the
    /// disc sat visibly off the drawn arc — off by the ~13°/day orbital drift
    /// from the previous lap.
    static func windowPath(
        of body: Body, centeredOn date: Date, latitude: Double, longitude: Double,
        stepMinutes: Int = 10
    ) -> Path {
        let totalMinutes = body == .moon ? 1_490 : 1_440
        func elevation(_ d: Date) -> Double {
            position(of: body, date: d, latitude: latitude, longitude: longitude).elevationDeg
        }
        // Coarse back-scan over a bit MORE than one lap (the pad keeps a
        // culmination in view even at the moon's longest laps), keeping the most
        // recent LOCAL minimum before `date` — the lower culmination that starts
        // the lap containing it. A plain global minimum re-picked the previous
        // culmination when the window held two, ending the lap before `date`.
        let scanBackMinutes = totalMinutes + 120
        var els: [Double] = []
        els.reserveCapacity(scanBackMinutes / stepMinutes + 1)
        var scan = -scanBackMinutes
        while scan <= 0 {
            els.append(elevation(date.addingTimeInterval(TimeInterval(scan * 60))))
            scan += stepMinutes
        }
        var anchorIndex = els.indices.min { els[$0] < els[$1] } ?? 0   // fallback: global min
        for i in stride(from: els.count - 2, through: 1, by: -1)
        where els[i] <= els[i - 1] && els[i] < els[i + 1] {
            anchorIndex = i
            break
        }
        let coarse = date.addingTimeInterval(TimeInterval((anchorIndex * stepMinutes - scanBackMinutes) * 60))
        // Refine on the ABSOLUTE minute grid (not offsets from `date`): the
        // anchor then lands on the same instant however the caller scrubs, so
        // every sample — and the drawn arc — holds still to the sub-pixel.
        var start = coarse
        var lowest = Double.infinity
        let gridStart = (coarse.timeIntervalSince1970 / 60).rounded(.down) * 60
            - Double(stepMinutes * 60)
        for m in 0...(2 * stepMinutes) {
            let d = Date(timeIntervalSince1970: gridStart + Double(m * 60))
            let el = elevation(d)
            if el < lowest {
                lowest = el
                start = d
            }
        }
        var samples: [PathSample] = []
        samples.reserveCapacity(totalMinutes / stepMinutes + 1)
        var t = 0
        while t <= totalMinutes {
            let d = start.addingTimeInterval(TimeInterval(t * 60))
            samples.append(PathSample(
                date: d, position: position(of: body, date: d, latitude: latitude, longitude: longitude)
            ))
            t += stepMinutes
        }
        // (No astronomical-horizon rise/set scan here: the sky overlay derives
        // its rise/set tags from the RIDGE skyline, not sea level.)
        return Path(body: body, samples: samples)
    }

    // MARK: - Shared helpers

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    private static func obliquityRad(_ T: Double) -> Double {
        (23.439291 - T * (0.0130042 + T * 0.00000016)) * .pi / 180
    }

    private static func normalizeDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private static func horizontal(
        raRad: Double, decRad: Double, jd: Double, latitude: Double, longitude: Double
    ) -> SkyPosition {
        let gmstDeg = normalizeDeg(280.46061837 + 360.98564736629 * (jd - 2451545.0))
        let lstRad = (gmstDeg + longitude) * .pi / 180
        let H = lstRad - raRad
        let lat = latitude * .pi / 180
        let el = asin(sin(lat) * sin(decRad) + cos(lat) * cos(decRad) * cos(H))
        let azFromSouth = atan2(sin(H), cos(H) * sin(lat) - tan(decRad) * cos(lat))
        return SkyPosition(
            azimuthDeg: normalizeDeg(azFromSouth * 180 / .pi + 180),
            elevationDeg: el * 180 / .pi
        )
    }
}
