import Foundation
import simd

/// The far-horizon ring: silhouettes of terrain BEYOND the raymarched tiers.
///
/// Past ~120 km terrain has no visible parallax or relief detail — a distant
/// giant is one elevation angle per azimuth, a 1D signal. So instead of
/// hauling more DEM tiles, a bundled 5-arc-minute global relief grid (~18 MB,
/// max-pooled ETOPO1 — see Tools/HorizonDEM) is marched ONCE per viewpoint,
/// CPU-side, from the far-tier edge out to the curvature limit. The result is
/// a per-azimuth (tan elevation, distance) profile that the BAKE composites as
/// a pale haze silhouette with real depth — so every view mode, the edges
/// Sobel, and the label occlusion tests all inherit distant mountains for the
/// cost of one 1D texture.
enum FarHorizon {
    /// Azimuth bins in the profile (matches the pano width granularity the
    /// skyline needs; ~0.09°/bin).
    static let bins = 4096
    /// March span: from just inside the far-tier edge (overlap hides the seam)
    /// to the practical visibility limit for terrestrial giants.
    static let startMeters = 110_000.0
    static let endMeters = 600_000.0
    private static let stepMeters = 4_000.0
    /// "Nothing visible" tan-elevation: below any real ring angle, but close
    /// enough that the texture's LINEAR filtering doesn't notch silhouette
    /// edges the way a -10 sentinel would.
    static let emptyTanEl: Float = -0.2
    /// Effective Earth radius with standard atmospheric refraction (4/3 R) —
    /// the same k≈0.13 convention as GeoMath.apparentRise uses for peaks.
    private static let effectiveRadius = 6_371_000.0 / (1.0 - 0.13)

    struct Profile {
        /// Per azimuth bin (0 = north, clockwise): tan(elevation angle) of the
        /// highest beyond-tier terrain, and its distance in meters. Bins with
        /// nothing visible hold (emptyTanEl, 0).
        var tanEl: [Float]
        var distance: [Float]
    }

    private struct Grid {
        let cols: Int, rows: Int, cellDeg: Double
        let data: Data          // int16 LE, row 0 = lat +90, col 0 = lon −180

        /// Bilinear over the 5' cells — nearest-cell lookups staircased the
        /// silhouette into visible ~2° steps at ring distances.
        func elevation(lat: Double, lon: Double) -> Float {
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
                let v = data.withUnsafeBytes { buf -> Int16 in
                    buf.loadUnaligned(fromByteOffset: (r * cols + c) * 2, as: Int16.self)
                }
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
        return Grid(cols: cols, rows: rows, cellDeg: cell, data: data.advanced(by: 20))
    }()

    static var isAvailable: Bool { grid != nil }

    /// March the coarse grid over the full circle. ~500k lookups; run OFF the
    /// main thread (a few ms in release builds).
    static func profile(latitude: Double, longitude: Double, eyeElevation: Double) -> Profile? {
        guard let grid else { return nil }
        var tanEl = [Float](repeating: emptyTanEl, count: bins)
        var dist = [Float](repeating: 0, count: bins)
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(latitude * .pi / 180), 0.01)
        for b in 0..<bins {
            let az = Double(b) / Double(bins) * 2 * .pi
            let dirN = cos(az), dirE = sin(az)
            var best = -10.0
            var bestD = 0.0
            var d = startMeters
            while d <= endMeters {
                let lat = latitude + dirN * d / mLat
                let lon = longitude + dirE * d / mLon
                let h = Double(grid.elevation(lat: lat, lon: lon))
                if h > 0 {
                    // Apparent elevation with curvature (+ refraction) drop —
                    // matches the renderer's convention for distant terrain.
                    let t = (h - eyeElevation - d * d / (2 * effectiveRadius)) / d
                    if t > best { best = t; bestD = d }
                }
                d += stepMeters
            }
            if best > -10 {
                tanEl[b] = Float(best)
                dist[b] = Float(bestD)
            }
        }
        return Profile(tanEl: tanEl, distance: dist)
    }
}
