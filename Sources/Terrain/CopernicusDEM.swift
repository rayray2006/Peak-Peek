import Foundation
import Compression

/// Copernicus GLO-30 supplement for latitudes SRTM never covered. The skadi
/// mirror serves tiles everywhere, but above 60°N (and below 56°S) they're
/// coarse ~250 m GMTED data upsampled onto the 30 m grid — Iceland renders as
/// melted blobs (measured: ~2/3 of adjacent posts byte-identical). Copernicus
/// GLO-30 (TanDEM-X) is real ~30 m worldwide and lives on the same kind of
/// keyless public S3 bucket as skadi (`copernicus-dem-30m`, AWS Open Data,
/// no key, no account) — so it keeps the app shippable for the same reason.
///
/// Integration happens entirely at the fetch boundary: a high-latitude degree
/// tile downloads the Copernicus COG GeoTIFF and converts it HERE into the
/// exact gzipped SRTM1 `.hgt` bytes the rest of the pipeline speaks (3601²
/// big-endian Int16). The stitcher, caches, offline region store and
/// last-region snapshots never learn a second format exists.
///
/// GLO-30 tiles are 1°×1°, pixel-is-point registered like SRTM posts, 3600
/// rows of 1″ latitude — but the LONGITUDE step widens with latitude (2″ at
/// 60–70°N → 1800 cols, 3″ at 70–75°N, …), so conversion linearly
/// interpolates longitude back to 1″ posts. At 64°N a 2″ step is ~27 m of
/// ground — no real detail is invented. The missing south/east edge post row
/// (Copernicus tiles don't duplicate tile-boundary posts the way SRTM does)
/// is clamped from the last real post: at a degree seam the two covering
/// tiles then write values ~one post apart instead of identical ones — an
/// aligned-store race the stitcher already tolerates, and invisible at 30 m.
enum CopernicusDEM {
    /// Degree tiles the skadi composite has no SRTM for: north of 60°N and
    /// south of 56°S. Everything else keeps the battle-tested skadi path.
    static func coversTile(tLat: Int) -> Bool { tLat >= 60 || tLat <= -57 }

    /// "Copernicus_DSM_COG_10_N64_00_W018_00_DEM" — same antimeridian wrap
    /// as the skadi names (W180…E179).
    static func objectName(tLat: Int, tLon: Int) -> String {
        let lonW = ((tLon + 180) % 360 + 360) % 360 - 180
        let ns = tLat >= 0 ? "N" : "S"
        let ew = lonW >= 0 ? "E" : "W"
        return String(format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM",
                      ns, abs(tLat), ew, abs(lonW))
    }

    static func url(tLat: Int, tLon: Int) -> URL? {
        let name = objectName(tLat: tLat, tLon: tLon)
        return URL(string: "https://copernicus-dem-30m.s3.amazonaws.com/\(name)/\(name).tif")
    }

    // MARK: COG → gzipped SRTM1 hgt

    enum ConvertError: Error { case badTIFF, badLayout, decodeFailed, encodeFailed }

    /// Full conversion: COG GeoTIFF bytes → gzipped 3601×3601 big-endian
    /// Int16 `.hgt.gz` bytes, byte-compatible with a skadi download.
    static func convertToHGTGZ(tiff: Data) throws -> Data {
        let grid = try decodeGrid(tiff: tiff)
        let hgt = resampleToHGT(grid.values, width: grid.width, height: grid.height)
        guard let gz = gzip(hgt) else { throw ConvertError.encodeFailed }
        return gz
    }

    // MARK: TIFF/COG decode

    struct FloatGrid { let values: [Float]; let width: Int; let height: Int }

