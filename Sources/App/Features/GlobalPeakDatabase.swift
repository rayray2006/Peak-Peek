import Foundation

/// Reader for the bundled global peak database (`peaks_global.bin`), built once
/// by `Tools/PeakDB/build_peak_db.py` from an OSM extract. This replaces the
/// runtime Overpass fetch as the label source: every named peak on Earth is
/// available locally in milliseconds, offline, with no server costs.
///
/// The file is memory-mapped (never fully loaded); a radius query touches only
/// the 1°×1° cells covering the query box and decodes just those records.
///
/// Format (little-endian; see the Python script for the writer):
///   header:  "PKDB" | u16 version=2 | u16 reserved | u32 cellCount | u32 peakCount
///   index:   cellCount × (u32 key | u32 offset | u32 count), sorted by key.
///            key = (floor(lat)+90)·360 + (floor(lon)+180); offset is relative
///            to the records region.
///   records: i64 osmId | i32 latE7 | i32 lonE7 | i16 elevM | i16 promM |
///            u8 kind | u8 nameLen | name UTF-8.  -32768 = unknown elev/prom;
///            kind 0 = summit, 1 = saddle/gap (never summit-snapped).
struct GlobalPeakDatabase: Sendable {
    /// Shared instance backed by the bundled file; nil only if the resource is
    /// missing or malformed (the app then just has no global directory).
    static let shared: GlobalPeakDatabase? = {
        guard let url = Bundle.main.url(forResource: "peaks_global", withExtension: "bin")
        else { return nil }
        return GlobalPeakDatabase(url: url)
    }()

    /// Lakes + reservoirs (`lakes_global.bin`, built by the `lakes` subcommand of
    /// the same tool; ids are negative → "gn-…", unique vs peaks since GeoNames
    /// ids are global). Same format, same reader; "elevation" = surface elevation.
    static let lakes: GlobalPeakDatabase? = {
        guard let url = Bundle.main.url(forResource: "lakes_global", withExtension: "bin")
        else { return nil }
        return GlobalPeakDatabase(url: url)
    }()

    private static let unknown: Int16 = -32768
    private static let headerSize = 16
    private static let indexEntrySize = 12
    private static let recordFixedSize = 22

    private let data: Data
    /// cell key → (byte offset into the records region, record count)
    private let cells: [UInt32: (offset: Int, count: Int)]
    private let recordsStart: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count >= Self.headerSize else { return nil }
        let (cellCount, ok): (Int, Bool) = data.withUnsafeBytes { buf in
            guard buf.load(fromByteOffset: 0, as: UInt32.self).littleEndian == 0x42444B50, // "PKDB"
                  buf.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian == 2
            else { return (0, false) }
            return (Int(buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian), true)
        }
        guard ok, data.count >= Self.headerSize + cellCount * Self.indexEntrySize else { return nil }

