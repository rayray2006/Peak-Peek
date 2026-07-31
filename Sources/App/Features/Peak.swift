import Foundation

/// Peak search/label reach (meters). In RidgeLine this is `SilhouetteEngine`'s
/// label range; PeakPeek keeps the same radius for directory queries.
enum PeakSearch {
    static let maxRangeMeters: Double = 500_000
}

/// A named summit. Sourced from the bundled directory (OSM extract) and, later,
/// runtime OSM/GeoNames region packs. (Ported from RidgeLine.)
struct Peak: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double
    let prominenceMeters: Double?
    /// A saddle/gap/pass (OSM `natural=saddle`) — a LOW point between summits,
    /// not a mountain. Label anchors and "Stand here" must NOT summit-snap these
    /// (the snap would drag them uphill onto the neighboring peak).
    var isSaddle: Bool = false

    init(
        id: String, name: String, latitude: Double, longitude: Double,
        elevationMeters: Double, prominenceMeters: Double?, isSaddle: Bool = false
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.elevationMeters = elevationMeters
        self.prominenceMeters = prominenceMeters
        self.isSaddle = isSaddle
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, elevationMeters, prominenceMeters, isSaddle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        elevationMeters = try c.decodeIfPresent(Double.self, forKey: .elevationMeters) ?? 0
        prominenceMeters = try c.decodeIfPresent(Double.self, forKey: .prominenceMeters)
        isSaddle = try c.decodeIfPresent(Bool.self, forKey: .isSaddle) ?? false
    }

    /// Label priority: prominent peaks win declutter fights.
    var priority: Double { prominenceMeters ?? elevationMeters * 0.25 }

    /// The name says LOW POINT — "… Gap", "… Pass", "… Col", "Sattel" and
    /// friends. A snap guard of last resort: legacy pack/cache records lost
    /// the `isSaddle` flag, and OSM occasionally mis-tags a gap as a peak —
    /// standing on a gap must never climb the neighboring hill. Whole-word
    /// match, so "Compass Rose" doesn't trip on "pass" — and a SUMMIT word
    /// anywhere wins: "Heather Pass Peak" is the peak BESIDE Heather Pass
    /// (the saddle word is attributive), not a pass itself.
    var nameSuggestsSaddle: Bool {
        let saddleWords: Set<String> = ["gap", "pass", "saddle", "col", "notch",
                                        "joch", "sattel", "colle", "forcella",
                                        "bocchetta", "furka", "scharte"]
        let summitWords: Set<String> = ["peak", "mountain", "mount", "mt",
                                        "butte", "spire", "point", "dome",
                                        "horn", "rock", "tower", "needle",
                                        "pinnacle", "summit"]
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        guard !words.contains(where: { summitWords.contains($0) }) else { return false }
        return words.contains { saddleWords.contains($0) }
    }

    /// Order-preserving dedup across SOURCES: drops exact-id duplicates and
    /// same-name records within 200 m of an earlier one (the same feature via
    /// two catalogs — different id schemes defeat an id-only check). Callers
    /// put the most trustworthy source FIRST: the global DB carries the
    /// saddle flag, and its copy of a gap must shadow a legacy pack's
    /// flag-less one, or "Stand here" summit-snaps the eye uphill.
    nonisolated static func dedupedKeepingFirst(_ peaks: [Peak]) -> [Peak] {
        var merged: [Peak] = []
        var ids = Set<String>()
        var buckets: [String: [Peak]] = [:]

        func bucketKey(_ peak: Peak) -> String {
            let lat = Int((peak.latitude * 200).rounded())
            let lon = Int((peak.longitude * 200).rounded())
            return "\(lat):\(lon)"
        }

        for peak in peaks {
            guard ids.insert(peak.id).inserted else { continue }
            let key = bucketKey(peak)
            let duplicate = buckets[key]?.contains(where: {
                guard $0.name.localizedCaseInsensitiveCompare(peak.name) == .orderedSame else { return false }
                return GeoMath.distanceMeters(
                    fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                    toLatitude: peak.latitude, toLongitude: peak.longitude
                ) < 200
            }) ?? false
            guard !duplicate else { continue }
            merged.append(peak)
            buckets[key, default: []].append(peak)
        }
        return merged
    }

    /// Display name: a name in a non-Latin script gets a Latin transliteration
    /// appended in parens — "富士山 (Fu Shi Shan)", "Эльбрус (Elbrus)" — so
    /// labels stay readable anywhere on Earth. Latin names pass through as-is.
    var displayName: String {
        guard let latin = Self.latinized(name) else { return name }
        return "\(name) (\(latin))"
    }

    /// Offline ICU transliteration of `s` when it is written in a non-Latin
    /// script; nil when `s` is already Latin (or transliterating adds nothing).
    static func latinized(_ s: String) -> String? {
        // Quick reject — the overwhelmingly common case. Everything below
        // U+0370 (Greek onward) is Latin, punctuation, digits or combining
        // diacritics; none of those need (or survive) transliteration.
        guard s.unicodeScalars.contains(where: { $0.value >= 0x0370 }) else { return nil }
        guard var latin = s.applyingTransform(
                  StringTransform("Any-Latin; Latin-ASCII"), reverse: false)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !latin.isEmpty,
              latin.caseInsensitiveCompare(s) != .orderedSame else { return nil }
        // Han/kana readings come out all-lowercase ("fu shi shan") — title-case
        // them; scripts that carry case (Cyrillic, Greek) keep their own.
        if latin == latin.lowercased() { latin = latin.capitalized }
        return latin
    }
}

/// Loads the bundled peak directory and answers radius queries.
struct PeakStore: Sendable {
    let peaks: [Peak]

    init(peaks: [Peak]) {
        self.peaks = peaks
    }

    init(bundle: Bundle = .main, resource: String = "peaks") {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Peak].self, from: data) else {
            self.init(peaks: [])
            return
        }
        self.init(peaks: decoded)
    }

    func peaks(nearLatitude lat: Double, longitude lon: Double, withinMeters radius: Double) -> [Peak] {
        let (latDelta, lonDelta) = GeoMath.boundingDegreeDeltas(radiusMeters: radius, latitude: lat)
        return peaks.filter {
            abs($0.latitude - lat) <= latDelta && abs($0.longitude - lon) <= lonDelta
                && GeoMath.distanceMeters(
                    fromLatitude: lat, fromLongitude: lon,
                    toLatitude: $0.latitude, toLongitude: $0.longitude
                ) <= radius
        }
    }
}

/// A peak resolved against a viewpoint: its compass azimuth, apparent elevation
/// angle, and distance from the eye. (In RidgeLine this lives on
/// `SilhouetteEngine`; PeakPeek computes it directly from `GeoMath` since the
/// live raymarch view has no precomputed skyline.)
struct AnnotatedPeak: Identifiable, Equatable {
    let peak: Peak
    let azimuthDeg: Double
    let elevationAngleDeg: Double
    let distanceMeters: Double

    var id: String { peak.id }
}