    /// Minimal reader for the ONE layout the Copernicus bucket serves
    /// (verified against live tiles): classic little-endian TIFF, first IFD
    /// full-res, float32 single-sample, 1024² tiles, deflate (8) with the
    /// floating-point predictor (3). Anything else throws rather than
    /// guessing — a changed upstream format must fail loudly, not render
    /// garbage terrain.
    static func decodeGrid(tiff d: Data) throws -> FloatGrid {
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int {
            Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
        }
        guard d.count > 8, d[0] == 0x49, d[1] == 0x49, u16(2) == 42 else {
            throw ConvertError.badTIFF
        }
        let ifd = u32(4)
        guard d.count > ifd + 2 else { throw ConvertError.badTIFF }
        let n = u16(ifd)
        guard d.count >= ifd + 2 + n * 12 else { throw ConvertError.badTIFF }

        var width = 0, height = 0, tileW = 0, tileH = 0
        var compression = 0, predictor = 1, bits = 0, sampleFormat = 1, samples = 1
        var offsets: [Int] = [], counts: [Int] = []

        for i in 0..<n {
            let e = ifd + 2 + i * 12
            let tag = u16(e), typ = u16(e + 2), cnt = u32(e + 4)
            // Inline value for counts that fit in 4 bytes; else an offset.
            let inline = typ == 3 ? u16(e + 8) : u32(e + 8)
            func longArray() -> [Int] {
                if cnt == 1 { return [inline] }
                let base = u32(e + 8)
                guard typ == 4, d.count >= base + cnt * 4 else { return [] }
                return (0..<cnt).map { u32(base + $0 * 4) }
            }
            switch tag {
            case 256: width = inline
            case 257: height = inline
            case 258: bits = inline
            case 259: compression = inline
            case 277: samples = inline
            case 317: predictor = inline
            case 322: tileW = inline
            case 323: tileH = inline
            case 324: offsets = longArray()
            case 325: counts = longArray()
            case 339: sampleFormat = inline
            default: break
            }
        }
        guard compression == 8, predictor == 3, bits == 32, sampleFormat == 3,
              samples == 1, width > 1, height > 1, tileW > 0, tileH > 0 else {
            throw ConvertError.badLayout
        }
        let tilesAcross = (width + tileW - 1) / tileW
        let tilesDown = (height + tileH - 1) / tileH
        guard offsets.count == tilesAcross * tilesDown,
              counts.count == offsets.count else { throw ConvertError.badLayout }

        var out = [Float](repeating: 0, count: width * height)
        var tileOK = [Bool](repeating: false, count: offsets.count)
        out.withUnsafeMutableBufferPointer { grid in
          tileOK.withUnsafeMutableBufferPointer { ok in
            // Tiles decode independently; a cold Iceland fetch decodes 8 of
            // them (~50 MB inflated), and this sits on the critical path of
            // a move — spread it across cores like the stitcher does.
            DispatchQueue.concurrentPerform(iterations: offsets.count) { t in
                guard let tile = decodeTile(d, offset: offsets[t], count: counts[t],
                                            tileW: tileW, tileH: tileH) else { return }
                ok[t] = true
                let tr = t / tilesAcross, tc = t % tilesAcross
                let rowLo = tr * tileH, colLo = tc * tileW
                let rows = min(tileH, height - rowLo)
                let cols = min(tileW, width - colLo)   // edge tiles are padded
                for r in 0..<rows {
                    let src = r * tileW
                    let dst = (rowLo + r) * width + colLo
                    for c in 0..<cols { grid[dst + c] = tile[src + c] }
                }
            }
          }
        }
        guard tileOK.allSatisfy({ $0 }) else { throw ConvertError.decodeFailed }
        return FloatGrid(values: out, width: width, height: height)
    }

