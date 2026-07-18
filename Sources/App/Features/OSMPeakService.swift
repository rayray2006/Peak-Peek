import Foundation

/// Reads the on-disk peak caches left by the old OpenStreetMap **Overpass**
/// fetch path. The runtime download machinery itself is gone — the bundled
/// `GlobalPeakDatabase` (every named OSM peak on Earth) replaced it — but
/// devices that downloaded regions before the switch still have those caches,
/// and they keep contributing to the directory/labels here.
enum OSMPeakService {

    private static let cacheVersion = "v2"

    static func cachedPeaks(aroundLatitude lat: Double, longitude lon: Double, radiusKm: Double) -> [Peak]? {
        let dir = cacheDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        var merge = LinearPeakMerge()
        for url in urls where url.pathExtension == "json" {
            guard let entry = cacheEntry(for: url),
                  GeoMath.distanceMeters(
                    fromLatitude: lat, fromLongitude: lon,
                    toLatitude: entry.latitude, toLongitude: entry.longitude
                  ) <= (radiusKm + entry.radiusKm) * 1000
            else { continue }
            guard let data = try? Data(contentsOf: url),
                  let peaks = try? JSONDecoder().decode([Peak].self, from: data) else { continue }
            for peak in peaks where GeoMath.distanceMeters(
                fromLatitude: lat, fromLongitude: lon,
                toLatitude: peak.latitude, toLongitude: peak.longitude
            ) <= radiusKm * 1000 {
                merge.insert(peak)
            }
        }
        return merge.peaks.isEmpty ? nil : merge.peaks
    }

    static func allCachedPeaks() -> [Peak] {
        let dir = cacheDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        var merge = LinearPeakMerge()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let peaks = try? JSONDecoder().decode([Peak].self, from: data) else { continue }
            for peak in peaks { merge.insert(peak) }
        }
        return merge.peaks
    }

    /// Linear-time replacement for the old `merged.contains(where: samePeak)`
    /// dedup, which was O(n²) — with the multi-megabyte tile caches a device
    /// accumulates, that quadratic scan (name compare + haversine per pair) took
    /// SECONDS and delayed labels long after the terrain was up. Same semantics:
    /// drop exact-id duplicates and same-name peaks within 200 m (tile overlap),
    /// via an id set + a ~550 m grid bucketed by normalized name.
    struct LinearPeakMerge {
        private(set) var peaks: [Peak] = []
        private var ids = Set<String>()
        private var nameBuckets: [String: [Peak]] = [:]

        private static func bucketKey(_ name: String, _ latCell: Int, _ lonCell: Int) -> String {
            "\(latCell):\(lonCell):\(name)"
        }

        mutating func insert(_ peak: Peak) {
            guard ids.insert(peak.id).inserted else { return }
            let name = peak.name.lowercased()
            let latCell = Int((peak.latitude * 200).rounded())
            let lonCell = Int((peak.longitude * 200).rounded())
            for dy in -1...1 {
                for dx in -1...1 {
                    let key = Self.bucketKey(name, latCell + dy, lonCell + dx)
                    if nameBuckets[key]?.contains(where: {
                        GeoMath.distanceMeters(
                            fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                            toLatitude: peak.latitude, toLongitude: peak.longitude
                        ) < 200
                    }) == true { return }
                }
            }
            peaks.append(peak)
            nameBuckets[Self.bucketKey(name, latCell, lonCell), default: []].append(peak)
        }
    }

    // MARK: - Disk cache

    private static func cacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("peakcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// (lat, lon, radius) encoded in a cache file's name by the old fetch path.
    private static func cacheEntry(for url: URL) -> (latitude: Double, longitude: Double, radiusKm: Double)? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count == 4, parts[0] == Substring(cacheVersion),
              let lat = Double(parts[1]),
              let lon = Double(parts[2]),
              parts[3].first == "r",
              let radius = Double(parts[3].dropFirst())
        else { return nil }
        return (lat, lon, radius)
    }
}
