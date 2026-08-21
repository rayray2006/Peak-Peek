import Foundation
import Metal
import simd

/// A loaded digital elevation model: a regular lat/lon grid of elevations
/// (meters), plus the geographic metadata needed to place it in a local ENU
/// frame and build a Metal height texture.
///
/// Rows are stored north-to-south (row 0 = northernmost); we keep that ordering in
/// the texture so texture row 0 = north. At runtime tiles come from `DEMFetcher`
/// (keyless AWS SRTM). The `parseAAIGrid` helper below is legacy (ESRI ASCII grid
/// — e.g. the macOS harness loading a local `.asc`); the app no longer uses it.
struct DEMTile {
    let ncols: Int
    let nrows: Int
    /// Lower-left corner (cell-edge) longitude/latitude, degrees.
    let xllcorner: Double
    let yllcorner: Double
    /// Cell size in degrees (square cells).
    let cellsize: Double
    let nodata: Float
    /// Row-major elevations, row 0 = north. Count = ncols * nrows.
    let elevations: [Float]
    /// Maximum elevation in the grid (meters). Computed once at construction.
    let maxElevation: Float

    var north: Double { yllcorner + Double(nrows) * cellsize }
    var west: Double { xllcorner }

    /// True if (lat, lon) falls within this tile's geographic extent.
    func contains(lat: Double, lon: Double) -> Bool {
        lon >= xllcorner && lon <= xllcorner + Double(ncols) * cellsize
            && lat >= yllcorner && lat <= yllcorner + Double(nrows) * cellsize
    }

    /// True if (lat, lon) is inside the tile AND at least `marginMeters` from every
    /// edge — i.e. there's a healthy band of terrain around the eye in all
    /// directions, so this tile can be reused for that viewpoint without a refetch.
    func contains(lat: Double, lon: Double, marginMeters: Double) -> Bool {
        let mLat = marginMeters / 111_320.0
        let mLon = marginMeters / (111_320.0 * max(cos(lat * .pi / 180), 0.01))
        return lon >= xllcorner + mLon && lon <= xllcorner + Double(ncols) * cellsize - mLon
            && lat >= yllcorner + mLat && lat <= yllcorner + Double(nrows) * cellsize - mLat
    }

    // MARK: - Parsing

