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
        var merged: [Peak] = []
        for pack in packsCovering(latitude: lat, longitude: lon, radiusKm: radiusKm) {
            guard let peaks = loadCachedPack(pack) ?? loadBundledPack(pack) else { continue }
            append(peaks, to: &merged, latitude: lat, longitude: lon, radiusKm: radiusKm)
        }
        return merged
    }

    static func allCachedPeaks() -> [Peak] {
        var merged: [Peak] = []
        for pack in manifest()?.packs ?? [] {
            guard let peaks = loadCachedPack(pack) else { continue }
            append(peaks, to: &merged)
        }
        return merged
    }

    @discardableResult
    static func downloadRegion(latitude lat: Double, longitude lon: Double, radiusKm: Double) async -> [Peak] {
        let packs = packsCovering(latitude: lat, longitude: lon, radiusKm: radiusKm)
        var merged: [Peak] = []
        for pack in packs {
            guard let peaks = await ensurePack(pack) else { continue }
            append(peaks, to: &merged, latitude: lat, longitude: lon, radiusKm: radiusKm)
        }
        return merged
    }

    static func downloadedBytes() -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory(), includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.reduce(0) { total, url in
            total + (((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
        }
    }

    @discardableResult
    static func clearCache() -> Int {
        let freed = downloadedBytes()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory(), includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }

    static func availablePackCount() -> Int {
        manifest()?.packs.count ?? 0
    }

    static func packsCovering(latitude lat: Double, longitude lon: Double, radiusKm: Double) -> [Pack] {
        (manifest()?.packs ?? []).filter { $0.intersects(latitude: lat, longitude: lon, radiusKm: radiusKm) }
    }

    private static func ensurePack(_ pack: Pack) async -> [Peak]? {
        if let cached = loadCachedPack(pack) { return cached }
        if let bundled = loadBundledPack(pack) {
            saveCached(bundled, pack: pack)
            return bundled
        }

        guard let tag = pack.tag, !tag.isEmpty else { return nil }
        let request = NSBundleResourceRequest(tags: [tag])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
        do {
            try await request.beginAccessingResources()
            defer { request.endAccessingResources() }
            guard let peaks = loadBundledPack(pack) else { return nil }
            saveCached(peaks, pack: pack)
            return peaks
        } catch {
            return nil
        }
    }

    private static func manifest() -> Manifest? {
        guard let url = Bundle.main.url(forResource: manifestResource, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

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
        if let peaks = try? JSONDecoder().decode([Peak].self, from: data) {
            return peaks
        }
        if let wrapped = try? JSONDecoder().decode(PeakPackPayload.self, from: data) {
            return wrapped.peaks
        }
        return nil
    }

    private struct PeakPackPayload: Decodable {
        let peaks: [Peak]
    }

    private static func saveCached(_ peaks: [Peak], pack: Pack) {
        guard let data = try? JSONEncoder().encode(peaks) else { return }
        try? data.write(to: cacheURL(for: pack), options: .atomic)
    }

    private static func append(_ peaks: [Peak], to merged: inout [Peak], latitude lat: Double, longitude lon: Double, radiusKm: Double) {
        for peak in peaks where GeoMath.distanceMeters(
            fromLatitude: lat, fromLongitude: lon,
            toLatitude: peak.latitude, toLongitude: peak.longitude
        ) <= radiusKm * 1000 && !merged.contains(where: { samePeak($0, peak) }) {
            merged.append(peak)
        }
    }

    private static func append(_ peaks: [Peak], to merged: inout [Peak]) {
        for peak in peaks where !merged.contains(where: { samePeak($0, peak) }) {
            merged.append(peak)
        }
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

    private static func samePeak(_ a: Peak, _ b: Peak) -> Bool {
        if a.id == b.id { return true }
        guard a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame else { return false }
        return GeoMath.distanceMeters(
            fromLatitude: a.latitude, fromLongitude: a.longitude,
            toLatitude: b.latitude, toLongitude: b.longitude
        ) < 200
    }
}
