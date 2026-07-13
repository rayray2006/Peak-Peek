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

    /// Default max cells per axis in the stitched grid. A large radius would blow
    /// past device memory at native ~30 m, so we downsample (uniform arc-second
    /// stride) so neither axis exceeds this. The two-tier renderer fetches a NEAR
    /// tile with a large cap (native ~30 m) and a FAR tile with a small cap (coarse,
    /// for distant silhouettes) — see `TerrainMetalView`.
    private static let defaultMaxGrid = 4096

    // MARK: Caches

    private final class Box { let tile: DEMTile; init(_ t: DEMTile) { tile = t } }
    private static let memoryCache = NSCache<NSString, Box>()

    /// Per-degree raw `.hgt.gz` cache (shared across overlapping boxes, survives
    /// launches → offline revisits and far fewer downloads). In Caches → the OS may
    /// evict it under storage pressure.
    private static let hgtCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("srtm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Persistent store for user-DOWNLOADED offline regions. In Application Support so
    /// the OS won't evict it; checked before the cache + network so downloaded regions
    /// render with no connection. Managed by `RegionStore`.
    static let regionStoreDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("srtm-regions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Snapshot of the LAST rendered region's stitched tiles, so the app reopens
    /// instantly: on launch we reload these prebuilt `.dembin`s (a flat Float read,
    /// <1 s) and skip the network AND the ~10 s tile stitch. Application Support so
    /// the OS won't evict it; overwritten whenever a new region is fetched.
    static let lastRegionDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("last-region", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Persist the freshly stitched near/far tiers for an instant next launch.
    /// Heavy (~80 MB) but rare (only on an actual fetch, not tile reuse), off-main.
    static func saveLastRegion(near: DEMTile, far: DEMTile?) {
        let nearPath = lastRegionDir.appendingPathComponent("near.dembin").path
        let farPath = lastRegionDir.appendingPathComponent("far.dembin").path
        DispatchQueue.global(qos: .utility).async {
            try? near.saveBinary(to: nearPath)
            if let far { try? far.saveBinary(to: farPath) }
            else { try? FileManager.default.removeItem(atPath: farPath) }
        }
    }

    /// Reload the last region's tiers if present. Returns nil on a first-ever launch
    /// (nothing saved) or if the cache is unreadable — caller then fetches normally.
    static func loadLastRegion() -> (near: DEMTile, far: DEMTile?)? {
        let nearPath = lastRegionDir.appendingPathComponent("near.dembin").path
        guard let near = try? DEMTile.loadCached(binPath: nearPath) else { return nil }
        let far = try? DEMTile.loadCached(binPath: lastRegionDir.appendingPathComponent("far.dembin").path)
        return (near, far)
    }

    private static func boxKey(lat: Double, lon: Double, radiusMeters: Double) -> String {
        String(format: "box_%.4f_%.4f_%d", lat, lon, Int(radiusMeters.rounded()))
    }

    // MARK: Fetch

    /// Build a DEM tile covering ±`radiusMeters` around (lat, lon) from skadi SRTM.
    /// `onTileComplete` fires once per covering degree tile as its download settles
    /// (success or ocean/404 alike); `onTileStitched` fires once per tile as its
    /// decode + copy into the output grid finishes. Together they let callers drive
    /// a progress readout spanning the download AND the (often longer) stitch —
    /// 2 × `tileCount(...)` is the matching total.
    static func fetch(lat: Double, lon: Double, radiusMeters: Double = 120_000,
                      maxGrid: Int = defaultMaxGrid,
                      onTileComplete: (@Sendable () -> Void)? = nil,
                      onTileStitched: (@Sendable () -> Void)? = nil) async throws -> DEMTile {
        let key = boxKey(lat: lat, lon: lon, radiusMeters: radiusMeters) + "_g\(maxGrid)"
        if let hit = memoryCache.object(forKey: key as NSString) {
            // Already resident: no download or stitch, but tick both phases'
            // tiles so a combined progress counter still reaches its total.
            for _ in 0..<tileCount(lat: lat, lon: lon, radiusMeters: radiusMeters) {
                onTileComplete?()
                onTileStitched?()
            }
            return hit.tile
        }

        let tile = try await assemble(lat: lat, lon: lon, radiusMeters: radiusMeters,
                                      maxGrid: maxGrid, onTileComplete: onTileComplete,
                                      onTileStitched: onTileStitched)
        memoryCache.setObject(Box(tile), forKey: key as NSString)
        return tile
    }

    /// The 1°×1° skadi degree tiles the ±`radiusMeters` box around (lat, lon) spans.
    /// Single source of truth for both the download loop and the progress total.
    private static func neededTiles(lat: Double, lon: Double, radiusMeters: Double)
        -> [(tLat: Int, tLon: Int)] {
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(lat * .pi / 180), 0.01)
        let per = Double(samplesPerDegree)
        let colMin = Int(((lon - radiusMeters / mLon) * per).rounded(.down))
        let colMax = Int(((lon + radiusMeters / mLon) * per).rounded(.up))
        let rowS = Int(((lat - radiusMeters / mLat) * per).rounded(.down))
        let rowN = Int(((lat + radiusMeters / mLat) * per).rounded(.up))
        let tLatMin = Int((Double(rowS) / per).rounded(.down))
        let tLatMax = Int((Double(rowN) / per).rounded(.down))
        let tLonMin = Int((Double(colMin) / per).rounded(.down))
        let tLonMax = Int((Double(colMax) / per).rounded(.down))
        guard tLatMax >= tLatMin, tLonMax >= tLonMin else { return [] }
        var needed: [(tLat: Int, tLon: Int)] = []
        for tLat in tLatMin...tLatMax {
            for tLon in tLonMin...tLonMax { needed.append((tLat, tLon)) }
        }
        return needed
    }

    /// How many degree tiles a fetch of this box will cover — the denominator for a
    /// "tiles X of Y" progress readout.
    static func tileCount(lat: Double, lon: Double, radiusMeters: Double) -> Int {
        neededTiles(lat: lat, lon: lon, radiusMeters: radiusMeters).count
    }

    // MARK: Assembly

    private static func assemble(lat: Double, lon: Double, radiusMeters: Double, maxGrid: Int,
                                 onTileComplete: (@Sendable () -> Void)? = nil,
                                 onTileStitched: (@Sendable () -> Void)? = nil) async throws -> DEMTile {
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
        let ncolsNative = colMax - colMin + 1
        let nrowsNative = rowN - rowS + 1
        guard ncolsNative > 1, nrowsNative > 1 else { throw FetchError.empty }

        // Downsample stride so the output grid fits `maxGrid` on each axis. stride 1
        // = native ~30 m (small radii); a large far-field radius coarsens uniformly
        // to stay memory-bounded. Output cell (c,r) samples the global arc-second
        // index (colMin + c*stride, rowN - r*stride).
        let stride = max(1, Int(ceil(Double(max(ncolsNative, nrowsNative)) / Double(maxGrid))))
        let ncols = (ncolsNative - 1) / stride + 1
        let nrows = (nrowsNative - 1) / stride + 1

        // Degree tiles intersecting the box (same enumeration `tileCount` divides by).
        let needed = neededTiles(lat: lat, lon: lon, radiusMeters: radiusMeters)

        // Download the covering tiles' raw gz concurrently (keyless GETs), ticking
        // progress as each settles.
        let gzData = await withTaskGroup(of: (Int, Int, Data?).self) { group -> [String: Data] in
            for t in needed {
                group.addTask { (t.tLat, t.tLon, await loadHGTData(tLat: t.tLat, tLon: t.tLon)) }
            }
            var out: [String: Data] = [:]
            for await (tLat, tLon, data) in group {
                if let data { out["\(tLat),\(tLon)"] = data }
                onTileComplete?()
            }
            return out
        }
        guard !gzData.isEmpty else { throw FetchError.empty }   // all ocean / unreachable

        var elevations = [Float](repeating: voidSentinel, count: ncols * nrows)
        // Decode + copy the tiles CONCURRENTLY — with downloads usually disk-cache
        // hits, this is the long pole of a load, and each tile's work is
        // independent. Tiles write disjoint output cells except SRTM's shared edge
        // posts, where any two writers store the IDENTICAL value (degree tiles
        // duplicate their boundary posts) and aligned 4-byte stores can't tear —
        // so the overlap is benign.
        elevations.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: needed.count) { i in
                let t = needed[i]
                // Every tile ticks the stitch phase — including ocean/missing ones
                // the guards skip — so the progress total stays exactly 2 × tileCount.
                defer { onTileStitched?() }
                guard let gz = gzData["\(t.tLat),\(t.tLon)"],
                      let raw = decodedTile(tLat: t.tLat, tLon: t.tLon, gz: gz) else { return }
                let n = Int((Double(raw.count / 2)).squareRoot().rounded())
                guard n > 1, raw.count == n * n * 2 else { return }

                let gLatLo = max(rowS, t.tLat * samplesPerDegree)
                let gLatHi = min(rowN, (t.tLat + 1) * samplesPerDegree)
                let gLonLo = max(colMin, t.tLon * samplesPerDegree)
                let gLonHi = min(colMax, (t.tLon + 1) * samplesPerDegree)
                guard gLatLo <= gLatHi, gLonLo <= gLonHi else { return }

                // Output rows/cols whose strided global index lands in this tile.
                let rLo = max(0, Int(ceil(Double(rowN - gLatHi) / Double(stride))))
                let rHi = min(nrows - 1, (rowN - gLatLo) / stride)
                let cLo = max(0, Int(ceil(Double(gLonLo - colMin) / Double(stride))))
                let cHi = min(ncols - 1, (gLonHi - colMin) / stride)
                guard rLo <= rHi, cLo <= cHi else { return }
                let tLonBase = t.tLon * samplesPerDegree

                raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                    let samples = rawBuf.bindMemory(to: Int16.self)
                    for r in rLo...rHi {
                        let gLat = rowN - r * stride
                        let tileRow = (t.tLat + 1) * samplesPerDegree - gLat
                        let outBase = r * ncols
                        let tileBase = tileRow * n
                        for c in cLo...cHi {
                            let gLon = colMin + c * stride
                            let v = Int16(bigEndian: samples[tileBase + (gLon - tLonBase)])
                            out[outBase + c] = (v == -32768) ? voidSentinel : Float(v)
                        }
                    }
                }
            }
        }

        fillVoids(&elevations, ncols: ncols, nrows: nrows)
        let maxElev = elevations.max() ?? 0
        return DEMTile(
            ncols: ncols, nrows: nrows,
            xllcorner: (Double(colMin) - 0.5 * Double(stride)) * arcsec,
            yllcorner: (Double(rowN) - (Double(nrows) - 0.5) * Double(stride)) * arcsec,
            cellsize: arcsec * Double(stride), nodata: voidSentinel,
            elevations: elevations, maxElevation: maxElev)
    }

    /// Gunzipped degree tiles (~26 MB each decoded), shared between the near/far
    /// tiers — which otherwise each decompress the SAME overlapping tiles — and
    /// kept for later re-stitches when the viewpoint moves within the stored
    /// tiles. NSCache evicts under memory pressure; the cost limit keeps roughly
    /// one far-tier footprint resident.
    private static let decodedCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 320 * 1024 * 1024
        return cache
    }()

    private static func decodedTile(tLat: Int, tLon: Int, gz: Data) -> Data? {
        let key = "\(tLat),\(tLon)" as NSString
        if let hit = decodedCache.object(forKey: key) { return hit as Data }
        guard let raw = gunzip(gz) else { return nil }
        decodedCache.setObject(raw as NSData, forKey: key, cost: raw.count)
        return raw
    }

    /// Fill voids (and ocean-404 gaps) so they don't render as spikes/holes:
    /// nearest valid sample along the row, then any all-void rows fall back to 0.
    /// Rows are independent, so they fill concurrently (this pass touches every
    /// cell of a grid that can reach 9000², too slow single-threaded).
    private static func fillVoids(_ e: inout [Float], ncols: Int, nrows: Int) {
        e.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: nrows) { r in
                let base = r * ncols
                var last: Float? = nil
                for c in 0..<ncols {           // forward fill
                    if buf[base + c] != voidSentinel { last = buf[base + c] }
                    else if let last { buf[base + c] = last }
                }
                if last == nil {               // all-void row: sea level
                    for c in 0..<ncols { buf[base + c] = 0 }
                    return
                }
                last = nil
                for c in stride(from: ncols - 1, through: 0, by: -1) {   // backward fill
                    if buf[base + c] != voidSentinel { last = buf[base + c] }
                    else if let last { buf[base + c] = last }
                }
            }
        }
    }

    // MARK: Skadi tile download (keyless)

    private static func tileName(tLat: Int, tLon: Int) -> (folder: String, name: String) {
        // Wrap across the antimeridian (skadi names run W180…E179): a stitch box
        // near ±180° yields indices like −181 (= E179) or +180 (= W180). Only the
        // NAME wraps — the caller's arc-second column math stays in its own
        // continuous unwrapped domain, so stitching across the seam still works.
        let lonW = ((tLon + 180) % 360 + 360) % 360 - 180
        let ns = tLat >= 0 ? "N" : "S"
        let ew = lonW >= 0 ? "E" : "W"
        let folder = String(format: "%@%02d", ns, abs(tLat))
        let name = String(format: "%@%02d%@%03d", ns, abs(tLat), ew, abs(lonW))
        return (folder, name)
    }

    /// In-flight download dedup. The near and far tiers fetch IN PARALLEL and
    /// share their central tiles; the disk cache alone can't help there — both
    /// tiers ask before either has written — so the same ~10 MB tile downloaded
    /// twice on every cold region (~a third of the first-launch bytes). One
    /// task per tile name; concurrent requesters await the same task.
    private actor InflightDownloads {
        private var tasks: [String: Task<Data?, Never>] = [:]

        func data(for name: String, download: @escaping @Sendable () async -> Data?) async -> Data? {
            if let running = tasks[name] { return await running.value }
            let task = Task { await download() }
            tasks[name] = task
            let result = await task.value
            tasks[name] = nil
            return result
        }
    }
    private static let inflight = InflightDownloads()

    private static func loadHGTData(tLat: Int, tLon: Int) async -> Data? {
        let (folder, name) = tileName(tLat: tLat, tLon: tLon)
        // Downloaded offline regions first (persistent), then the runtime cache.
        if let d = try? Data(contentsOf: regionStoreDir.appendingPathComponent("\(name).hgt.gz")) { return d }
        let cacheURL = hgtCacheDir.appendingPathComponent("\(name).hgt.gz")
        if let cached = try? Data(contentsOf: cacheURL) { return cached }

        return await inflight.data(for: name) {
            // Re-check inside the deduped task: a racing caller may have finished
            // (and written the cache) between our miss above and getting here.
            if let cached = try? Data(contentsOf: cacheURL) { return cached }
            guard let url = URL(string:
                "https://elevation-tiles-prod.s3.amazonaws.com/skadi/\(folder)/\(name).hgt.gz") else { return nil }
            NSLog("DEM tile download: %@", name)
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                return nil    // 404 = ocean tile, or transient failure
            }
            try? data.write(to: cacheURL)
            return data
        }
    }

    // MARK: Offline region download (persistent tile store)

    /// The 1°×1° SRTM tiles covering a lat/lon bounding box (for map area selection).
    static func regionTiles(south: Double, north: Double, west: Double, east: Double) -> [(tLat: Int, tLon: Int)] {
        let s = min(south, north), n = max(south, north)
        let w = min(west, east), e = max(west, east)
        var out: [(Int, Int)] = []
        for la in Int(floor(s))...Int(floor(n)) {
            for lo in Int(floor(w))...Int(floor(e)) { out.append((la, lo)) }
        }
        return out
    }

    static func tileFileName(tLat: Int, tLon: Int) -> String { tileName(tLat: tLat, tLon: tLon).name }

    /// Ensure a tile is in the persistent region store. Returns bytes stored (0 = an
    /// ocean/void tile that 404s — nothing to keep but still "done"), or nil on a
    /// transient failure (caller can retry). Promotes from the runtime cache if present.
    static func ensurePersistentTile(tLat: Int, tLon: Int) async -> Int? {
        let (folder, name) = tileName(tLat: tLat, tLon: tLon)
        let dest = regionStoreDir.appendingPathComponent("\(name).hgt.gz")
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int {
            return size                                   // already downloaded
        }
        if let data = try? Data(contentsOf: hgtCacheDir.appendingPathComponent("\(name).hgt.gz")) {
            try? data.write(to: dest); return data.count  // promote from runtime cache
        }
        guard let url = URL(string:
            "https://elevation-tiles-prod.s3.amazonaws.com/skadi/\(folder)/\(name).hgt.gz") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 60
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return 0 }                       // ocean tile — nothing to store
        guard code == 200, !data.isEmpty else { return nil }
        try? data.write(to: dest)
        return data.count
    }

    /// Remove a downloaded tile from the persistent store (caller handles sharing).
    static func deletePersistentTile(name: String) {
        try? FileManager.default.removeItem(at: regionStoreDir.appendingPathComponent("\(name).hgt.gz"))
    }

    /// Total bytes currently used by the persistent region store.
    static func downloadedBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: regionStoreDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
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
