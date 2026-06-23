import Foundation
import Compression

/// Fetches a DEM tile around a coordinate at runtime from the **AWS Open Data
/// "skadi" SRTM mirror** — public, NO API key, no account, no per-user cost
/// (`https://elevation-tiles-prod.s3.amazonaws.com/skadi/...`). This is what makes
/// the app shippable: there is no key embedded and nothing to rate-limit per user.
///
/// Skadi tiles are 1°×1° SRTM1 (~30 m, the same resolution as the old AW3D30
/// source), gzipped big-endian Int16, 3601×3601, row 0 = north, −32768 = void.
/// The box around the eye usually spans 1–4 degree tiles; we download the covering
/// tiles (keyless), stitch them into one `DEMTile` at native SRTM resolution, and
/// cache. The renderer consumes a `DEMTile` exactly as before.
enum DEMFetcher {
    enum FetchError: Error { case empty }

    private static let samplesPerDegree = 3600           // SRTM1: 3601 posts, 3600 cells
    private static let arcsec = 1.0 / 3600.0
    private static let voidSentinel: Float = -9999

    // MARK: Caches

    private final class Box { let tile: DEMTile; init(_ t: DEMTile) { tile = t } }
    private static let memoryCache = NSCache<NSString, Box>()

    /// Per-degree raw `.hgt.gz` cache (shared across overlapping boxes, survives
    /// launches → offline revisits and far fewer downloads).
    private static let hgtCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("srtm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func boxKey(lat: Double, lon: Double, radiusMeters: Double) -> String {
        String(format: "box_%.4f_%.4f_%d", lat, lon, Int(radiusMeters.rounded()))
    }

    // MARK: Fetch

    /// Build a DEM tile covering ±`radiusMeters` around (lat, lon) from skadi SRTM.
    static func fetch(lat: Double, lon: Double, radiusMeters: Double = 40_000) async throws -> DEMTile {
        let key = boxKey(lat: lat, lon: lon, radiusMeters: radiusMeters)
        if let hit = memoryCache.object(forKey: key as NSString) { return hit.tile }

        let tile = try await assemble(lat: lat, lon: lon, radiusMeters: radiusMeters)
        memoryCache.setObject(Box(tile), forKey: key as NSString)
        return tile
    }

    // MARK: Assembly

    private static func assemble(lat: Double, lon: Double, radiusMeters: Double) async throws -> DEMTile {
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(lat * .pi / 180), 0.01)
        let south = lat - radiusMeters / mLat
        let north = lat + radiusMeters / mLat
        let west = lon - radiusMeters / mLon
        let east = lon + radiusMeters / mLon

        let per = Double(samplesPerDegree)
        // Global integer arc-second indices spanning the box (col = lon, row = lat).
        let colMin = Int((west * per).rounded(.down))
        let colMax = Int((east * per).rounded(.up))
        let rowS = Int((south * per).rounded(.down))
        let rowN = Int((north * per).rounded(.up))
        let ncols = colMax - colMin + 1
        let nrows = rowN - rowS + 1
        guard ncols > 1, nrows > 1 else { throw FetchError.empty }

        // Degree tiles intersecting the box.
        let tLatMin = Int((Double(rowS) / per).rounded(.down))
        let tLatMax = Int((Double(rowN) / per).rounded(.down))
        let tLonMin = Int((Double(colMin) / per).rounded(.down))
        let tLonMax = Int((Double(colMax) / per).rounded(.down))
        var needed: [(tLat: Int, tLon: Int)] = []
        for tLat in tLatMin...tLatMax {
            for tLon in tLonMin...tLonMax { needed.append((tLat, tLon)) }
        }

        // Download the covering tiles' raw gz concurrently (keyless GETs).
        let gzData = await withTaskGroup(of: (Int, Int, Data?).self) { group -> [String: Data] in
            for t in needed {
                group.addTask { (t.tLat, t.tLon, await loadHGTData(tLat: t.tLat, tLon: t.tLon)) }
            }
            var out: [String: Data] = [:]
            for await (tLat, tLon, data) in group {
                if let data { out["\(tLat),\(tLon)"] = data }
            }
            return out
        }
        guard !gzData.isEmpty else { throw FetchError.empty }   // all ocean / unreachable

