import simd

/// Builds the per-frame `Uniforms` for a fixed-viewpoint panorama camera.
///
/// The world frame is local ENU (east-north-up) in meters, with the origin
/// at the DEM grid's reference point. The camera sits at a fixed position and
/// only rotates (azimuth + pitch), matching the PeakVisor "look around from
/// here" interaction.
struct PanoramaCamera {
    /// Camera position in ENU meters (x=east, y=north, z=up = elevation).
    var position: SIMD3<Float>
    /// Compass heading the camera looks toward, in degrees (0=N, 90=E, 180=S, 270=W).
    var azimuthDegrees: Float
    /// Pitch in degrees (positive = looking up, negative = looking down).
    var pitchDegrees: Float
    /// Vertical field of view in degrees.
    var verticalFovDegrees: Float

    /// Half-height of the baked 360° panorama's vertical band, in degrees.
    var panoElevMaxDegrees: Float = 60

    /// Direction towards the sun (ENU). Default: afternoon sun from the SW, fairly high.
    var sunDirection: SIMD3<Float> = normalize(SIMD3<Float>(-0.5, -0.35, 0.8))

    var maxDistance: Float = 80_000
    var heightScale: Float = 1

    /// Earth radius (m) used for curvature drop.
    var earthRadius: Float = 6_371_000
    /// Standard atmospheric refraction coefficient (~0.13 lifts distant terrain).
    var refractionCoefficient: Float = 0.13

    func makeUniforms(width: Int, height: Int) -> Uniforms {
        var u = Uniforms()

        // Forward vector from azimuth (clockwise from north) + pitch.
        // ENU: north = +y, east = +x, up = +z.
        let az = azimuthDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let cp = cosf(pitch)
        let forward = SIMD3<Float>(sinf(az) * cp,   // east component
                                   cosf(az) * cp,   // north component
                                   sinf(pitch))     // up component
        let worldUp = SIMD3<Float>(0, 0, 1)
        var right = simd_cross(forward, worldUp)
        // Guard against looking straight up/down.
        if simd_length(right) < 1e-4 {
            right = SIMD3<Float>(1, 0, 0)
        }
        right = normalize(right)
        let camUp = normalize(simd_cross(right, forward))

        u.cameraPos = SIMD4<Float>(position, 0)
        u.forward = SIMD4<Float>(normalize(forward), 0)
        u.right = SIMD4<Float>(right, 0)
        u.up = SIMD4<Float>(camUp, 0)
        u.sunDir = SIMD4<Float>(normalize(sunDirection), 0)

        u.resolution = SIMD2<Float>(Float(width), Float(height))
        u.tanHalfFovY = tanf((verticalFovDegrees * .pi / 180) / 2)
        u.aspect = Float(width) / Float(height)

        u.maxDistance = maxDistance
        let effectiveRadius = earthRadius / (1 - refractionCoefficient)
        u.curvatureK = 1 / (2 * effectiveRadius)
        u.heightScale = heightScale
        u.time = 0
        u.panoElevMax = panoElevMaxDegrees * .pi / 180

        return u
    }
}
