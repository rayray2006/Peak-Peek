import Foundation
import Compression

/// Fetches a DEM tile around a coordinate at runtime from the **AWS Open Data
/// "skadi" SRTM mirror** — public, NO API key, no account, no per-user cost
/// (`https://elevation-tiles-prod.s3.amazonaws.com/skadi/...`). This is what makes
/// the app shippable: there is no key embedded and nothing to rate-limit per user.
///
/// Skadi tiles are 1°×1° SRTM1 (~30 m, the same resolution as the old AW3D30
/// source), gzipped big-endian Int16, 3601×3601, row 0 = north, −32768 = void.
/// Above 60°N / below 56°S — where SRTM never flew, and skadi falls back to
/// national sources where they exist (Norway is fine) but ~250 m GMTED where
/// they don't (Iceland rendered as melted blobs) — tiles come from the
/// (equally keyless) Copernicus GLO-30 bucket instead, converted into the
/// identical format at the download boundary; see `CopernicusDEM`.
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
    private static let memoryCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // Stitched tiles reach 4096² × 4 B = 64 MB each; without a cost limit a
        // few viewpoint moves could pin hundreds of MB until the OS forces
        // eviction. Two near+far pairs' worth is plenty.
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Per-tile download outcome. Distinguishing a confirmed-ocean 404 from a
    /// transient failure (offline, timeout, 5xx) is what keeps a Wi-Fi hiccup
    /// from being stitched as sea level and then cached/persisted as if real.
    private enum TileLoad: Sendable {
        case data(Data)          // real tile bytes (network or disk cache)
        case decoded(Data)       // decoded-cache hit — no gz needed at all
        case ocean               // 404: genuinely no land here
        case failed              // transient: retryable, NOT flat ocean
        case stale(Data)         // offline, only a pre-Copernicus coarse tile
                                 // on disk: render it, but count as a failure
                                 // so nothing caches/persists it as real
    }

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
    /// Deferred a few seconds: it used to kick off right as the new scene swapped
    /// in, adding disk + allocation churn to the first second of panning it. An
    /// app killed inside the window just refetches next launch — same as before
    /// the snapshot existed.
    /// Serial home for snapshot writes: chained fetches inside the defer window
    /// must not interleave their near/far file pairs.
    private static let snapshotQueue = DispatchQueue(
        label: "com.peakpeek.demsnapshot", qos: .utility)

    /// Marker written alongside the snapshot since the Copernicus supplement
    /// shipped. A HIGH-LATITUDE snapshot without it was stitched from the
    /// coarse pre-supplement skadi tiles and is ignored once (the normal
    /// fetch that follows rebuilds it from Copernicus and stamps the marker).
    private static var snapshotSourcesMarker: URL {
        lastRegionDir.appendingPathComponent("sources-copernicus")
    }

    static func saveLastRegion(near: DEMTile, far: DEMTile?) {
        let nearPath = lastRegionDir.appendingPathComponent("near.dembin").path
        let farPath = lastRegionDir.appendingPathComponent("far.dembin").path
        snapshotQueue.asyncAfter(deadline: .now() + 4) {
            try? near.saveBinary(to: nearPath)
            if let far { try? far.saveBinary(to: farPath) }
            else { try? FileManager.default.removeItem(atPath: farPath) }
            try? Data().write(to: snapshotSourcesMarker)
        }
    }

    /// Reload the last region's tiers if present. Returns nil on a first-ever launch
    /// (nothing saved) or if the cache is unreadable — caller then fetches normally.
    /// Tiles are re-run through the full sanitize pass (range gate + spike filter):
    /// snapshots saved before either filter existed persist the artifacts, and
    /// healing on load (~ms) keeps the instant launch path instead of invalidating
    /// it. No-op for clean tiles — which is every tile saved after the filters
    /// shipped.
    static func loadLastRegion() -> (near: DEMTile, far: DEMTile?)? {
        let nearPath = lastRegionDir.appendingPathComponent("near.dembin").path
        guard let near = try? DEMTile.loadCached(binPath: nearPath) else { return nil }
        // A high-latitude snapshot from before the Copernicus supplement is
        // built from ~250 m terrain — skip it so launch takes the fetch path.
        let north = near.yllcorner + Double(near.nrows) * near.cellsize
        if north >= 60 || near.yllcorner <= -56,
           !FileManager.default.fileExists(atPath: snapshotSourcesMarker.path) {
            NSLog("DEM snapshot predates Copernicus supplement at high latitude — refetching")
            return nil
        }
        let far = try? DEMTile.loadCached(binPath: lastRegionDir.appendingPathComponent("far.dembin").path)
        return (sanitized(near), far.map(sanitized))
    }

    /// `sanitize` applied to an already-stitched tile (the last-region fast path).
    /// Returns the tile unchanged when nothing was fixed; else rebuilds it so
    /// `maxElevation` — the raymarcher's curvature-envelope bound — drops back to
    /// the real terrain max instead of a 32767 m artifact.
    private static func sanitized(_ tile: DEMTile) -> DEMTile {
        var e = tile.elevations
        let healed = sanitize(&e, ncols: tile.ncols, nrows: tile.nrows,
                              cellMeters: tile.cellsize * 111_320.0)
        guard healed.voided > 0 || healed.spikes > 0 else { return tile }
        NSLog("DEM sanitize: healed cached region (%d impossible, %d spikes)",
              healed.voided, healed.spikes)
        return DEMTile(ncols: tile.ncols, nrows: tile.nrows,
                       xllcorner: tile.xllcorner, yllcorner: tile.yllcorner,
                       cellsize: tile.cellsize, nodata: tile.nodata,
                       elevations: e, maxElevation: e.max() ?? 0)
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
    ///
    /// `complete` is false when any tile failed TRANSIENTLY (offline, timeout):
    /// the returned tile still renders — missing tiles void-fill, so the user
    /// sees what could be loaded — but it is NOT memory-cached and callers must
    /// not persist it, or a Wi-Fi hiccup becomes flat ocean across launches.
    static func fetch(lat: Double, lon: Double, radiusMeters: Double = 120_000,
                      maxGrid: Int = defaultMaxGrid,
                      onTileComplete: (@Sendable (String) -> Void)? = nil,
                      onTileDownloadProgress: (@Sendable (String, Double) -> Void)? = nil,
                      onTileStitched: (@Sendable () -> Void)? = nil)
        async throws -> (tile: DEMTile, complete: Bool) {
        // Debug (-failFetches): every network fetch fails, as if offline —
        // exercises the failed-move fallback without cutting the Mac's link.
        if ProcessInfo.processInfo.arguments.contains("-failFetches") {
            throw URLError(.notConnectedToInternet)
        }
        let key = boxKey(lat: lat, lon: lon, radiusMeters: radiusMeters) + "_g\(maxGrid)"
        if let hit = memoryCache.object(forKey: key as NSString) {
            // Already resident: no download or stitch, but tick both phases'
            // tiles so a combined progress counter still reaches its total.
            for t in neededTiles(lat: lat, lon: lon, radiusMeters: radiusMeters) {
                onTileComplete?(tileName(tLat: t.tLat, tLon: t.tLon).name)
                onTileStitched?()
            }
            return (hit.tile, true)
        }

        let (tile, complete) = try await assemble(
            lat: lat, lon: lon, radiusMeters: radiusMeters,
            maxGrid: maxGrid, onTileComplete: onTileComplete,
            onTileDownloadProgress: onTileDownloadProgress,
            onTileStitched: onTileStitched)
        if complete {
            memoryCache.setObject(Box(tile), forKey: key as NSString,
                                  cost: tile.elevations.count * MemoryLayout<Float>.size)
        }
        return (tile, complete)
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
                                 onTileComplete: (@Sendable (String) -> Void)? = nil,
                                 onTileDownloadProgress: (@Sendable (String, Double) -> Void)? = nil,
                                 onTileStitched: (@Sendable () -> Void)? = nil)
        async throws -> (tile: DEMTile, complete: Bool) {
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
        // progress as each settles. Tiles whose DECODED bytes are already cached
        // skip the gz disk read (10 MB/tile) and network entirely.
        struct Loads { var gz: [String: Data] = [:]; var decoded: [String: Data] = [:]; var failures = 0 }
        let loads = await withTaskGroup(of: (Int, Int, TileLoad).self) { group -> Loads in
            for t in needed {
                group.addTask {
                    if let hit = decodedCache.object(forKey: "\(t.tLat),\(t.tLon)" as NSString) {
                        return (t.tLat, t.tLon, .decoded(hit as Data))
                    }
                    let name = tileName(tLat: t.tLat, tLon: t.tLon).name
                    return (t.tLat, t.tLon, await loadHGTData(
                        tLat: t.tLat, tLon: t.tLon,
                        onProgress: onTileDownloadProgress.map { cb in
                            { frac in cb(name, frac) }
                        }))
                }
            }
            var out = Loads()
            for await (tLat, tLon, load) in group {
                switch load {
                case .data(let data): out.gz["\(tLat),\(tLon)"] = data
                case .decoded(let raw): out.decoded["\(tLat),\(tLon)"] = raw
                case .ocean: break
                case .failed: out.failures += 1
                case .stale(let data):
                    // Renders, but the failure keeps `complete` false: the
                    // coarse pre-Copernicus tile must not be cached as real.
                    out.gz["\(tLat),\(tLon)"] = data
                    out.failures += 1
                }
                onTileComplete?(tileName(tLat: tLat, tLon: tLon).name)
            }
            return out
        }
        let gzData = loads.gz
        let preDecoded = loads.decoded
        // All ocean / unreachable.
        guard !gzData.isEmpty || !preDecoded.isEmpty else { throw FetchError.empty }

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
                let key = "\(t.tLat),\(t.tLon)"
                guard let raw = preDecoded[key]
                    ?? decodedTile(tLat: t.tLat, tLon: t.tLon, gz: gzData[key]) else { return }
                let n = Int((Double(raw.count / 2)).squareRoot().rounded())
                guard n > 1, raw.count == n * n * 2 else { return }

                // A tile's south-edge row and east-edge col duplicate the
                // neighbouring tile's posts. For skadi tiles the duplicates
                // are byte-identical; for converted Copernicus tiles they're
                // CLAMPED approximations (GLO-30 doesn't ship the shared
                // edge posts — the converter copies the adjacent row/col).
                // Whenever the neighbour's data is part of this stitch,
                // defer the shared posts to it: the true post always wins,
                // and the formerly benign-race write order becomes
                // deterministic. An absent neighbour (ocean 404, transient
                // failure, box edge) keeps the clamp — better than a void.
                func hasTile(_ la: Int, _ lo: Int) -> Bool {
                    let k = "\(la),\(lo)"
                    return preDecoded[k] != nil || gzData[k] != nil
                }
                var gLatLo = max(rowS, t.tLat * samplesPerDegree)
                if hasTile(t.tLat - 1, t.tLon) {
                    gLatLo = max(gLatLo, t.tLat * samplesPerDegree + 1)
                }
                let gLatHi = min(rowN, (t.tLat + 1) * samplesPerDegree)
                let gLonLo = max(colMin, t.tLon * samplesPerDegree)
                var gLonHi = min(colMax, (t.tLon + 1) * samplesPerDegree)
                if hasTile(t.tLat, t.tLon + 1) {
                    gLonHi = min(gLonHi, (t.tLon + 1) * samplesPerDegree - 1)
                }
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

        let healed = sanitize(&elevations, ncols: ncols, nrows: nrows,
                              cellMeters: arcsec * 111_320.0 * Double(stride))
        if healed.voided > 0 || healed.spikes > 0 {
            NSLog("DEM sanitize: voided %d impossible posts, despiked %d artifact posts",
                  healed.voided, healed.spikes)
        }
        let maxElev = elevations.max() ?? 0
        let tile = DEMTile(
            ncols: ncols, nrows: nrows,
            xllcorner: (Double(colMin) - 0.5 * Double(stride)) * arcsec,
            yllcorner: (Double(rowN) - (Double(nrows) - 0.5) * Double(stride)) * arcsec,
            cellsize: arcsec * Double(stride), nodata: voidSentinel,
            elevations: elevations, maxElevation: maxElev)
        return (tile, loads.failures == 0)
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

    private static func decodedTile(tLat: Int, tLon: Int, gz: Data?) -> Data? {
        let key = "\(tLat),\(tLon)" as NSString
        if let hit = decodedCache.object(forKey: key) { return hit as Data }
        guard let gz, let raw = gunzip(gz) else { return nil }
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

    /// Bounds of physically possible Earth-surface elevation. Land tops out at
    /// Everest's 8849 m; the mirror blends coastal bathymetry into some tiles,
    /// so depths down to the deepest trench (−10,935 m) are data, not garbage.
    /// Anything outside is corruption — the Florida marsh corridor east of
    /// Orlando (N28W081) carries ~20k Int16-SATURATED posts (+32767 m) in runs
    /// up to 39 long, which no neighbour-based spike test can heal: interior
    /// posts of a run protect each other exactly like a real ridge line.
    private static let maxPlausibleMeters: Float = 9000
    private static let minPlausibleMeters: Float = -12000

    /// The one entry point that turns a freshly stitched or snapshot-loaded
    /// grid into renderable terrain, in the only order that works: impossible
    /// values become voids FIRST (so they can't seed the fill), voids fill from
    /// row neighbours, and the spike filter runs LAST (so neither the void
    /// sentinel nor saturated posts can masquerade as terrain during its
    /// neighbour tests).
    static func sanitize(_ e: inout [Float], ncols: Int, nrows: Int,
                         cellMeters: Double) -> (voided: Int, spikes: Int) {
        let voided = voidImplausible(&e, ncols: ncols, nrows: nrows)
        fillVoids(&e, ncols: ncols, nrows: nrows)
        let spikes = despike(&e, ncols: ncols, nrows: nrows,
                             thresholdMeters: despikeThreshold(cellMeters: cellMeters))
        return (voided, spikes)
    }

    /// Rewrite posts outside the possible Earth-surface range as voids, to be
    /// refilled from their row neighbours. Unlike `despike` this needs no
    /// neighbourhood consensus, so clustered corruption — runs, blobs, whole
    /// swaths of saturated posts — dissolves in one pass with zero false
    /// positives anywhere on Earth.
    private static func voidImplausible(_ e: inout [Float], ncols: Int, nrows: Int) -> Int {
        var rowFixes = [Int](repeating: 0, count: nrows)
        rowFixes.withUnsafeMutableBufferPointer { fixes in
            e.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: nrows) { r in
                    let base = r * ncols
                    var fixed = 0
                    for c in 0..<ncols {
                        let v = buf[base + c]
                        // Inverted form: also catches NaN (any comparison with
                        // NaN is false), which would otherwise sail through a
                        // `>` / `<` pair and poison the raymarcher.
                        if !(v >= minPlausibleMeters && v <= maxPlausibleMeters) {
                            buf[base + c] = voidSentinel
                            fixed += 1
                        }
                    }
                    fixes[r] = fixed
                }
            }
        }
        return rowFixes.reduce(0, +)
    }

    /// Minimum height a post must tower over (or sink under) its EVERY neighbour
    /// before it's declared an artifact. 150 m at native ~30 m spacing means >78°
    /// slopes on all 8 sides at once — beyond anything in C-band SRTM, which
    /// smooths real pinnacles far below that. Scales with cell size so the coarse
    /// far tier (posts ~120 m apart, where large real relief between neighbours
    /// is normal) keeps the same safety margin.
    private static func despikeThreshold(cellMeters: Double) -> Float {
        Float(max(150.0, 2.0 * cellMeters))
    }

    /// Remove radar-artifact posts — singles AND small clusters. The keyless
    /// skadi mirror serves UNEDITED SRTM, which over water contains posts
    /// thousands of meters tall (a 4001 m post amid 2 m Puget Sound water) and
    /// mirror-image wells (−5802 m); the official SRTM V3/NASADEM releases
    /// patched these, the mirror never did, and the raymarcher faithfully
    /// renders each one as a giant spire.
    ///
    /// Artifacts come in PAIRS as well: the Snohomish delta has 1459 m and
    /// 2913 m posts diagonally adjacent over ~5 m river flats. Against an
    /// all-8-neighbours test each spike protected the other, and healing one
    /// to its MAX neighbour copied the other spike's height — leaving a twin
    /// 1459 m spire. So a post is judged against its SECOND-highest neighbour:
    /// real terrain is connected — a ridge or pinnacle line running through a
    /// post leaves ≥2 similar-height neighbours — while an artifact pair
    /// musters exactly one. Clearing even the second-highest by
    /// `thresholdMeters` means >78° slopes on 7 of 8 sides at once, beyond
    /// anything in C-band SRTM (verified: zero fixes across the whole bundled
    /// Cascades grid). Spikes snap DOWN to that second-highest neighbour;
    /// wells mirror with the second-lowest.
    ///
    /// Up to 4 passes: healing a cluster's outer posts exposes the inner ones,
    /// so short chains dissolve end-first; clean tiles exit after one pass
    /// (~ms on a stitched grid). Runs only on an actual stitch or a
    /// cached-region load. Border posts are skipped (no full neighbourhood;
    /// they sit at the scene's far edge). Runs after `fillVoids` so the void
    /// sentinel can't masquerade as a deep neighbour. In-place is safe
    /// concurrently: writes are rare, store plausible terrain, and aligned
    /// 4-byte stores can't tear — a racing row reading either value still
    /// judges its own posts correctly.
    static func despike(_ e: inout [Float], ncols: Int, nrows: Int, thresholdMeters t: Float) -> Int {
        guard ncols >= 3, nrows >= 3 else { return 0 }
        var total = 0
        for _ in 0..<4 {
            let fixed = despikePass(&e, ncols: ncols, nrows: nrows, thresholdMeters: t)
            total += fixed
            if fixed == 0 { break }
        }
        return total
    }

    private static func despikePass(_ e: inout [Float], ncols: Int, nrows: Int,
                                    thresholdMeters t: Float) -> Int {
        var rowFixes = [Int](repeating: 0, count: nrows)
        rowFixes.withUnsafeMutableBufferPointer { fixes in
            e.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: nrows - 2) { i in
                    let r = i + 1
                    var fixed = 0
                    for c in 1..<(ncols - 1) {
                        let idx = r * ncols + c
                        let up = idx - ncols, dn = idx + ncols
                        let v = buf[idx]
                        // Two largest / two smallest of the 8 neighbours.
                        var m1 = -Float.greatestFiniteMagnitude, m2 = m1
                        var n1 = Float.greatestFiniteMagnitude, n2 = n1
                        func acc(_ w: Float) {
                            if w > m1 { m2 = m1; m1 = w } else if w > m2 { m2 = w }
                            if w < n1 { n2 = n1; n1 = w } else if w < n2 { n2 = w }
                        }
                        acc(buf[up - 1]); acc(buf[up]); acc(buf[up + 1])
                        acc(buf[idx - 1]); acc(buf[idx + 1])
                        acc(buf[dn - 1]); acc(buf[dn]); acc(buf[dn + 1])
                        if v - m2 > t { buf[idx] = m2; fixed += 1; continue }
                        if n2 - v > t { buf[idx] = n2; fixed += 1 }
                    }
                    fixes[r] = fixed
                }
            }
        }
        return rowFixes.reduce(0, +)
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
        private var tasks: [String: Task<TileLoad, Never>] = [:]

        func load(for name: String, download: @escaping @Sendable () async -> TileLoad) async -> TileLoad {
            if let running = tasks[name] { return await running.value }
            let task = Task { await download() }
            tasks[name] = task
            let result = await task.value
            tasks[name] = nil
            return result
        }
    }
    private static let inflight = InflightDownloads()

    /// Tile-download session. The shared session's default of 6 connections per
    /// host serialized a cold 16-tile fetch into ~3 waves against the S3 mirror
    /// (which handles wide parallelism fine) — the limit, not bandwidth, was the
    /// long pole of a cold move. One connection per tile of a worst-case fetch.
    private static let tileSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: cfg)
    }()

    /// One dataTask with byte-level progress via KVO on `task.progress` — the
    /// tiles are ~10 MB apiece, and completion-only ticking left the loading
    /// bar frozen for the many seconds each tile spends in flight. Throttled
    /// to ≥3% steps so the observer doesn't spam the main queue.
    private static func downloadReportingProgress(
        _ req: URLRequest, onProgress: (@Sendable (Double) -> Void)?
    ) async -> (Data, URLResponse)? {
        await withCheckedContinuation { cont in
            final class Box: @unchecked Sendable {
                var obs: NSKeyValueObservation?
                var lastReported = 0.0
            }
            let box = Box()
            let task = tileSession.dataTask(with: req) { data, resp, _ in
                box.obs = nil
                if let data, let resp { cont.resume(returning: (data, resp)) }
                else { cont.resume(returning: nil) }
            }
            if let onProgress {
                box.obs = task.progress.observe(\.fractionCompleted) { p, _ in
                    let f = p.fractionCompleted
                    guard f - box.lastReported >= 0.03 else { return }
                    box.lastReported = f
                    onProgress(f)
                }
            }
            task.resume()
        }
    }

    /// Download one degree tile from whichever source actually has ~30 m data
    /// there: skadi SRTM inside SRTM's 60°N–56°S coverage, Copernicus GLO-30
    /// beyond it (converted on the spot into the same `.hgt.gz` bytes — see
    /// `CopernicusDEM`). Every caller downstream of this sees one format.
    private static func downloadTile(tLat: Int, tLon: Int,
                                     onProgress: (@Sendable (Double) -> Void)? = nil)
        async -> TileLoad {
        let useCopernicus = CopernicusDEM.coversTile(tLat: tLat)
        let (folder, name) = tileName(tLat: tLat, tLon: tLon)
        let url = useCopernicus
            ? CopernicusDEM.url(tLat: tLat, tLon: tLon)
            : URL(string: "https://elevation-tiles-prod.s3.amazonaws.com/skadi/\(folder)/\(name).hgt.gz")
        guard let url else { return .failed }
        NSLog("DEM tile download: %@ (%@)", name, useCopernicus ? "copernicus" : "srtm")
        var req = URLRequest(url: url)
        req.timeoutInterval = useCopernicus ? 120 : 60   // COGs run ~2× the bytes
        // NOTE: concurrent requesters share the deduped task around this, so
        // only the FIRST caller's progress closure streams — the other tier's
        // copy of a shared tile still ticks its completion unit as ever.
        guard let (data, resp) = await downloadReportingProgress(req, onProgress: onProgress) else {
            return .failed                          // offline / timeout: retryable
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .ocean }            // genuinely no land tile here
        guard code == 200, !data.isEmpty else { return .failed }
        if !useCopernicus { return .data(data) }
        guard let converted = try? CopernicusDEM.convertToHGTGZ(tiff: data) else {
            return .failed   // truncated/changed upstream: retryable, never cached
        }
        return .data(converted)
    }

    private static func loadHGTData(tLat: Int, tLon: Int,
                                    onProgress: (@Sendable (Double) -> Void)? = nil)
        async -> TileLoad {
        let name = tileName(tLat: tLat, tLon: tLon).name
        let regionURL = regionStoreDir.appendingPathComponent("\(name).hgt.gz")
        let cacheURL = hgtCacheDir.appendingPathComponent("\(name).hgt.gz")
        // A cached HIGH-LATITUDE tile not written by the Copernicus converter
        // is a coarse pre-supplement skadi file (Iceland as melted blobs) —
        // treat it as a miss so it's refetched and overwritten, not served.
        let needsCopernicus = CopernicusDEM.coversTile(tLat: tLat)
        @Sendable func fresh(_ d: Data?) -> Data? {
            guard let d else { return nil }
            return !needsCopernicus || CopernicusDEM.isConverted(d) ? d : nil
        }
        // Downloaded offline regions first (persistent), then the runtime cache.
        let regionData = try? Data(contentsOf: regionURL)
        if let d = fresh(regionData) { return .data(d) }
        let cacheData = try? Data(contentsOf: cacheURL)
        if let d = fresh(cacheData) { return .data(d) }
        // Kept only as the offline fallback below — coarse beats a void.
        let staleData = regionData ?? cacheData

        return await inflight.load(for: name) {
            // Re-check inside the deduped task: a racing caller may have finished
            // (and written the cache) between our miss above and getting here.
            if let cached = fresh(try? Data(contentsOf: cacheURL)) { return .data(cached) }
            let load = await downloadTile(tLat: tLat, tLon: tLon, onProgress: onProgress)
            switch load {
            case .data(let data):
                try? data.write(to: cacheURL)
                // Heal a stale offline-region tile in place: the region keeps
                // rendering offline, just with real 30 m terrain from now on.
                if regionData != nil { try? data.write(to: regionURL) }
            case .failed where staleData != nil:
                // Offline with only a pre-supplement tile on disk: coarse
                // terrain beats a void. `.stale` stitches like data but keeps
                // `complete` false, so the next online visit still refetches.
                return .stale(staleData!)
            default: break
            }
            return load
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

    /// Inverse of `tileFileName`: the SW-corner degree indices of a stored tile
    /// ("N46W122" → (46, −122)) — lets the region picker draw downloaded coverage.
    static func tileCoordinate(fromFileName name: String) -> (tLat: Int, tLon: Int)? {
        guard name.count == 7,
              let lat = Int(name.dropFirst(1).prefix(2)),
              let lon = Int(name.dropFirst(4)) else { return nil }
        let ns = name.first, ew = name.dropFirst(3).first
        guard ns == "N" || ns == "S", ew == "E" || ew == "W" else { return nil }
        return (ns == "S" ? -lat : lat, ew == "W" ? -lon : lon)
    }

    /// `regionTiles(...).count` without materializing the array — the region
    /// picker reads this per map-camera frame while dragging.
    static func regionTileCount(south: Double, north: Double, west: Double, east: Double) -> Int {
        let s = min(south, north), n = max(south, north)
        let w = min(west, east), e = max(west, east)
        return (Int(floor(n)) - Int(floor(s)) + 1) * (Int(floor(e)) - Int(floor(w)) + 1)
    }

    /// Ensure a tile is in the persistent region store. Returns bytes stored (0 = an
    /// ocean/void tile that 404s — nothing to keep but still "done"), or nil on a
    /// transient failure (caller can retry). Promotes from the runtime cache if present.
    static func ensurePersistentTile(tLat: Int, tLon: Int) async -> Int? {
        let name = tileName(tLat: tLat, tLon: tLon).name
        let dest = regionStoreDir.appendingPathComponent("\(name).hgt.gz")
        // Same freshness gate as loadHGTData: a high-latitude file that
        // didn't come from the Copernicus converter is coarse pre-supplement
        // skadi data — re-download instead of keeping/promoting it.
        let needsCopernicus = CopernicusDEM.coversTile(tLat: tLat)
        @Sendable func fresh(_ d: Data?) -> Data? {
            guard let d else { return nil }
            return !needsCopernicus || CopernicusDEM.isConverted(d) ? d : nil
        }
        if let existing = fresh(try? Data(contentsOf: dest, options: .alwaysMapped)) {
            return existing.count                         // already downloaded
        }
        if let data = fresh(try? Data(contentsOf: hgtCacheDir.appendingPathComponent("\(name).hgt.gz"))) {
            try? data.write(to: dest); return data.count  // promote from runtime cache
        }
        switch await downloadTile(tLat: tLat, tLon: tLon) {
        case .ocean: return 0                             // ocean tile — nothing to store
        case .failed, .decoded, .stale: return nil
        case .data(let data):
            try? data.write(to: dest)
            return data.count
        }
    }

    /// Remove a downloaded tile from the persistent store (caller handles sharing).
    static func deletePersistentTile(name: String) {
        try? FileManager.default.removeItem(at: regionStoreDir.appendingPathComponent("\(name).hgt.gz"))
    }

    /// Tile names ("N46W122") currently in the persistent store — lets the
    /// region store sweep orphans no manifest entry references.
    static func persistentTileNames() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: regionStoreDir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            let file = url.lastPathComponent
            guard file.hasSuffix(".hgt.gz") else { return nil }
            return String(file.dropLast(".hgt.gz".count))
        }
    }

    /// On-disk size of one persistent tile (0 if absent) — the truthful basis
    /// for a region's byte count, shared tiles included.
    static func persistentTileBytes(name: String) -> Int {
        let path = regionStoreDir.appendingPathComponent("\(name).hgt.gz").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    }

    /// Total bytes currently used by the persistent region store.
    static func downloadedBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: regionStoreDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // MARK: gzip (Compression speaks raw deflate, not the gzip wrapper)

    static func gunzip(_ data: Data) -> Data? {
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