    /// One deflate tile → floats: inflate, undo horizontal byte differencing,
    /// reassemble each float from its four byte planes (predictor 3 stores a
    /// row as [MSB plane][…][LSB plane] so the diffs are tiny).
    private static func decodeTile(_ d: Data, offset: Int, count: Int,
                                   tileW: Int, tileH: Int) -> [Float]? {
        guard offset > 0, count > 2, d.count >= offset + count else { return nil }
        // Compression 8 is a zlib stream: 2-byte header, then the raw
        // deflate Apple's Compression framework speaks (trailing adler is
        // ignored — the exact destination capacity ends the decode first).
        let capacity = tileW * tileH * 4
        var bytes = [UInt8](repeating: 0, count: capacity)
        let written = d.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&bytes, capacity,
                                             base + offset + 2, count - 2,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written == capacity else { return nil }

        var out = [Float](repeating: 0, count: tileW * tileH)
        let rowBytes = tileW * 4
        for r in 0..<tileH {
            let base = r * rowBytes
            for i in 1..<rowBytes { bytes[base + i] = bytes[base + i] &+ bytes[base + i - 1] }
            let p0 = base, p1 = base + tileW, p2 = base + 2 * tileW, p3 = base + 3 * tileW
            for c in 0..<tileW {
                let bits = UInt32(bytes[p0 + c]) << 24 | UInt32(bytes[p1 + c]) << 16
                    | UInt32(bytes[p2 + c]) << 8 | UInt32(bytes[p3 + c])
                out[r * tileW + c] = Float(bitPattern: bits)
            }
        }
        return out
    }

    // MARK: Resample to the SRTM1 post grid

    /// w×h float grid (posts at the tile's NW corner, 1°/h ″ lat × 1°/w ″ lon
    /// steps) → 3601×3601 big-endian Int16 SRTM1 bytes. Bilinear along each
    /// axis; the south/east edge posts (which Copernicus leaves to the
    /// neighbouring tile) clamp to the last real post. Non-finite or
    /// deep-negative (nodata) samples become the SRTM void sentinel so the
    /// stitcher's fillVoids treats them exactly like an SRTM void.
    static func resampleToHGT(_ v: [Float], width w: Int, height h: Int) -> Data {
        let n = 3601
        var out = [UInt8](repeating: 0, count: n * n * 2)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: n) { r in
                let u = Double(r) * Double(h) / 3600.0
                let r0 = min(h - 1, Int(u)), r1 = min(h - 1, r0 + 1)
                let fr = Float(u - Double(r0))
                for c in 0..<n {
                    let x = Double(c) * Double(w) / 3600.0
                    let c0 = min(w - 1, Int(x)), c1 = min(w - 1, c0 + 1)
                    let fx = Float(x - Double(c0))
                    let top = v[r0 * w + c0] * (1 - fx) + v[r0 * w + c1] * fx
                    let bot = v[r1 * w + c0] * (1 - fx) + v[r1 * w + c1] * fx
                    let f = top * (1 - fr) + bot * fr
                    let s: Int16
                    if !f.isFinite || f < -30000 { s = -32768 }   // void sentinel
                    else { s = Int16(max(-30000, min(32767, f.rounded()))) }
                    let o = (r * n + c) * 2
                    buf[o] = UInt8(truncatingIfNeeded: Int(s) >> 8)
                    buf[o + 1] = UInt8(truncatingIfNeeded: Int(s))
                }
            }
        }
        return Data(out)
    }

    // MARK: gzip encode (mirror of DEMFetcher.gunzip — Compression speaks
    // raw deflate, so wrap it in the gzip container by hand)

    /// The exact 10-byte gzip header `gzip(_:)` writes (no flags, mtime 0).
    /// Doubles as the converter's provenance mark: skadi's server-side gzip
    /// always carries FNAME + a real mtime, so a cached HIGH-LATITUDE tile
    /// without this header is a coarse pre-supplement skadi file that should
    /// be refetched — see the freshness gates in `DEMFetcher`.
    static let gzipHeader = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])

    static func isConverted(_ data: Data) -> Bool {
        data.count > gzipHeader.count && data.prefix(gzipHeader.count) == gzipHeader
    }

    static func gzip(_ data: Data) -> Data? {
        let capacity = data.count + 4096
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, capacity, base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        var out = gzipHeader
        out.append(contentsOf: dst[0..<written])
        var crc = crc32(data).littleEndian
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