    static func parseAAIGrid(path: String) throws -> DEMTile {
        return try parseAAIGrid(data: try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func parseAAIGrid(data: Data) throws -> DEMTile {
        let bytes = [UInt8](data)
        let n = bytes.count

        var ncols = 0, nrows = 0
        var xll = 0.0, yll = 0.0, cell = 0.0
        var nodata: Float = -9999
        var values = [Float]()

        // Byte-level tokenizer. A token starting with a letter is a header key
        // whose value is the next token; any other token is an elevation.
        // This tolerates any number of header lines (AAIGrid omits NODATA_value
        // when there is none).
        var i = 0
        @inline(__always) func isSpace(_ b: UInt8) -> Bool {
            return b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D
        }
        @inline(__always) func isAlpha(_ b: UInt8) -> Bool {
            return (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        // Fast float parse over a byte range [s, e).
        @inline(__always) func parseFloat(_ s: Int, _ e: Int) -> Float {
            var p = s
            var sign: Float = 1
            if p < e, bytes[p] == 0x2D { sign = -1; p += 1 }          // '-'
            else if p < e, bytes[p] == 0x2B { p += 1 }                // '+'
            var intPart: Double = 0
            while p < e, bytes[p] >= 0x30, bytes[p] <= 0x39 {
                intPart = intPart * 10 + Double(bytes[p] - 0x30); p += 1
            }
            var result = intPart
            if p < e, bytes[p] == 0x2E {                               // '.'
                p += 1
                var frac: Double = 0, scale: Double = 1
                while p < e, bytes[p] >= 0x30, bytes[p] <= 0x39 {
                    frac = frac * 10 + Double(bytes[p] - 0x30); scale *= 10; p += 1
                }
                result += frac / scale
            }
            if p < e, (bytes[p] == 0x65 || bytes[p] == 0x45) {         // 'e'/'E'
                p += 1
                var esign = 1
                if p < e, bytes[p] == 0x2D { esign = -1; p += 1 }
                else if p < e, bytes[p] == 0x2B { p += 1 }
                var exp = 0
                while p < e, bytes[p] >= 0x30, bytes[p] <= 0x39 {
                    exp = exp * 10 + Int(bytes[p] - 0x30); p += 1
                }
                result *= pow(10.0, Double(esign * exp))
            }
            return Float(sign) * Float(result)
        }

        var pendingKey: String? = nil
        while i < n {
            while i < n, isSpace(bytes[i]) { i += 1 }     // skip whitespace
            if i >= n { break }
            let start = i
            while i < n, !isSpace(bytes[i]) { i += 1 }    // token = [start, i)

            if isAlpha(bytes[start]) {
                pendingKey = String(decoding: bytes[start..<i], as: UTF8.self).lowercased()
                continue
            }
            // Numeric token.
            if let key = pendingKey {
                let str = String(decoding: bytes[start..<i], as: UTF8.self)
                switch key {
                case "ncols": ncols = Int(str) ?? 0
                case "nrows": nrows = Int(str) ?? 0
                case "xllcorner": xll = Double(str) ?? 0
                case "yllcorner": yll = Double(str) ?? 0
                case "cellsize": cell = Double(str) ?? 0
                case "nodata_value": nodata = Float(str) ?? -9999
                default:
                    // Unknown key with a numeric value — treat the number as data.
                    if values.isEmpty { values.reserveCapacity(max(1, ncols * nrows)) }
                    values.append(parseFloat(start, i))
                }
                pendingKey = nil
            } else {
                if values.isEmpty { values.reserveCapacity(max(1, ncols * nrows)) }
                values.append(parseFloat(start, i))
            }
        }

        guard ncols > 0, nrows > 0, cell > 0 else {
            throw DEMError.parse("bad header (ncols=\(ncols) nrows=\(nrows) cell=\(cell))")
        }
        guard values.count == ncols * nrows else {
            throw DEMError.parse("value count \(values.count) != \(ncols * nrows)")
        }
        return DEMTile(ncols: ncols, nrows: nrows, xllcorner: xll, yllcorner: yll,
                       cellsize: cell, nodata: nodata, elevations: values,
                       maxElevation: values.max() ?? 0)
    }

    /// Load from the compact binary cache if present & current, else parse the
    /// AAIGrid and write the cache.
    static func load(ascPath: String) throws -> DEMTile {
        let binPath = (ascPath as NSString).deletingPathExtension + ".dembin"
        if let cached = try? loadBinary(path: binPath) {
            return cached
        }
        let tile = try parseAAIGrid(path: ascPath)
        try? tile.writeBinary(path: binPath)
        return tile
    }

    // MARK: - Binary cache (header + raw Float32)

    private static let magic: UInt32 = 0x4D56_4454 // 'MVDT'

    /// Write this tile to the compact `.dembin` cache format at `path`.
    func saveBinary(to path: String) throws { try writeBinary(path: path) }

    private func writeBinary(path: String) throws {
        // Header (40 bytes), then the raw Float32 grid streamed straight from the
        // elevations buffer — assembling one contiguous Data first doubled the
        // ~64 MB grid's footprint for the duration of every snapshot save.
        var header = Data(capacity: 40)
        var m = Self.magic; header.append(Data(bytes: &m, count: 4))
        var c = Int32(ncols); header.append(Data(bytes: &c, count: 4))
        var r = Int32(nrows); header.append(Data(bytes: &r, count: 4))
        var x = xllcorner; header.append(Data(bytes: &x, count: 8))
        var y = yllcorner; header.append(Data(bytes: &y, count: 8))
        var cs = cellsize; header.append(Data(bytes: &cs, count: 8))
        var nd = nodata; header.append(Data(bytes: &nd, count: 4))
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        try elevations.withUnsafeBytes { raw in
            try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                                              count: raw.count, deallocator: .none))
        }
    }

    /// Public entry to load a prebuilt `.dembin` (e.g. bundled in the app).
    static func loadCached(binPath: String) throws -> DEMTile {
        return try loadBinary(path: binPath)
    }

    private static func loadBinary(path: String) throws -> DEMTile {
        // Mapped, not read: the copy into `elev` below then streams from the
        // mapping instead of first materializing a second ~64 MB Data buffer
        // (which made the launch fast path spike to ~2× the grid size).
        let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        guard d.count >= 36 else { throw DEMError.parse("bin too small") }
        func read<T>(_ off: Int, _ t: T.Type) -> T { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) } }
        guard read(0, UInt32.self) == magic else { throw DEMError.parse("bad magic") }
        let ncols = Int(read(4, Int32.self))
        let nrows = Int(read(8, Int32.self))
        let xll = read(12, Double.self)
        let yll = read(20, Double.self)
        let cell = read(28, Double.self)
        let nodata = read(36, Float.self)
        let count = ncols * nrows
        let expected = 40 + count * 4
        guard d.count == expected else { throw DEMError.parse("bin size \(d.count) != \(expected)") }
        var elev = [Float](repeating: 0, count: count)
        _ = elev.withUnsafeMutableBytes { dst in
            d.copyBytes(to: dst, from: 40..<expected)
        }
        return DEMTile(ncols: ncols, nrows: nrows, xllcorner: xll, yllcorner: yll,
                       cellsize: cell, nodata: nodata, elevations: elev,
                       maxElevation: elev.max() ?? 0)
    }

