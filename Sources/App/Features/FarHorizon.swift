import Foundation
import simd

/// The far-horizon ring: silhouettes of terrain BEYOND the raymarched tiers.
///
/// Past the far tier terrain has no visible parallax or relief detail — a
/// distant giant is one elevation angle per azimuth, a 1D signal. So instead
/// of hauling more DEM tiles, a bundled 3-arc-minute global relief grid
/// (~52 MB, max-pooled ETOPO1 — see Tools/HorizonDEM) is marched ONCE per
/// viewpoint, CPU-side, from the far-tier edge out to the curvature limit.
/// The result is a per-azimuth (tan elevation, distance) profile that the
/// BAKE composites as a pale haze silhouette with real depth — so every view
/// mode and the edges Sobel inherit distant mountains for the cost of one 1D
/// texture. Ring terrain is deliberately UNLABELED: the label pipeline treats
/// it as sky.
enum FarHorizon {
    /// The raymarched FAR TILE's radius — real DEM terrain renders out to
    /// here; the hazy ring takes over beyond. The single source of truth:
    /// the tile fetch, the ring march start, the visibility verdict's far
    /// tier and the label-candidate radius all key off it.
    static let farTileMeters = 160_000.0
    /// Azimuth bins in the profile (matches the pano width granularity the
    /// skyline needs; ~0.09°/bin).
    static let bins = 4096
    /// March span: from just inside the far-tier edge (overlap hides the seam)
    /// to the practical visibility limit for terrestrial giants.
    static let startMeters = farTileMeters - 10_000
    static let endMeters = 600_000.0

    /// Could this feature plausibly be SEEN at this distance, in the hazy ring
    /// band? Perceptibility = its PROMINENCE (height above its own
    /// surroundings — what actually sticks up at the horizon) subtending at
    /// least ~0.15° of apparent height. Rainier (4 km prominence) passes from
    /// anywhere in the band; a foothill does not, however high its absolute
    /// elevation. Features that fail are neither badged nor anchored out
    /// there — the coarse ring data couldn't vouch for them anyway.
    static func perceptible(prominenceMeters: Double?, elevationMeters: Double,
                            distanceMeters: Double) -> Bool {
        // Unknown prominence: the same conservative elevation-based proxy the
        // label declutter uses.
        let prom = prominenceMeters ?? elevationMeters * 0.25
        return prom >= distanceMeters * 0.0026   // tan(~0.15°)
    }
    /// Kept sub-cell for the 3' grid (lon cells ≈ 3.8 km at 47° N) so a one-cell
    /// ridge crest between samples can't be stepped over; ~800k lookups per
    /// profile, still a few ms off-main.
    private static let stepMeters = 2_500.0
    /// "Nothing visible" tan-elevation: below any real ring angle, but close
    /// enough that the texture's LINEAR filtering doesn't notch silhouette
    /// edges the way a -10 sentinel would.
    static let emptyTanEl: Float = -0.2
    /// The 2D strip: rows span tan(elevation) in [-stripTanMax, +stripTanMax]
    /// (row 0 = top). Each texel holds the nearest beyond-tier hit distance in
    /// KM (0 = sky), so the bake renders LAYERED far ranges with depth-graded
    /// haze instead of one flat cutout. +-0.08 covers the horizon band even
    /// from an Everest-height eye (dip ~-0.05). 320 rows ≈ 0.029°/row — under
    /// a device pixel even at max (4.4x) zoom, so the layer boundaries don't
    /// quantize visibly when pinched in.
    static let stripRows = 320
    static let stripTanMax: Float = 0.08
    /// Effective Earth radius with standard atmospheric refraction — the same
    /// k≈0.13 convention as GeoMath.apparentRise uses for peaks (drop =
    /// d²/(2·R/(1−k)) ≡ (1−k)·d²/(2R), i.e. GeoMath.curvatureDrop).
    private static let effectiveRadius =
        GeoMath.earthRadiusMeters / (1.0 - GeoMath.refractionCoefficient)

    struct Profile {
        /// Per azimuth bin (0 = north, clockwise): tan(elevation angle) of the
        /// highest beyond-tier terrain, and its distance in meters. Bins with
        /// nothing visible hold (emptyTanEl, 0).
        var tanEl: [Float]
        var distance: [Float]
        /// stripRows x bins, row-major (row 0 = top): nearest hit distance, km.
        var strip: [Float16]
    }

