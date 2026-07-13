import Foundation

/// A user-downloaded offline terrain region: the SRTM tiles around a viewpoint,
/// kept in `DEMFetcher.regionStoreDir` so that area renders with no connection.
struct DownloadedRegion: Codable, Identifiable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusKm: Double
    var tileNames: [String]   // persistent tiles this region brought in
    var byteCount: Int
    var date: Date
}

/// Manages downloaded offline regions: their manifest, downloading (with progress),
/// and deletion (reference-counting shared tiles). Drives `RegionManagerView`.
@MainActor
final class RegionStore: ObservableObject {
    @Published private(set) var regions: [DownloadedRegion] = []
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String?

    private let manifestURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("regions.json")
    }()

    init() { load() }

    /// Disk used by the persistent tile store, human-readable.
    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: DEMFetcher.downloadedBytes(), countStyle: .file)
    }

    func sizeText(_ region: DownloadedRegion) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(region.byteCount), countStyle: .file)
    }

    /// True if (lat, lon) is already covered by a downloaded region.
    func isCovered(latitude: Double, longitude: Double) -> Bool {
        regions.contains { r in
            let dLat = (latitude - r.latitude) * 111_320
            let dLon = (longitude - r.longitude) * 111_320 * Foundation.cos(r.latitude * .pi / 180)
            return (dLat * dLat + dLon * dLon).squareRoot() <= r.radiusKm * 1000 * 0.7
        }
    }

    /// Download the SRTM tiles in a selected lat/lon area into the persistent store.
    func download(name: String, south: Double, north: Double, west: Double, east: Double) async {
        guard !isDownloading else { return }
        isDownloading = true; progress = 0; statusText = "Preparing…"

        let tiles = DEMFetcher.regionTiles(south: south, north: north, west: west, east: east)
        var stored: [String] = []
        var bytes = 0
        var anyFailed = false
        for (i, t) in tiles.enumerated() {
            statusText = "Downloading tile \(i + 1) of \(tiles.count)…"
            if let n = await DEMFetcher.ensurePersistentTile(tLat: t.tLat, tLon: t.tLon) {
                if n > 0 {
                    stored.append(DEMFetcher.tileFileName(tLat: t.tLat, tLon: t.tLon))
                    bytes += n
                }
            } else {
                anyFailed = true
            }
            progress = Double(i + 1) / Double(tiles.count)
        }

        // Store the area's centre + half-diagonal radius (for the list + coverage test).
        let cLat = (south + north) / 2, cLon = (west + east) / 2
        let dLatKm = (north - south) * 111.32
        let dLonKm = (east - west) * 111.32 * Foundation.cos(cLat * .pi / 180)
        let radiusKm = (dLatKm * dLatKm + dLonKm * dLonKm).squareRoot() / 2

        // (No peak-label download: every named peak and lake worldwide ships in the
        // app's bundled database — labels are already instant and offline. Only the
        // DEM tiles above need fetching for offline terrain.)

        let region = DownloadedRegion(
            id: UUID().uuidString, name: name, latitude: cLat, longitude: cLon,
            radiusKm: radiusKm, tileNames: stored, byteCount: bytes, date: Date())
        regions.insert(region, at: 0)
        save()

        statusText = anyFailed ? "Some tiles failed — try again on Wi-Fi." : nil
        isDownloading = false
        progress = 0
    }

    /// Remove a region; delete only the tiles no other region still uses.
    func delete(_ region: DownloadedRegion) {
        regions.removeAll { $0.id == region.id }
        let stillUsed = Set(regions.flatMap { $0.tileNames })
        for name in region.tileNames where !stillUsed.contains(name) {
            DEMFetcher.deletePersistentTile(name: name)
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedRegion].self, from: data) else { return }
        regions = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(regions) { try? data.write(to: manifestURL) }
    }
}
