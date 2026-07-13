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
        let latDelta = radius / 111_000
        let lonDelta = radius / (111_000 * max(cos(lat * .pi / 180), 0.001))
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
