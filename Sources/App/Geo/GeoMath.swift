import Foundation

/// Pure geometry shared by the viewpoint model and peak annotation.
/// (Ported from RidgeLine.)
enum GeoMath {
    static let earthRadiusMeters: Double = 6_371_000

    /// Earth-curvature drop (meters) at `distance`, including the standard 0.87
    /// atmospheric-refraction factor (light bends down, recovering ~13% of the drop)
    /// — the correction PeakFinder applies so 200 km giants appear exactly as high
    /// as they really look.
    static func curvatureDrop(distanceMeters d: Double) -> Double {
        0.87 * d * d / (2 * earthRadiusMeters)
    }

    /// Apparent rise (meters) of a terrain point above the eye's horizontal,
    /// with optional vertical exaggeration. `exaggeration == 1` is true geometry;
    /// higher values amplify the terrain's rise/fall ABOUT THE EYE while the earth
    /// still curves away realistically (curvature is subtracted after scaling, not
    /// exaggerated). `atan2(apparentRise, distance)` is then the elevation angle.
    static func apparentRise(
        groundMeters ground: Double, eyeMeters eye: Double,
        distanceMeters d: Double, exaggeration: Double = 1
    ) -> Double {
        (ground - eye) * exaggeration - curvatureDrop(distanceMeters: d)
    }

    /// Fast local destination point: `distanceMeters` along compass `bearingRad`.
    /// Equirectangular — exact enough for a 300 km march (error ≪ one DEM cell).
    static func destination(
        latitude: Double, longitude: Double, bearingRad: Double, distanceMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let dNorth = distanceMeters * cos(bearingRad)
        let dEast = distanceMeters * sin(bearingRad)
        let lat = latitude + dNorth / 111_000.0
        let lon = longitude + dEast / (111_000.0 * max(cos(latitude * .pi / 180), 0.001))
        return (lat, lon)
    }

    /// Initial compass bearing (radians, 0 = north, clockwise) between coordinates.
    static func bearingRad(
        fromLatitude lat1d: Double, fromLongitude lon1d: Double,
        toLatitude lat2d: Double, toLongitude lon2d: Double
    ) -> Double {
        let lat1 = lat1d * .pi / 180, lat2 = lat2d * .pi / 180
        let dLon = (lon2d - lon1d) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let b = atan2(y, x)
        return b < 0 ? b + 2 * .pi : b
    }

    /// Great-circle distance in meters (haversine).
    static func distanceMeters(
        fromLatitude lat1d: Double, fromLongitude lon1d: Double,
        toLatitude lat2d: Double, toLongitude lon2d: Double
    ) -> Double {
        let lat1 = lat1d * .pi / 180, lat2 = lat2d * .pi / 180
        let dLat = (lat2d - lat1d) * .pi / 180
        let dLon = (lon2d - lon1d) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, h.squareRoot()))
    }
}
