import Foundation

/// Static peak-pack distribution backed by bundled resources or Apple-hosted
/// On-Demand Resources. Packs are immutable files generated offline from merged
/// gazetteers, so runtime lookup does not require an API or CDN. (Ported from
/// RidgeLine.)
enum PeakPackService {
    struct Manifest: Decodable {
        let version: Int
        let packs: [Pack]
    }

    struct Pack: Decodable, Hashable, Sendable {
        let id: String
        let name: String
        let file: String
        let tag: String?
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double

        var fileBaseName: String {
            URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        }

        var fileExtension: String {
            URL(fileURLWithPath: file).pathExtension
        }

        func intersects(latitude lat: Double, longitude lon: Double, radiusKm: Double) -> Bool {
            let latDelta = radiusKm / 111
            let lonDelta = radiusKm / (111 * max(cos(lat * .pi / 180), 0.001))
            return maxLatitude >= lat - latDelta
                && minLatitude <= lat + latDelta
                && maxLongitude >= lon - lonDelta
                && minLongitude <= lon + lonDelta
        }
    }

    private static let manifestResource = "peak-packs"
    private static let cacheVersion = "v1"

    static func cachedPeaks(aroundLatitude lat: Double, longitude lon: Double, radiusKm: Double) -> [Peak] {
        // Linear-time dedup (see OSMPeakService.LinearPeakMerge) — the old
        // contains(where:) scan was the same O(n²) pattern that took seconds
        // over the OSM tile caches.
        var merge = OSMPeakService.LinearPeakMerge()
        for pack in packsCovering(latitude: lat, longitude: lon, radiusKm: radiusKm) {
            guard let peaks = loadCachedPack(pack) ?? loadBundledPack(pack) else { continue }
            for peak in peaks where GeoMath.distanceMeters(
                fromLatitude: lat, fromLongitude: lon,
                toLatitude: peak.latitude, toLongitude: peak.longitude
            ) <= radiusKm * 1000 {
                merge.insert(peak)
            }
        }
        return merge.peaks
    }

    static func allCachedPeaks() -> [Peak] {
        var merge = OSMPeakService.LinearPeakMerge()
        for pack in manifest()?.packs ?? [] {
            guard let peaks = loadCachedPack(pack) else { continue }
            for peak in peaks { merge.insert(peak) }
        }
        return merge.peaks
    }

    static func packsCovering(latitude lat: Double, longitude lon: Double, radiusKm: Double) -> [Pack] {
        (manifest()?.packs ?? []).filter { $0.intersects(latitude: lat, longitude: lon, radiusKm: radiusKm) }
    }

    /// The bundled manifest is immutable for the process lifetime — decode it
    /// once instead of re-reading the JSON on every coverage query.
    private static let cachedManifest: Manifest? = {
        guard let url = Bundle.main.url(forResource: manifestResource, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    private static func manifest() -> Manifest? { cachedManifest }

    private static func loadBundledPack(_ pack: Pack) -> [Peak]? {
        guard let url = Bundle.main.url(forResource: pack.fileBaseName, withExtension: pack.fileExtension),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return decodePack(data)
    }

    private static func loadCachedPack(_ pack: Pack) -> [Peak]? {
        guard let data = try? Data(contentsOf: cacheURL(for: pack)) else { return nil }
        return decodePack(data)
    }

    private static func decodePack(_ data: Data) -> [Peak]? {
        // Sniff the first non-whitespace byte ('[' = bare array, '{' = wrapped)
        // — blindly trying the wrong shape first paid a complete failed parse
        // of a multi-MB pack on every load.
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        if data.first(where: { !whitespace.contains($0) }) == UInt8(ascii: "{") {
            return (try? JSONDecoder().decode(PeakPackPayload.self, from: data))?.peaks
        }
        if let peaks = try? JSONDecoder().decode([Peak].self, from: data) {
            return peaks
        }
        return (try? JSONDecoder().decode(PeakPackPayload.self, from: data))?.peaks
    }

    private struct PeakPackPayload: Decodable {
        let peaks: [Peak]
    }

    private static func cacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("peakpacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for pack: Pack) -> URL {
        cacheDirectory().appendingPathComponent("\(cacheVersion)_\(pack.id).json")
    }
}
