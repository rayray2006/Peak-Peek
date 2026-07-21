import Foundation

/// Pure geometry shared by the viewpoint model and peak annotation.
/// (Ported from RidgeLine.)
enum GeoMath {
    static let earthRadiusMeters: Double = 6_371_000

    /// Standard atmospheric refraction coefficient k ≈ 0.13: light bends down,
    /// recovering ~13% of the curvature drop. THE one home for the constant —
    /// the horizon march, label anchors, far-horizon ring and shader curvature
    /// must all agree, or distant peaks and their labels drift apart.
    /// (Camera.swift in Sources/Terrain carries a LOCK-STEP twin: it also
    /// builds in the ReliefRender target, which doesn't compile this file.)
    static let refractionCoefficient = 0.13

    /// Earth-curvature drop (meters) at `distance`, including the standard
    /// atmospheric-refraction factor — the correction PeakFinder applies so
    /// 200 km giants appear exactly as high as they really look.
    static func curvatureDrop(distanceMeters d: Double) -> Double {
        (1 - refractionCoefficient) * d * d / (2 * earthRadiusMeters)
    }

    /// Bounding-box half-extents in degrees for a radius at a latitude — the
    /// cheap prefilter used before exact haversine checks.
    static func boundingDegreeDeltas(radiusMeters: Double, latitude: Double)
        -> (lat: Double, lon: Double) {
        let latDelta = radiusMeters / 111_000
        let lonDelta = radiusMeters / (111_000 * max(cos(latitude * .pi / 180), 0.001))
        return (latDelta, lonDelta)
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

    /// Destination point `distanceMeters` along the initial compass `bearingRad` —
    /// exact spherical geodesic. The old equirectangular shortcut (fixed 111,000
    /// m/deg, no meridian convergence along the path) drifted ~0.3–0.5° off the
    /// true sightline at 120 km, so the horizon profile it fed disagreed with both
    /// the real skyline and the (meridian-corrected) renderer.
    static func destination(
        latitude: Double, longitude: Double, bearingRad: Double, distanceMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let d = distanceMeters / earthRadiusMeters
        let lat1 = latitude * .pi / 180
        let sinLat2 = sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(bearingRad)
        let lat2 = asin(max(-1, min(1, sinLat2)))
        let dLon = atan2(sin(bearingRad) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sinLat2)
        return (lat2 * 180 / .pi, longitude + dLon * 180 / .pi)
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