        var elevations = [Float](repeating: voidSentinel, count: ncols * nrows)
        // Decode + copy one tile at a time to cap peak memory.
        for t in needed {
            guard let gz = gzData["\(t.tLat),\(t.tLon)"], let raw = gunzip(gz) else { continue }
            let n = Int((Double(raw.count / 2)).squareRoot().rounded())
            guard n > 1, raw.count == n * n * 2 else { continue }

            let gLatLo = max(rowS, t.tLat * samplesPerDegree)
            let gLatHi = min(rowN, (t.tLat + 1) * samplesPerDegree)
            let gLonLo = max(colMin, t.tLon * samplesPerDegree)
            let gLonHi = min(colMax, (t.tLon + 1) * samplesPerDegree)
            guard gLatLo <= gLatHi, gLonLo <= gLonHi else { continue }

            raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                let samples = rawBuf.bindMemory(to: Int16.self)
                for gLat in gLatLo...gLatHi {
                    let outRow = rowN - gLat
                    let tileRow = (t.tLat + 1) * samplesPerDegree - gLat
                    let outBase = outRow * ncols
                    let tileBase = tileRow * n
                    for gLon in gLonLo...gLonHi {
                        let v = Int16(bigEndian: samples[tileBase + (gLon - t.tLon * samplesPerDegree)])
                        elevations[outBase + (gLon - colMin)] = (v == -32768) ? voidSentinel : Float(v)
                    }
                }
            }
        }

        fillVoids(&elevations, ncols: ncols, nrows: nrows)
        let maxElev = elevations.max() ?? 0
        return DEMTile(
            ncols: ncols, nrows: nrows,
            xllcorner: (Double(colMin) - 0.5) * arcsec,
            yllcorner: (Double(rowS) - 0.5) * arcsec,
            cellsize: arcsec, nodata: voidSentinel,
            elevations: elevations, maxElevation: maxElev)
    }

    /// Fill voids (and ocean-404 gaps) so they don't render as spikes/holes:
    /// nearest valid sample along the row, then any all-void rows fall back to 0.
    private static func fillVoids(_ e: inout [Float], ncols: Int, nrows: Int) {
        for r in 0..<nrows {
            let base = r * ncols
            var last: Float? = nil
            for c in 0..<ncols {           // forward fill
                if e[base + c] != voidSentinel { last = e[base + c] }
                else if let last { e[base + c] = last }
            }
            last = nil
            for c in stride(from: ncols - 1, through: 0, by: -1) {   // backward fill
                if e[base + c] != voidSentinel { last = e[base + c] }
                else if let last { e[base + c] = last }
            }
        }
        for i in e.indices where e[i] == voidSentinel { e[i] = 0 }   // sea level
    }

    // MARK: Skadi tile download (keyless)

    private static func tileName(tLat: Int, tLon: Int) -> (folder: String, name: String) {
        let ns = tLat >= 0 ? "N" : "S"
        let ew = tLon >= 0 ? "E" : "W"
        let folder = String(format: "%@%02d", ns, abs(tLat))
        let name = String(format: "%@%02d%@%03d", ns, abs(tLat), ew, abs(tLon))
        return (folder, name)
    }

    private static func loadHGTData(tLat: Int, tLon: Int) async -> Data? {
        let (folder, name) = tileName(tLat: tLat, tLon: tLon)
        let cacheURL = hgtCacheDir.appendingPathComponent("\(name).hgt.gz")
        if let cached = try? Data(contentsOf: cacheURL) { return cached }

        guard let url = URL(string:
            "https://elevation-tiles-prod.s3.amazonaws.com/skadi/\(folder)/\(name).hgt.gz") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            return nil    // 404 = ocean tile, or transient failure
        }
        try? data.write(to: cacheURL)
        return data
    }

    // MARK: gzip (Compression speaks raw deflate, not the gzip wrapper)

    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else { return nil }
        let flags = data[3]
        var offset = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 { while offset < data.count, data[offset] != 0 { offset += 1 }; offset += 1 }  // FNAME
        if flags & 0x10 != 0 { while offset < data.count, data[offset] != 0 { offset += 1 }; offset += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }   // FHCRC
        guard data.count > offset + 8 else { return nil }
        let isize = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let deflate = data.subdata(in: offset..<(data.count - 8))
        let capacity = Int(isize) + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = deflate.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, deflate.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }
}