        var cells: [UInt32: (offset: Int, count: Int)] = Dictionary(minimumCapacity: cellCount)
        data.withUnsafeBytes { buf in
            for i in 0..<cellCount {
                let base = Self.headerSize + i * Self.indexEntrySize
                let key = buf.loadUnaligned(fromByteOffset: base, as: UInt32.self).littleEndian
                let offset = buf.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self).littleEndian
                let count = buf.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self).littleEndian
                cells[key] = (Int(offset), Int(count))
            }
        }
        self.data = data
        self.cells = cells
        self.recordsStart = Self.headerSize + cellCount * Self.indexEntrySize
    }

    /// All peaks within `radius` meters of the given coordinate.
    func peaks(nearLatitude lat: Double, longitude lon: Double, withinMeters radius: Double) -> [Peak] {
        let (latDelta, lonDelta) = GeoMath.boundingDegreeDeltas(radiusMeters: radius, latitude: lat)
        let latLo = max(Int(floor(lat - latDelta)), -90)
        let latHi = min(Int(floor(lat + latDelta)), 89)
        let lonLo = Int(floor(lon - lonDelta)), lonHi = Int(floor(lon + lonDelta))

        var out: [Peak] = []
        for cellLat in latLo...latHi {
            guard lonHi - lonLo < 360 else {                     // polar cap: full ring
                for cellLon in -180...179 {
                    appendPeaks(cellLat: cellLat, cellLon: cellLon,
                                lat: lat, lon: lon, radius: radius, into: &out)
                }
                continue
            }
            for rawLon in lonLo...lonHi {                        // wrap across the date line
                let cellLon = (rawLon + 540) % 360 - 180
                appendPeaks(cellLat: cellLat, cellLon: cellLon,
                            lat: lat, lon: lon, radius: radius, into: &out)
            }
        }
        return out
    }

    /// Case-insensitive substring name search over EVERY record in the file —
    /// the whole world, no radius. Scans the raw mapped bytes (ASCII case-folded;
    /// no String is allocated until a record matches), so ~1.5M records resolve
    /// in tens of milliseconds. Results in file order; the caller ranks them.
    func search(nameContains query: String, limit: Int = 400) -> [Peak] {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty else { return [] }
        var out: [Peak] = []
        data.withUnsafeBytes { buf in
            var cursor = recordsStart
            while cursor + Self.recordFixedSize <= buf.count, out.count < limit {
                let nameLen = Int(buf.loadUnaligned(fromByteOffset: cursor + 21, as: UInt8.self))
                let nameStart = cursor + Self.recordFixedSize
                let next = nameStart + nameLen
                guard next <= buf.count else { break }
                if nameLen >= needle.count,
                   Self.containsFolded(buf, start: nameStart, length: nameLen, needle: needle) {
                    let osmId = buf.loadUnaligned(fromByteOffset: cursor, as: Int64.self).littleEndian
                    let pLat = Double(buf.loadUnaligned(fromByteOffset: cursor + 8, as: Int32.self).littleEndian) * 1e-7
                    let pLon = Double(buf.loadUnaligned(fromByteOffset: cursor + 12, as: Int32.self).littleEndian) * 1e-7
                    let elev = buf.loadUnaligned(fromByteOffset: cursor + 16, as: Int16.self).littleEndian
                    let prom = buf.loadUnaligned(fromByteOffset: cursor + 18, as: Int16.self).littleEndian
                    let kind = buf.loadUnaligned(fromByteOffset: cursor + 20, as: UInt8.self)
                    if let name = String(bytes: buf[nameStart..<next], encoding: .utf8) {
                        out.append(Peak(
                            id: osmId >= 0 ? "osm-\(osmId)" : "gn-\(-osmId)",
                            name: name, latitude: pLat, longitude: pLon,
                            elevationMeters: elev == Self.unknown ? 0 : Double(elev),
                            prominenceMeters: prom == Self.unknown ? nil : Double(prom),
                            isSaddle: kind == 1))
                    }
                }
                cursor = next
            }
        }
        return out
    }

    /// ASCII-case-insensitive substring test over raw UTF-8 (non-ASCII bytes
    /// compare exactly — accented names need the accent typed, acceptable for v1).
    private static func containsFolded(
        _ buf: UnsafeRawBufferPointer, start: Int, length: Int, needle: [UInt8]
    ) -> Bool {
        func fold(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        let last = start + length - needle.count
        var i = start
        while i <= last {
            var j = 0
            while j < needle.count, fold(buf[i + j]) == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }

    private func appendPeaks(cellLat: Int, cellLon: Int,
                             lat: Double, lon: Double, radius: Double, into out: inout [Peak]) {
        let key = UInt32((cellLat + 90) * 360 + (cellLon + 180))
        guard let cell = cells[key] else { return }
        data.withUnsafeBytes { buf in
            var cursor = recordsStart + cell.offset
            for _ in 0..<cell.count {
                guard cursor + Self.recordFixedSize <= buf.count else { return }
                let osmId = buf.loadUnaligned(fromByteOffset: cursor, as: Int64.self).littleEndian
                let pLat = Double(buf.loadUnaligned(fromByteOffset: cursor + 8, as: Int32.self).littleEndian) * 1e-7
                let pLon = Double(buf.loadUnaligned(fromByteOffset: cursor + 12, as: Int32.self).littleEndian) * 1e-7
                let elev = buf.loadUnaligned(fromByteOffset: cursor + 16, as: Int16.self).littleEndian
                let prom = buf.loadUnaligned(fromByteOffset: cursor + 18, as: Int16.self).littleEndian
                let kind = buf.loadUnaligned(fromByteOffset: cursor + 20, as: UInt8.self)
                let nameLen = Int(buf.loadUnaligned(fromByteOffset: cursor + 21, as: UInt8.self))
                let nameStart = cursor + Self.recordFixedSize
                cursor = nameStart + nameLen
                guard cursor <= buf.count else { return }

                // Cheap box reject before the exact distance test.
                guard abs(pLat - lat) * 111_000 <= radius,
                      GeoMath.distanceMeters(fromLatitude: lat, fromLongitude: lon,
                                             toLatitude: pLat, toLongitude: pLon) <= radius,
                      let name = String(bytes: buf[nameStart..<nameStart + nameLen], encoding: .utf8)
                else { continue }
                // Positive ids are OSM node ids; negative ids are GeoNames features
                // merged in at pack time (see build_peak_db.py).
                out.append(Peak(
                    id: osmId >= 0 ? "osm-\(osmId)" : "gn-\(-osmId)",
                    name: name, latitude: pLat, longitude: pLon,
                    elevationMeters: elev == Self.unknown ? 0 : Double(elev),
                    prominenceMeters: prom == Self.unknown ? nil : Double(prom),
                    isSaddle: kind == 1))
            }
        }
    }
}
