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
        var out = Data()
        var m = Self.magic; out.append(Data(bytes: &m, count: 4))
        var c = Int32(ncols); out.append(Data(bytes: &c, count: 4))
        var r = Int32(nrows); out.append(Data(bytes: &r, count: 4))
        var x = xllcorner; out.append(Data(bytes: &x, count: 8))
        var y = yllcorner; out.append(Data(bytes: &y, count: 8))
        var cs = cellsize; out.append(Data(bytes: &cs, count: 8))
        var nd = nodata; out.append(Data(bytes: &nd, count: 4))
        elevations.withUnsafeBytes { out.append(contentsOf: $0) }
        try out.write(to: URL(fileURLWithPath: path))
    }

    /// Public entry to load a prebuilt `.dembin` (e.g. bundled in the app).
    static func loadCached(binPath: String) throws -> DEMTile {
        return try loadBinary(path: binPath)
    }

    private static func loadBinary(path: String) throws -> DEMTile {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
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