    // MARK: - Metal texture + ENU framing

    /// Build an R32Float height texture (texel = meters, row 0 = north).
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: ncols, height: nrows, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        elevations.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, ncols, nrows),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: ncols * 4)
        }
        return tex
    }

    /// Meters per degree at a reference latitude.
    func metersPerDegree(atLat lat: Double) -> (lon: Double, lat: Double) {
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(lat * .pi / 180)
        return (mLon, mLat)
    }

    /// Fill the DEM fields of `uniforms` for a camera referenced at (refLat, refLon).
    /// The ENU origin is the reference point; +x east, +y north, meters.
    func applyDEMUniforms(to u: inout Uniforms, refLat: Double, refLon: Double) {
        let (mLon, mLat) = metersPerDegree(atLat: refLat)
        // SW corner (lower-left) in ENU meters relative to reference.
        let minX = (xllcorner - refLon) * mLon
        let minY = (yllcorner - refLat) * mLat
        u.gridMinENU = SIMD2<Float>(Float(minX), Float(minY))
        u.cellSizeENU = SIMD2<Float>(Float(cellsize * mLon), Float(cellsize * mLat))
        u.gridDims = SIMD2<Float>(Float(ncols), Float(nrows))
        u.useDEM = 1
        u.globalMaxHeight = maxElevation * u.heightScale
        Self.applyProjectionCorrection(to: &u, refLat: refLat)
    }

    /// ENU projection correction shared by both tiers: lets the shader undo the
    /// single-cos(refLat) flattening per sample (meridian convergence + geodesic
    /// bulge) so distant rendered azimuths land on true compass bearings.
    static func applyProjectionCorrection(to u: inout Uniforms, refLat: Double) {
        let refLatRad = refLat * .pi / 180
        u.refLatRad = Float(refLatRad)
        u.cosRefLat = Float(max(cos(refLatRad), 1e-4))
        u.geoK = Float(tan(refLatRad) / (2 * Uniforms.enuEarthRadiusMeters))
    }

    /// Fill the FAR (coarse, wide-coverage) DEM tier — sampled by the shader only
    /// where the near grid has no data. Also sets `globalMaxHeight` from this tile
    /// (the far tile spans the whole scene, so it holds the true max for the
    /// curvature march bound).
    func applyFarDEMUniforms(to u: inout Uniforms, refLat: Double, refLon: Double) {
        let (mLon, mLat) = metersPerDegree(atLat: refLat)
        let minX = (xllcorner - refLon) * mLon
        let minY = (yllcorner - refLat) * mLat
        u.gridMinENU2 = SIMD2<Float>(Float(minX), Float(minY))
        u.cellSizeENU2 = SIMD2<Float>(Float(cellsize * mLon), Float(cellsize * mLat))
        u.gridDims2 = SIMD2<Float>(Float(ncols), Float(nrows))
        u.useFar = 1
        u.globalMaxHeight = maxElevation * u.heightScale
        Self.applyProjectionCorrection(to: &u, refLat: refLat)
    }

    /// Bilinear elevation lookup (meters) at a geographic coordinate, for CPU
    /// use (e.g. setting camera elevation to ground + eye height).
    func elevation(lat: Double, lon: Double) -> Float {
        let col = (lon - xllcorner) / cellsize - 0.5
        // row 0 = north; convert lat to row-from-top.
        let rowFromBottom = (lat - yllcorner) / cellsize - 0.5
        let rowFromTop = Double(nrows - 1) - rowFromBottom
        let c0 = max(0, min(ncols - 1, Int(floor(col))))
        let r0 = max(0, min(nrows - 1, Int(floor(rowFromTop))))
        let c1 = min(ncols - 1, c0 + 1)
        let r1 = min(nrows - 1, r0 + 1)
        let fc = Float(col - floor(col))
        let fr = Float(rowFromTop - floor(rowFromTop))
        func at(_ c: Int, _ r: Int) -> Float { elevations[r * ncols + c] }
        let top = at(c0, r0) * (1 - fc) + at(c1, r0) * fc
        let bot = at(c0, r1) * (1 - fc) + at(c1, r1) * fc
        return top * (1 - fr) + bot * fr
    }

    /// Global elevation range and the location of the maximum (for diagnostics).
    func elevationStats() -> (min: Float, max: Float, maxLat: Double, maxLon: Double) {
        var mn: Float = .greatestFiniteMagnitude
        var mx: Float = -.greatestFiniteMagnitude
        var mxIdx = 0
        for (i, v) in elevations.enumerated() where v > nodata {
            if v < mn { mn = v }
            if v > mx { mx = v; mxIdx = i }
        }
        let r = mxIdx / ncols, c = mxIdx % ncols
        let lon = xllcorner + (Double(c) + 0.5) * cellsize
        let lat = yllcorner + (Double(nrows - 1 - r) + 0.5) * cellsize
        return (mn, mx, lat, lon)
    }

    /// A local maximum of the DEM grid — an actual apex of the drawn terrain —
    /// with its WINDOWED prominence: how far it rises above the highest saddle
    /// connecting it to higher ground inside the search window (window floor
    /// when nothing in the window is higher). Label anchors match catalog
    /// peaks to these 1:1, so a dot can only ever sit on a real bump top,
    /// never on a flank cell.
    struct LocalSummit {
        let lat: Double
        let lon: Double
        let elev: Float
        let prominence: Float
    }

    /// All grid local maxima within `radiusMeters` of (lat, lon), with
    /// prominence ≥ `minProminence`, highest first.
    ///
    /// One union-find flood over the window computes every candidate's
    /// prominence at once: cells are visited highest→lowest, each joining its
    /// already-visited (higher) neighbors' components; a cell where two
    /// components meet is the SADDLE between their summits, fixing the lower
    /// summit's prominence there. Plateau ties break by cell index, so a flat
    /// summit yields ONE candidate (the rest read as prominence 0). The
    /// maxima test itself uses the full grid, so a window-edge cell whose
    /// higher neighbor sits just outside the window can't fake a summit.
    func localSummits(lat: Double, lon: Double, radiusMeters: Double,
                      minProminence: Float) -> [LocalSummit] {
        let (mLon, mLat) = metersPerDegree(atLat: lat)
        let dCol = Int((radiusMeters / mLon) / cellsize) + 1
        let dRow = Int((radiusMeters / mLat) / cellsize) + 1
        let cCenter = min(ncols - 1, max(0, Int((lon - xllcorner) / cellsize)))
        let rCenter = min(nrows - 1, max(0, (nrows - 1) - Int((lat - yllcorner) / cellsize)))
        let r0 = max(0, rCenter - dRow), r1 = min(nrows - 1, rCenter + dRow)
        let c0 = max(0, cCenter - dCol), c1 = min(ncols - 1, cCenter + dCol)
        let w = c1 - c0 + 1, h = r1 - r0 + 1
        let count = w * h
        guard count > 1 else { return [] }

        // Window-local copy (wi = wr * w + wc), for cache-friendly flooding.
        var elev = [Float](repeating: 0, count: count)
        for wr in 0..<h {
            let base = (r0 + wr) * ncols + c0
            for wc in 0..<w { elev[wr * w + wc] = elevations[base + wc] }
        }
        // Highest first; ties by index — the deterministic plateau representative.
        var order = Array(Int32(0)..<Int32(count))
        order.sort { elev[Int($0)] == elev[Int($1)] ? $0 < $1 : elev[Int($0)] > elev[Int($1)] }

        var parent = [Int32](repeating: -1, count: count)   // -1 = unvisited
        var summitOf = [Int32](repeating: -1, count: count) // root wi → summit wi
        var prom = [Float](repeating: -1, count: count)     // summit wi → prominence
        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }

        var windowMin = Float.greatestFiniteMagnitude
        for wi in order {
            let v = elev[Int(wi)]
            guard v > nodata else { continue }
            windowMin = min(windowMin, v)
            let wr = Int(wi) / w, wc = Int(wi) % w
            // Distinct components among already-visited neighbors.
            var roots: [Int32] = []
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let nr = wr + dr, nc = wc + dc
                    guard nr >= 0, nr < h, nc >= 0, nc < w else { continue }
                    let ni = Int32(nr * w + nc)
                    guard parent[Int(ni)] >= 0 else { continue }
                    let rt = find(ni)
                    if !roots.contains(rt) { roots.append(rt) }
                }
            }
            guard let first = roots.first else {
                parent[Int(wi)] = wi          // new component: wi is its summit
                summitOf[Int(wi)] = wi
                continue
            }
            // Join the component with the HIGHEST summit; every other
            // component ends here — this cell is its saddle.
            var keep = first
            for rt in roots.dropFirst() {
                let a = summitOf[Int(keep)], b = summitOf[Int(rt)]
                let higher = elev[Int(a)] == elev[Int(b)] ? min(a, b)
                    : (elev[Int(a)] > elev[Int(b)] ? a : b)
                let lower = higher == a ? b : a
                prom[Int(lower)] = elev[Int(lower)] - v
                let winner = higher == a ? keep : rt
                let loser = winner == keep ? rt : keep
                parent[Int(loser)] = winner
                keep = winner
            }
            parent[Int(wi)] = keep
        }

        var out: [LocalSummit] = []
        for wi in 0..<count where summitOf[wi] == Int32(wi) {
            let p = prom[wi] >= 0 ? prom[wi] : elev[wi] - windowMin   // never merged
            guard p >= minProminence else { continue }
            let row = r0 + wi / w, col = c0 + wi % w
            // Full-grid maxima check (ties by index): filters window-edge fakes.
            let gi = row * ncols + col
            let v = elevations[gi]
            var isMax = true
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let nr = row + dr, nc = col + dc
                    guard nr >= 0, nr < nrows, nc >= 0, nc < ncols else { continue }
                    let ni = nr * ncols + nc
                    let nv = elevations[ni]
                    if nv > v || (nv == v && ni < gi) { isMax = false }
                }
            }
            guard isMax else { continue }
            out.append(LocalSummit(
                lat: yllcorner + (Double(nrows - 1 - row) + 0.5) * cellsize,
                lon: xllcorner + (Double(col) + 0.5) * cellsize,
                elev: v, prominence: p))
        }
        out.sort { $0.elev == $1.elev ? $0.lat < $1.lat : $0.elev > $1.elev }
        return out
    }

    // MARK: Summit matching (ONE rule, used by the dot AND by the eye)

    /// Reach of every summit match: enough to cover catalog-coordinate offset
    /// and the apex displacement of a void-filled summit.
    static let summitSearchRadiusMeters: Double = 600
    /// Rise that separates a real bump from grid ripple.
    static let summitMinProminence: Float = 8

    /// How well a local maximum describes the RENDERED apex of a catalog peak.
    /// Elevation agreement dominates; overshoot (a cell higher than the
    /// surveyed summit) is someone else's mountain, penalized 2×. The distance
    /// term keeps a peak from wandering to a look-alike bump across the cirque;
    /// the small prominence bonus breaks near-ties toward the massif apex over
    /// a shoulder ripple. `catalogElevationMeters` nil = the catalog has no
    /// height, so prefer the higher candidate.
    ///
    /// This is the ONLY place the rule lives: the label pass scores with it to
    /// assign one apex per peak, and the eye scores with it to stand on the
    /// peak you asked for — so the dot and your feet agree by construction.
    static func summitMatchScore(
        _ s: LocalSummit, catalogLat: Double, catalogLon: Double,
        catalogElevationMeters: Double?,
        metersPerDegLat mLat: Double, metersPerDegLon mLon: Double
    ) -> Double {
        let dist = hypot((s.lat - catalogLat) * mLat, (s.lon - catalogLon) * mLon)
        var score = -0.15 * dist + 0.25 * Double(min(s.prominence, 100))
        if let target = catalogElevationMeters, target > 0 {
            let dh = Double(s.elev) - target
            score -= dh > 0 ? 2 * dh : -dh
        } else {
            score += Double(s.elev) * 0.2       // unknown height: prefer higher
        }
        return score
    }

    /// The rendered apex of ONE catalog peak — the best-scoring local maximum
    /// in reach, with no claims to respect. The label pass solves the same
    /// scoring as an ASSIGNMENT (many peaks competing for one apex each);
    /// placing the eye is a single-peak case of it, so both land on the same
    /// cell. nil when the DEM has no bump of its own here (a gendarme inside a
    /// bigger peak's mass) — the caller decides what to do with the catalog
    /// point.
    func matchedSummit(lat: Double, lon: Double,
                       catalogElevationMeters: Double?) -> LocalSummit? {
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(lat * .pi / 180), 0.01)
        var best: (score: Double, s: LocalSummit)?
        for s in localSummits(lat: lat, lon: lon,
                              radiusMeters: Self.summitSearchRadiusMeters,
                              minProminence: Self.summitMinProminence) {
            let score = Self.summitMatchScore(
                s, catalogLat: lat, catalogLon: lon,
                catalogElevationMeters: catalogElevationMeters,
                metersPerDegLat: mLat, metersPerDegLon: mLon)
            if best == nil || score > best!.score { best = (score, s) }
        }
        return best?.s
    }

    /// Candidate WATER-surface anchor cells for a lake label, nearest first.
    /// Lake catalog points are sometimes placed well off the water (Ross
    /// Lake's sits ~1 km up the eastern shore, 430 m ABOVE the surface — its
    /// dot rode the mountainside), and the single nearest surface cell can
    /// hide behind the shore ridge. Water in SRTM is FLAT, so: search in
    /// GROWING rings for cells that are low (≤ the label cell's height + 5 m)
    /// and flat (≥5 of 8 neighbours within ±2 m), returning ONE candidate per
    /// ring — each ring's nearest — so the caller can walk deeper into open
    /// water until one passes its visibility judgment. The ring growth keeps a
    /// small tarn snapping to ITS OWN surface long before a deeper valley two
    /// ridges over enters the search. A label already on flat water returns
    /// just itself; nothing water-like in reach falls back to the label point.
    func waterSurfaceCandidates(lat: Double, lon: Double)
        -> [(lat: Double, lon: Double, elev: Float)] {
        let (mLon, mLat) = metersPerDegree(atLat: lat)
        let cCenter = min(ncols - 2, max(1, Int((lon - xllcorner) / cellsize)))
        let rCenter = min(nrows - 2, max(1, (nrows - 1) - Int((lat - yllcorner) / cellsize)))
        func isFlat(_ r: Int, _ c: Int) -> Bool {
            guard r >= 1, r <= nrows - 2, c >= 1, c <= ncols - 2 else { return false }
            let v = elevations[r * ncols + c]
            var near = 0
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    if abs(elevations[(r + dr) * ncols + (c + dc)] - v) <= 2 { near += 1 }
                }
            }
            return near >= 5
        }
        let e0 = elevations[rCenter * ncols + cCenter]
        if isFlat(rCenter, cCenter) {
            return [(lat, lon, e0)]           // already on the water
        }
        // True ANNULI (prev, radius]: each candidate is the nearest flat cell
        // strictly deeper than the previous ring's, so the list steps
        // genuinely further into open water rather than one cell sideways.
        var out: [(lat: Double, lon: Double, elev: Float)] = []
        var prev = 0.0
        for radius in [150.0, 300.0, 600.0, 1200.0] {
            let dCol = Int((radius / mLon) / cellsize) + 1
            let dRow = Int((radius / mLat) / cellsize) + 1
            var best: (d2: Double, r: Int, c: Int)?
            for r in max(1, rCenter - dRow)...min(nrows - 2, rCenter + dRow) {
                for c in max(1, cCenter - dCol)...min(ncols - 2, cCenter + dCol) {
                    let v = elevations[r * ncols + c]
                    guard v <= e0 + 5, v > nodata else { continue }
                    let dy = Double(r - rCenter) * mLat * cellsize
                    let dx = Double(c - cCenter) * mLon * cellsize
                    let d2 = dx * dx + dy * dy
                    guard d2 > prev * prev else { continue }
                    if let b = best, d2 >= b.d2 { continue }
                    if isFlat(r, c) { best = (d2, r, c) }
                }
            }
            prev = radius
            if let best {
                let outLon = xllcorner + (Double(best.c) + 0.5) * cellsize
                let outLat = yllcorner + (Double(nrows - 1 - best.r) + 0.5) * cellsize
                out.append((outLat, outLon, elevations[best.r * ncols + best.c]))
            }
        }
        return out.isEmpty ? [(lat, lon, e0)] : out
    }

    /// Find the highest cell within `radiusMeters` of (lat,lon). Used to snap a
    /// camera onto the nearby summit despite coordinate imprecision + grid sampling.
    func highestNear(lat: Double, lon: Double, radiusMeters: Double) -> (lat: Double, lon: Double, elev: Float) {
        let (mLon, mLat) = metersPerDegree(atLat: lat)
        let dCol = Int((radiusMeters / mLon) / cellsize) + 1
        let dRow = Int((radiusMeters / mLat) / cellsize) + 1
        let cCenter = Int((lon - xllcorner) / cellsize)
        let rFromBottom = Int((lat - yllcorner) / cellsize)
        let rCenter = (nrows - 1) - rFromBottom
        var best: Float = -.greatestFiniteMagnitude
        var bc = cCenter, br = rCenter
        for r in max(0, rCenter - dRow)...min(nrows - 1, rCenter + dRow) {
            for c in max(0, cCenter - dCol)...min(ncols - 1, cCenter + dCol) {
                let v = elevations[r * ncols + c]
                if v > best { best = v; bc = c; br = r }
            }
        }
        let outLon = xllcorner + (Double(bc) + 0.5) * cellsize
        let outLat = yllcorner + (Double(nrows - 1 - br) + 0.5) * cellsize
        return (outLat, outLon, best)
    }

    enum DEMError: Error { case parse(String) }
}
