import Foundation

enum CelestialSky {
    struct Star: Sendable {
        let name: String
        let rightAscensionHours: Double
        let declinationDeg: Double
        let magnitude: Double
        let color: StarColor
    }

    enum StarColor: Sendable {
        case blueWhite
        case white
        case yellowWhite
        case orange
        case red

        var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .blueWhite: return (0.72, 0.82, 1.00)
            case .white: return (0.95, 0.97, 1.00)
            case .yellowWhite: return (1.00, 0.92, 0.72)
            case .orange: return (1.00, 0.72, 0.44)
            case .red: return (1.00, 0.50, 0.38)
            }
        }
    }

    struct ProjectedStar: Sendable {
        let name: String
        let azimuthDeg: Double
        let elevationDeg: Double
        let magnitude: Double
        let color: StarColor
    }


    /// Real star catalog bundled as `stars.csv` (~2.9k stars to mag 5.5, every one
    /// named — proper name, else Bayer/Flamsteed designation, else HIP id — so every
    /// real star is tappable). Built by `Tools/StarCatalog/build_star_catalog.py`
    /// from the HYG database (CC BY-SA, needs attribution). Falls back to the
    /// hand-curated bright list if the resource is missing/corrupt.
    static let catalogStars: [Star] = loadCatalogStars() ?? brightStars

    private static func loadCatalogStars() -> [Star]? {
        guard let url = Bundle.main.url(forResource: "stars", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let colors: [StarColor] = [.blueWhite, .white, .yellowWhite, .orange, .red]
        var out: [Star] = []
        out.reserveCapacity(3000)
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",")
            guard f.count == 5,
                  let ra = Double(f[1]), let dec = Double(f[2]),
                  let mag = Double(f[3]), let ci = Int(f[4]), colors.indices.contains(ci)
            else { continue }
            out.append(Star(name: String(f[0]), rightAscensionHours: ra,
                            declinationDeg: dec, magnitude: mag, color: colors[ci]))
        }
        return out.isEmpty ? nil : out
    }

    // Bright-star subset from J2000 visual catalog values — FALLBACK ONLY (the
    // bundled catalog above supersedes it), kept so the sky still has its anchors
    // if the resource ever goes missing.
    static let brightStars: [Star] = [
        Star(name: "Sirius", rightAscensionHours: 6.7525, declinationDeg: -16.7161, magnitude: -1.46, color: .blueWhite),
        Star(name: "Canopus", rightAscensionHours: 6.3992, declinationDeg: -52.6957, magnitude: -0.74, color: .yellowWhite),
        Star(name: "Arcturus", rightAscensionHours: 14.2610, declinationDeg: 19.1825, magnitude: -0.05, color: .orange),
        Star(name: "Vega", rightAscensionHours: 18.6156, declinationDeg: 38.7837, magnitude: 0.03, color: .blueWhite),
        Star(name: "Capella", rightAscensionHours: 5.2782, declinationDeg: 45.9980, magnitude: 0.08, color: .yellowWhite),
        Star(name: "Rigel", rightAscensionHours: 5.2423, declinationDeg: -8.2016, magnitude: 0.13, color: .blueWhite),
        Star(name: "Procyon", rightAscensionHours: 7.6550, declinationDeg: 5.2250, magnitude: 0.34, color: .yellowWhite),
        Star(name: "Betelgeuse", rightAscensionHours: 5.9195, declinationDeg: 7.4071, magnitude: 0.42, color: .red),
        Star(name: "Achernar", rightAscensionHours: 1.6286, declinationDeg: -57.2368, magnitude: 0.46, color: .blueWhite),
        Star(name: "Hadar", rightAscensionHours: 14.0637, declinationDeg: -60.3730, magnitude: 0.61, color: .blueWhite),
        Star(name: "Altair", rightAscensionHours: 19.8464, declinationDeg: 8.8683, magnitude: 0.77, color: .white),
        Star(name: "Acrux", rightAscensionHours: 12.4433, declinationDeg: -63.0991, magnitude: 0.76, color: .blueWhite),
        Star(name: "Aldebaran", rightAscensionHours: 4.5987, declinationDeg: 16.5093, magnitude: 0.85, color: .orange),
        Star(name: "Spica", rightAscensionHours: 13.4199, declinationDeg: -11.1613, magnitude: 0.98, color: .blueWhite),
        Star(name: "Antares", rightAscensionHours: 16.4901, declinationDeg: -26.4320, magnitude: 1.06, color: .red),
        Star(name: "Pollux", rightAscensionHours: 7.7553, declinationDeg: 28.0262, magnitude: 1.14, color: .orange),
        Star(name: "Fomalhaut", rightAscensionHours: 22.9608, declinationDeg: -29.6222, magnitude: 1.16, color: .white),
        Star(name: "Deneb", rightAscensionHours: 20.6905, declinationDeg: 45.2803, magnitude: 1.25, color: .blueWhite),
        Star(name: "Mimosa", rightAscensionHours: 12.7953, declinationDeg: -59.6888, magnitude: 1.25, color: .blueWhite),
        Star(name: "Regulus", rightAscensionHours: 10.1395, declinationDeg: 11.9672, magnitude: 1.35, color: .blueWhite),
        Star(name: "Adhara", rightAscensionHours: 6.9771, declinationDeg: -28.9721, magnitude: 1.50, color: .blueWhite),
        Star(name: "Shaula", rightAscensionHours: 17.5601, declinationDeg: -37.1038, magnitude: 1.62, color: .blueWhite),
        Star(name: "Castor", rightAscensionHours: 7.5767, declinationDeg: 31.8883, magnitude: 1.58, color: .white),
        Star(name: "Gacrux", rightAscensionHours: 12.5194, declinationDeg: -57.1132, magnitude: 1.63, color: .red),
        Star(name: "Bellatrix", rightAscensionHours: 5.4189, declinationDeg: 6.3497, magnitude: 1.64, color: .blueWhite),
        Star(name: "Elnath", rightAscensionHours: 5.4382, declinationDeg: 28.6075, magnitude: 1.65, color: .blueWhite),
        Star(name: "Miaplacidus", rightAscensionHours: 9.2200, declinationDeg: -69.7172, magnitude: 1.67, color: .white),
        Star(name: "Alnilam", rightAscensionHours: 5.6036, declinationDeg: -1.2019, magnitude: 1.69, color: .blueWhite),
        Star(name: "Alnair", rightAscensionHours: 22.1372, declinationDeg: -46.9606, magnitude: 1.73, color: .blueWhite),
        Star(name: "Alioth", rightAscensionHours: 12.9005, declinationDeg: 55.9598, magnitude: 1.76, color: .blueWhite),
        Star(name: "Mirfak", rightAscensionHours: 3.4054, declinationDeg: 49.8612, magnitude: 1.79, color: .yellowWhite),
        Star(name: "Dubhe", rightAscensionHours: 11.0621, declinationDeg: 61.7510, magnitude: 1.79, color: .orange),
        Star(name: "Wezen", rightAscensionHours: 7.1399, declinationDeg: -26.3932, magnitude: 1.83, color: .yellowWhite),
        Star(name: "Sargas", rightAscensionHours: 17.6219, declinationDeg: -42.9978, magnitude: 1.86, color: .yellowWhite),
        Star(name: "Kaus Australis", rightAscensionHours: 18.4029, declinationDeg: -34.3846, magnitude: 1.85, color: .blueWhite),
        Star(name: "Avior", rightAscensionHours: 8.3752, declinationDeg: -59.5095, magnitude: 1.86, color: .orange),
        Star(name: "Alkaid", rightAscensionHours: 13.7923, declinationDeg: 49.3133, magnitude: 1.86, color: .blueWhite),
        Star(name: "Menkalinan", rightAscensionHours: 5.9921, declinationDeg: 44.9474, magnitude: 1.90, color: .white),
        Star(name: "Atria", rightAscensionHours: 16.8111, declinationDeg: -69.0277, magnitude: 1.91, color: .orange),
        Star(name: "Alhena", rightAscensionHours: 6.6285, declinationDeg: 16.3993, magnitude: 1.93, color: .white),
        Star(name: "Peacock", rightAscensionHours: 20.4275, declinationDeg: -56.7351, magnitude: 1.94, color: .blueWhite),
        Star(name: "Polaris", rightAscensionHours: 2.5303, declinationDeg: 89.2641, magnitude: 1.98, color: .yellowWhite),
        Star(name: "Mirzam", rightAscensionHours: 6.3783, declinationDeg: -17.9559, magnitude: 1.98, color: .blueWhite),
        Star(name: "Alphard", rightAscensionHours: 9.4598, declinationDeg: -8.6586, magnitude: 2.00, color: .orange),
        Star(name: "Hamal", rightAscensionHours: 2.1196, declinationDeg: 23.4624, magnitude: 2.01, color: .orange),
        Star(name: "Diphda", rightAscensionHours: 0.7265, declinationDeg: -17.9866, magnitude: 2.04, color: .orange),
        Star(name: "Nunki", rightAscensionHours: 18.9211, declinationDeg: -26.2967, magnitude: 2.05, color: .blueWhite),
        Star(name: "Mizar", rightAscensionHours: 13.3987, declinationDeg: 54.9254, magnitude: 2.23, color: .white),
        Star(name: "Kochab", rightAscensionHours: 14.8451, declinationDeg: 74.1555, magnitude: 2.08, color: .orange),
        Star(name: "Saiph", rightAscensionHours: 5.7959, declinationDeg: -9.6696, magnitude: 2.09, color: .blueWhite),
        Star(name: "Rasalhague", rightAscensionHours: 17.5822, declinationDeg: 12.5600, magnitude: 2.08, color: .white),
        Star(name: "Algol", rightAscensionHours: 3.1361, declinationDeg: 40.9556, magnitude: 2.12, color: .blueWhite),
        Star(name: "Denebola", rightAscensionHours: 11.8177, declinationDeg: 14.5721, magnitude: 2.14, color: .white),
        Star(name: "Almach", rightAscensionHours: 2.0650, declinationDeg: 42.3297, magnitude: 2.10, color: .orange),
        Star(name: "Schedar", rightAscensionHours: 0.6751, declinationDeg: 56.5373, magnitude: 2.24, color: .orange),
        Star(name: "Eltanin", rightAscensionHours: 17.9434, declinationDeg: 51.4889, magnitude: 2.24, color: .orange),
        Star(name: "Caph", rightAscensionHours: 0.1529, declinationDeg: 59.1498, magnitude: 2.28, color: .white),
        Star(name: "Merak", rightAscensionHours: 11.0307, declinationDeg: 56.3824, magnitude: 2.37, color: .white),
        Star(name: "Phecda", rightAscensionHours: 11.8972, declinationDeg: 53.6948, magnitude: 2.44, color: .white),
        Star(name: "Megrez", rightAscensionHours: 12.2571, declinationDeg: 57.0326, magnitude: 3.31, color: .white),
    ]

    // Procedural faint-star fill for density. NOT a real catalog — a deterministic
    // pseudo-random field (uniform on the sphere, weighted toward faint magnitudes),
    // generated once at launch so it costs ZERO storage and ~tens of KB of memory.
    // The real catalog covers everything to mag 5.5; this fills in the fainter
    // (5.5–7.5) background dust so the night sky looks dense. Unnamed → not
    // tappable. The whole field rotates correctly with sidereal time.
    static let fillStars: [Star] = makeFillStars(count: 3000)

    /// Real catalog + procedural faint fill, projected together.
    static let allStars: [Star] = catalogStars + fillStars

    private struct SplitMix64 {
        var state: UInt64
        mutating func nextU64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func nextUnit() -> Double { Double(nextU64() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    }

    private static func makeFillStars(count: Int) -> [Star] {
        var rng = SplitMix64(state: 0x1234_5678_9ABC_DEF0)   // fixed seed → stable field
        var out: [Star] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let raHours = rng.nextUnit() * 24.0
            let dec = asin(rng.nextUnit() * 2 - 1) * 180 / .pi       // equal-area on the sphere
            let mag = 5.5 + pow(rng.nextUnit(), 0.7) * 2.0          // ~5.5…7.5, below the real catalog
            let c = rng.nextUnit()
            let color: StarColor = c < 0.62 ? .white
                : c < 0.86 ? .blueWhite
                : c < 0.95 ? .yellowWhite
                : c < 0.99 ? .orange : .red
            out.append(Star(name: "", rightAscensionHours: raHours, declinationDeg: dec,
                            magnitude: mag, color: color))
        }
        return out
    }

    static func projectedStars(date: Date, latitude: Double, longitude: Double) -> [ProjectedStar] {
        let transform = SkyTransform(date: date, latitude: latitude, longitude: longitude)
        return allStars.map { star in
            let position = horizontal(
                rightAscensionDeg: star.rightAscensionHours * 15,
                declinationDeg: star.declinationDeg,
                transform: transform
            )
            return ProjectedStar(
                name: star.name,
                azimuthDeg: position.azimuthDeg,
                elevationDeg: position.elevationDeg,
                magnitude: star.magnitude,
                color: star.color
            )
        }
    }

    // MARK: - Planets

    struct ProjectedPlanet: Sendable {
        let name: String
        let azimuthDeg: Double
        let elevationDeg: Double
        let magnitude: Double
        let color: StarColor
    }

    /// JPL "Keplerian elements for approximate positions" (J2000 epoch + per-century
    /// rates). a (AU), e, inc/longPeri(ϖ)/longNode(Ω)/meanLong(L) in degrees.
    private struct PlanetElements {
        let name: String, color: StarColor, vRef: Double
        let a, aR, e, eR, inc, incR, peri, periR, node, nodeR, mLong, mLongR: Double
    }

    private static let earth = PlanetElements(
        name: "Earth", color: .white, vRef: 0,
        a: 1.00000261, aR: 0.00000562, e: 0.01671123, eR: -0.00004392,
        inc: -0.00001531, incR: -0.01294668, peri: 102.93768193, periR: 0.32327364,
        node: 0.0, nodeR: 0.0, mLong: 100.46457166, mLongR: 35999.37244981)

    private static let planetElements: [PlanetElements] = [
        PlanetElements(name: "Mercury", color: .yellowWhite, vRef: -0.42,
            a: 0.38709927, aR: 0.00000037, e: 0.20563593, eR: 0.00001906,
            inc: 7.00497902, incR: -0.00594749, peri: 77.45779628, periR: 0.16047689,
            node: 48.33076593, nodeR: -0.12534081, mLong: 252.25032350, mLongR: 149472.67411175),
        PlanetElements(name: "Venus", color: .white, vRef: -4.40,
            a: 0.72333566, aR: 0.00000390, e: 0.00677672, eR: -0.00004107,
            inc: 3.39467605, incR: -0.00078890, peri: 131.60246718, periR: 0.00268329,
            node: 76.67984255, nodeR: -0.27769418, mLong: 181.97909950, mLongR: 58517.81538729),
        PlanetElements(name: "Mars", color: .red, vRef: -1.52,
            a: 1.52371034, aR: 0.00001847, e: 0.09339410, eR: 0.00007882,
            inc: 1.84969142, incR: -0.00813131, peri: -23.94362959, periR: 0.44441088,
            node: 49.55953891, nodeR: -0.29257343, mLong: -4.55343205, mLongR: 19140.30268499),
        PlanetElements(name: "Jupiter", color: .yellowWhite, vRef: -9.40,
            a: 5.20288700, aR: -0.00011607, e: 0.04838624, eR: -0.00013253,
            inc: 1.30439695, incR: -0.00183714, peri: 14.72847983, periR: 0.21252668,
            node: 100.47390909, nodeR: 0.20469106, mLong: 34.39644051, mLongR: 3034.74612775),
        PlanetElements(name: "Saturn", color: .yellowWhite, vRef: -8.88,
            a: 9.53667594, aR: -0.00125060, e: 0.05386179, eR: -0.00050991,
            inc: 2.48599187, incR: 0.00193609, peri: 92.59887831, periR: -0.41897216,
            node: 113.66242448, nodeR: -0.28867794, mLong: 49.95424423, mLongR: 1222.49362201),
        PlanetElements(name: "Uranus", color: .blueWhite, vRef: -7.19,
            a: 19.18916464, aR: -0.00196176, e: 0.04725744, eR: -0.00004397,
            inc: 0.77263783, incR: -0.00242939, peri: 170.95427630, periR: 0.40805281,
            node: 74.01692503, nodeR: 0.04240589, mLong: 313.23810451, mLongR: 428.48202785),
        PlanetElements(name: "Neptune", color: .blueWhite, vRef: -6.87,
            a: 30.06992276, aR: 0.00026291, e: 0.00859048, eR: 0.00005105,
            inc: 1.77004347, incR: 0.00035372, peri: 44.96476227, periR: -0.32241464,
            node: 131.78422574, nodeR: -0.00508664, mLong: -55.12002969, mLongR: 218.45945325),
    ]

    static func projectedPlanets(date: Date, latitude: Double, longitude: Double) -> [ProjectedPlanet] {
        let jd = Ephemeris.julianDay(date)
        let T = (jd - 2451545.0) / 36525.0
        let e0 = heliocentric(earth, T)
        let eps = 23.43928 * .pi / 180                       // obliquity (J2000)
        let transform = SkyTransform(date: date, latitude: latitude, longitude: longitude)
        return planetElements.map { p in
            let h = heliocentric(p, T)
            let gx = h.x - e0.x, gy = h.y - e0.y, gz = h.z - e0.z   // geocentric ecliptic
            let delta = (gx * gx + gy * gy + gz * gz).squareRoot()
            let xeq = gx
            let yeq = gy * cos(eps) - gz * sin(eps)
            let zeq = gy * sin(eps) + gz * cos(eps)
            let raDeg = normalizeDeg(atan2(yeq, xeq) * 180 / .pi)
            let decDeg = atan2(zeq, (xeq * xeq + yeq * yeq).squareRoot()) * 180 / .pi
            let pos = horizontal(rightAscensionDeg: raDeg, declinationDeg: decDeg,
                                 transform: transform)
            let mag = p.vRef + 5 * log10(max(1e-4, h.r * delta))    // approximate
            return ProjectedPlanet(name: p.name, azimuthDeg: pos.azimuthDeg,
                                   elevationDeg: pos.elevationDeg, magnitude: mag, color: p.color)
        }
    }

    /// Heliocentric ecliptic (J2000) position + distance for a set of elements at T.
    private static func heliocentric(_ p: PlanetElements, _ T: Double) -> (x: Double, y: Double, z: Double, r: Double) {
        let a = p.a + p.aR * T
        let e = p.e + p.eR * T
        let inc = (p.inc + p.incR * T) * .pi / 180
        let peri = p.peri + p.periR * T                       // ϖ (longitude of perihelion)
        let node = (p.node + p.nodeR * T) * .pi / 180         // Ω
        let argPeri = (peri - (p.node + p.nodeR * T)) * .pi / 180   // ω = ϖ − Ω
        let m = normalizeSignedDeg(p.mLong + p.mLongR * T - peri) * .pi / 180   // mean anomaly
        var ecc = m + e * sin(m)                              // Kepler's equation
        for _ in 0..<8 { ecc -= (ecc - e * sin(ecc) - m) / (1 - e * cos(ecc)) }
        let xp = a * (cos(ecc) - e)
        let yp = a * (1 - e * e).squareRoot() * sin(ecc)
        let cw = cos(argPeri), sw = sin(argPeri)
        let cn = cos(node), sn = sin(node)
        let ci = cos(inc), si = sin(inc)
        let x = (cw * cn - sw * sn * ci) * xp + (-sw * cn - cw * sn * ci) * yp
        let y = (cw * sn + sw * cn * ci) * xp + (-sw * sn + cw * cn * ci) * yp
        let z = (sw * si) * xp + (cw * si) * yp
        return (x, y, z, (x * x + y * y + z * z).squareRoot())
    }

    static func nightVisibility(sunElevationDeg: Double) -> Double {
        if sunElevationDeg >= -4 { return 0 }
        if sunElevationDeg <= -18 { return 1 }
        let t = (-4 - sunElevationDeg) / 14
        return t * t * (3 - 2 * t)
    }

    /// Date/site-only terms of the J2000 → horizontal transform, hoisted out of
    /// the per-star loop: Julian day, the three precession polynomials, GMST and
    /// the observer's latitude trig depend only on (date, lat, lon) — yet were
    /// recomputed for each of the ~5,900 stars on every rebuild, the bulk of
    /// scrub-time CPU.
    private struct SkyTransform {
        let zeta: Double, zDeg: Double
        let sinTheta: Double, cosTheta: Double
        let gmstPlusLonDeg: Double
        let sinLat: Double, cosLat: Double

        init(date: Date, latitude: Double, longitude: Double) {
            let jd = Ephemeris.julianDay(date)
            // Precession J2000 → date (rigorous rotation, ≪1′ over ±1 century;
            // Meeus eq. 21.3/21.4 — by 2026 the sky has rotated ~0.36° since
            // J2000, a visible offset against a ridge).
            let t = (jd - 2451545.0) / 36525.0
            let zetaDeg = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) / 3600
            zDeg = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) / 3600
            let thetaDeg = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) / 3600
            zeta = zetaDeg * .pi / 180
            let theta = thetaDeg * .pi / 180
            sinTheta = sin(theta); cosTheta = cos(theta)
            gmstPlusLonDeg = normalizeDeg(280.46061837 + 360.98564736629 * (jd - 2451545.0))
                + longitude
            let lat = latitude * .pi / 180
            sinLat = sin(lat); cosLat = cos(lat)
        }
    }

    /// J2000 catalog place → apparent local horizontal coordinates, using the
    /// precomputed per-rebuild transform. Adds atmospheric refraction so stars
    /// sit where the eye sees them, consistent with the sun/moon and terrain.
    private static func horizontal(
        rightAscensionDeg: Double,
        declinationDeg: Double,
        transform tf: SkyTransform
    ) -> (azimuthDeg: Double, elevationDeg: Double) {
        let ra0 = rightAscensionDeg * .pi / 180, dec0 = declinationDeg * .pi / 180
        let A = cos(dec0) * sin(ra0 + tf.zeta)
        let B = tf.cosTheta * cos(dec0) * cos(ra0 + tf.zeta) - tf.sinTheta * sin(dec0)
        let C = tf.sinTheta * cos(dec0) * cos(ra0 + tf.zeta) + tf.cosTheta * sin(dec0)
        let raDeg = atan2(A, B) * 180 / .pi + tf.zDeg
        let dec = asin(max(-1, min(1, C)))

        let hourAngle = normalizeSignedDeg(tf.gmstPlusLonDeg - raDeg) * .pi / 180

        let elevation = asin(tf.sinLat * sin(dec) + tf.cosLat * cos(dec) * cos(hourAngle))
        let azFromSouth = atan2(
            sin(hourAngle),
            cos(hourAngle) * tf.sinLat - tan(dec) * tf.cosLat
        )
        let elDeg = elevation * 180 / .pi
        return (
            azimuthDeg: normalizeDeg(azFromSouth * 180 / .pi + 180),
            elevationDeg: elDeg + Ephemeris.refractionDeg(trueAltitudeDeg: elDeg)
        )
    }

    private static func normalizeDeg(_ value: Double) -> Double {
        var d = value.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private static func normalizeSignedDeg(_ value: Double) -> Double {
        var d = normalizeDeg(value)
        if d > 180 { d -= 360 }
        return d
    }
}