    private struct Grid {
        let cols: Int, rows: Int, cellDeg: Double
        /// The FULL mapped file — sliced views like `advanced(by:)` materialize a
        /// heap copy of the ~52 MB grid, defeating the mapping; instead the header
        /// is skipped by `dataStart` in the byte offsets below.
        let data: Data          // int16 LE, row 0 = lat +90, col 0 = lon −180
        let dataStart: Int

        /// Bilinear over the 3' cells — nearest-cell lookups staircased the
        /// silhouette into visible ~2° steps at ring distances. Takes the file's
        /// bytes as a pointer so the march loop enters `withUnsafeBytes` once,
        /// not once per texel (~2M closure entries per profile build).
        func elevation(lat: Double, lon: Double, buf: UnsafeRawBufferPointer) -> Float {
            var l = lon
            if l < -180 { l += 360 } else if l >= 180 { l -= 360 }
            let rf = (90 - lat) / cellDeg - 0.5
            let cf = (l + 180) / cellDeg - 0.5
            let r0 = min(rows - 1, max(0, Int(rf.rounded(.down))))
            let c0 = min(cols - 1, max(0, Int(cf.rounded(.down))))
            let r1 = min(rows - 1, r0 + 1), c1 = min(cols - 1, c0 + 1)
            let fr = Float(max(0, min(1, rf - rf.rounded(.down))))
            let fc = Float(max(0, min(1, cf - cf.rounded(.down))))
            func at(_ r: Int, _ c: Int) -> Float {
                let v = buf.loadUnaligned(fromByteOffset: dataStart + (r * cols + c) * 2, as: Int16.self)
                return Float(Int16(littleEndian: v))
            }
            let top = at(r0, c0) * (1 - fc) + at(r0, c1) * fc
            let bot = at(r1, c0) * (1 - fc) + at(r1, c1) * fc
            return top * (1 - fr) + bot * fr
        }
    }

    private static let grid: Grid? = {
        guard let url = Bundle.main.url(forResource: "horizon_global", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 16, data.prefix(4) == Data("PPHZ".utf8) else { return nil }
        let cols = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        let rows = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) }
        let cell = data.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: 16, as: Float.self)) }
        guard data.count >= 20 + rows * cols * 2, cell > 0 else { return nil }
        return Grid(cols: cols, rows: rows, cellDeg: cell, data: data, dataStart: 20)
    }()

    static var isAvailable: Bool { grid != nil }

    /// March the coarse grid over the full circle. ~800k lookups; run OFF the
    /// main thread (a few ms in release builds).
    static func profile(latitude: Double, longitude: Double, eyeElevation: Double) -> Profile? {
        guard let grid else { return nil }
        var tanEl = [Float](repeating: emptyTanEl, count: bins)
        var dist = [Float](repeating: 0, count: bins)
        var strip = [Float16](repeating: 0, count: stripRows * bins)
        let tanMax = stripTanMax, tanSpan = 2 * stripTanMax
        func rowFor(_ t: Float) -> Int {
            max(0, min(stripRows - 1, Int((tanMax - t) / tanSpan * Float(stripRows - 1))))
        }
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(latitude * .pi / 180), 0.01)
        grid.data.withUnsafeBytes { gridBuf in
        for b in 0..<bins {
            let az = Double(b) / Double(bins) * 2 * .pi
            let dirN = cos(az), dirE = sin(az)
            var best = -10.0
            var bestD = 0.0
            // Rising-envelope fill: rows between the previous envelope top and
            // this sample's angle get THIS sample's distance — the nearest
            // range to crest each elevation wins, which is exactly parallax.
            var envTan = -tanMax
            var d = startMeters
            while d <= endMeters {
                let lat = latitude + dirN * d / mLat
                let lon = longitude + dirE * d / mLon
                let h = Double(grid.elevation(lat: lat, lon: lon, buf: gridBuf))
                if h > 0 {
                    // Apparent elevation with curvature (+ refraction) drop —
                    // matches the renderer's convention for distant terrain.
                    let t = (h - eyeElevation - d * d / (2 * effectiveRadius)) / d
                    if t > best { best = t; bestD = d }
                    let tf = Float(t)
                    if tf > envTan {
                        let top = rowFor(min(tf, tanMax))
                        let bottom = rowFor(envTan)
                        if top <= bottom {
                            let dk = Float16(d / 1000)
                            for r in top...bottom where strip[r * bins + b] == 0 {
                                strip[r * bins + b] = dk
                            }
                        }
                        envTan = min(tf, tanMax)
                    }
                }
                d += stepMeters
            }
            if best > -10 {
                tanEl[b] = Float(best)
                dist[b] = Float(bestD)
            }
        }
        }
        return Profile(tanEl: tanEl, distance: dist, strip: strip)
    }
}
