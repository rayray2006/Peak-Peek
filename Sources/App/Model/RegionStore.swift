import Foundation
import MapKit

/// A lat/lon rectangle — the exact area a download selection covered. Regions
/// carry one box per constituent download (merged regions carry several), and
/// the map draws precisely these, not the underlying 1° tile grid.
struct RegionBox: Codable, Hashable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double

    func intersects(_ other: RegionBox) -> Bool {
        south < other.north && other.south < north
            && west < other.east && other.west < east
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north
            && longitude >= west && longitude <= east
    }
}

/// A user-downloaded offline terrain region: the SRTM tiles around a viewpoint,
/// kept in `DEMFetcher.regionStoreDir` so that area renders with no connection.
/// Overlapping downloads merge into ONE region (union of boxes + tiles).
struct DownloadedRegion: Codable, Identifiable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusKm: Double
    var tileNames: [String]   // persistent tiles this region brought in
    var byteCount: Int
    var date: Date
    /// The exact selected areas (several after merges). Older manifests lack
    /// this key; `RegionStore.load()` backfills from the tile extents.
    var boxes: [RegionBox]

    init(id: String, name: String, latitude: Double, longitude: Double,
         radiusKm: Double, tileNames: [String], byteCount: Int, date: Date,
         boxes: [RegionBox]) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusKm = radiusKm
        self.tileNames = tileNames
        self.byteCount = byteCount
        self.date = date
        self.boxes = boxes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radiusKm = try c.decode(Double.self, forKey: .radiusKm)
        tileNames = try c.decode([String].self, forKey: .tileNames)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        date = try c.decode(Date.self, forKey: .date)
        boxes = try c.decodeIfPresent([RegionBox].self, forKey: .boxes) ?? []
    }
}

/// Manages downloaded offline regions: their manifest, downloading (with progress),
/// merging overlapping areas, and deletion (reference-counting shared tiles).
/// Drives `RegionManagerView`.
@MainActor
final class RegionStore: ObservableObject {
    @Published private(set) var regions: [DownloadedRegion] = []
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String?
    /// Disk used by the persistent tile store, human-readable. Cached: computing
    /// it walks the store directory, which must not happen per SwiftUI render.
    @Published private(set) var totalSizeText: String = ""

    private let manifestURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("regions.json")
    }()

    init() {
        load()
        sweepOrphanedTiles()
        refreshTotalSize()
    }

    private func refreshTotalSize() {
        totalSizeText = ByteCountFormatter.string(
            fromByteCount: DEMFetcher.downloadedBytes(), countStyle: .file)
    }

    /// Tiles sitting in the persistent store that no region references — left
    /// behind by interrupted downloads or lost manifests. They made "Storage"
    /// read non-zero with "No regions downloaded"; reclaim them at startup.
    private func sweepOrphanedTiles() {
        let referenced = Set(regions.flatMap(\.tileNames))
        for name in DEMFetcher.persistentTileNames() where !referenced.contains(name) {
            DEMFetcher.deletePersistentTile(name: name)
        }
    }

    func sizeText(_ region: DownloadedRegion) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(region.byteCount), countStyle: .file)
    }

    /// True if (lat, lon) is inside a downloaded region's exact area.
    func isCovered(latitude: Double, longitude: Double) -> Bool {
        regions.contains { r in
            r.boxes.contains { $0.contains(latitude: latitude, longitude: longitude) }
        }
    }

    /// Download the SRTM tiles in a selected lat/lon area into the persistent
    /// store. If the area overlaps existing regions, everything merges into
    /// ONE region: union of boxes and tiles, one row in the saved list.
    func download(name: String, south: Double, north: Double, west: Double, east: Double) async {
        guard !isDownloading else { return }
        isDownloading = true; progress = 0; statusText = "Preparing…"

        let tiles = DEMFetcher.regionTiles(south: south, north: north, west: west, east: east)
        var stored: [String] = []
        var anyFailed = false
        for (i, t) in tiles.enumerated() {
            statusText = "Downloading tile \(i + 1) of \(tiles.count)…"
            if let n = await DEMFetcher.ensurePersistentTile(tLat: t.tLat, tLon: t.tLon) {
                if n > 0 {
                    stored.append(DEMFetcher.tileFileName(tLat: t.tLat, tLon: t.tLon))
                }
            } else {
                anyFailed = true
            }
            progress = Double(i + 1) / Double(tiles.count)
        }

        // Best-effort offline map imagery for the pin-drop map: snapshotting
        // the area routes its tiles through MapKit's own disk cache.
        statusText = "Caching map imagery…"
        await Self.warmMapCache(south: south, north: north, west: west, east: east)

        let newBox = RegionBox(south: min(south, north), west: min(west, east),
                               north: max(south, north), east: max(west, east))

        // Merge with every existing region the new area overlaps.
        let touching = regions.filter { $0.boxes.contains { $0.intersects(newBox) } }
        let rest = regions.filter { r in !touching.contains { $0.id == r.id } }

        var boxes = touching.flatMap(\.boxes) + [newBox]
        // Drop boxes fully inside another (re-downloading a covered corner
        // shouldn't accumulate clutter).
        boxes = boxes.filter { b in
            !boxes.contains { o in
                o != b && o.south <= b.south && o.west <= b.west
                    && o.north >= b.north && o.east >= b.east
            }
        }
        let tileUnion = Array(Set(touching.flatMap(\.tileNames) + stored))
        // Truthful size: what the union's tiles actually occupy on disk.
        let bytes = tileUnion.reduce(0) { $0 + DEMFetcher.persistentTileBytes(name: $1) }

        // A merged region keeps the biggest constituent's name (the
        // established one); a fresh region takes the geocoded name.
        let mergedName = touching.max(by: { $0.byteCount < $1.byteCount })?.name ?? name

        // Centre + half-diagonal of the union's bounding box (list + tag anchor).
        let s = boxes.map(\.south).min() ?? newBox.south
        let n = boxes.map(\.north).max() ?? newBox.north
        let w = boxes.map(\.west).min() ?? newBox.west
        let e = boxes.map(\.east).max() ?? newBox.east
        let cLat = (s + n) / 2, cLon = (w + e) / 2
        let dLatKm = (n - s) * 111.32
        let dLonKm = (e - w) * 111.32 * Foundation.cos(cLat * .pi / 180)
        let radiusKm = (dLatKm * dLatKm + dLonKm * dLonKm).squareRoot() / 2

        // (No peak-label download: every named peak and lake worldwide ships in the
        // app's bundled database — labels are already instant and offline. Only the
        // DEM tiles above need fetching for offline terrain.)

        let region = DownloadedRegion(
            id: UUID().uuidString, name: mergedName, latitude: cLat, longitude: cLon,
            radiusKm: radiusKm, tileNames: tileUnion, byteCount: bytes, date: Date(),
            boxes: boxes)
        regions = [region] + rest
        save()
        refreshTotalSize()

        statusText = anyFailed ? "Some tiles failed — try again on Wi-Fi." : nil
        isDownloading = false
        progress = 0
    }

    /// Low-res map imagery for the downloaded area, best effort: render the
    /// region (overview + four quadrants) through MKMapSnapshotter in the
    /// pin-drop map's hybrid style, which lands the tiles in MapKit's disk
    /// cache — offline, the teleport map then usually still shows the area.
    /// (Apple ships no public offline-maps API; this is the strongest
    /// available lever, not a guarantee.)
    nonisolated private static func warmMapCache(
        south: Double, north: Double, west: Double, east: Double
    ) async {
        let cLat = (south + north) / 2, cLon = (west + east) / 2
        let dLat = max(0.05, north - south), dLon = max(0.05, east - west)
        var regions = [MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: cLat, longitude: cLon),
            span: MKCoordinateSpan(latitudeDelta: dLat * 1.4, longitudeDelta: dLon * 1.4))]
        for (qy, qx) in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)] {
            regions.append(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: south + dLat * (0.25 + 0.5 * qy),
                                               longitude: west + dLon * (0.25 + 0.5 * qx)),
                span: MKCoordinateSpan(latitudeDelta: dLat * 0.55, longitudeDelta: dLon * 0.55)))
        }
        for region in regions {
            let opts = MKMapSnapshotter.Options()
            opts.region = region
            opts.size = CGSize(width: 640, height: 640)
            opts.preferredConfiguration = MKHybridMapConfiguration()
            _ = try? await MKMapSnapshotter(options: opts).start()
        }
    }

    /// Remove a region; delete only the tiles no other region still uses.
    func delete(_ region: DownloadedRegion) {
        regions.removeAll { $0.id == region.id }
        let stillUsed = Set(regions.flatMap { $0.tileNames })
        for name in region.tileNames where !stillUsed.contains(name) {
            DEMFetcher.deletePersistentTile(name: name)
        }
        save()
        refreshTotalSize()
    }

    // MARK: - Union geometry (for drawing)

    /// Decompose the union of (possibly overlapping) boxes into NON-overlapping
    /// rectangles — a vertical slab sweep. Filling these with one color shows
    /// the union seamlessly: no double-shaded intersections, no crossing edges.
    nonisolated static func unionRects(_ boxes: [RegionBox]) -> [RegionBox] {
        guard !boxes.isEmpty else { return [] }
        let xs = Array(Set(boxes.flatMap { [$0.west, $0.east] })).sorted()
        var out: [RegionBox] = []
        for i in 0..<(xs.count - 1) {
            let x0 = xs[i], x1 = xs[i + 1]
            guard x1 > x0 else { continue }
            let mid = (x0 + x1) / 2
            // Merge the y-intervals of every box spanning this slab.
            var intervals = boxes.filter { $0.west <= mid && mid <= $0.east }
                .map { (lo: $0.south, hi: $0.north) }
                .sorted { $0.lo < $1.lo }
            guard !intervals.isEmpty else { continue }
            var merged: [(lo: Double, hi: Double)] = [intervals.removeFirst()]
            for iv in intervals {
                if iv.lo <= merged[merged.count - 1].hi {
                    merged[merged.count - 1].hi = max(merged[merged.count - 1].hi, iv.hi)
                } else {
                    merged.append(iv)
                }
            }
            for m in merged {
                out.append(RegionBox(south: m.lo, west: x0, north: m.hi, east: x1))
            }
        }
        return out
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedRegion].self, from: data) else { return }
        // Backfill boxes for pre-box manifests: the extent of the region's
        // tiles is the best record of what was downloaded.
        regions = decoded.map { r in
            guard r.boxes.isEmpty else { return r }
            var r = r
            let coords = r.tileNames.compactMap { DEMFetcher.tileCoordinate(fromFileName: $0) }
            if let sLat = coords.map(\.tLat).min(), let nLat = coords.map(\.tLat).max(),
               let wLon = coords.map(\.tLon).min(), let eLon = coords.map(\.tLon).max() {
                r.boxes = [RegionBox(south: Double(sLat), west: Double(wLon),
                                     north: Double(nLat + 1), east: Double(eLon + 1))]
            }
            return r
        }
    }

    private func save() {
        // A silently failed write orphans downloaded tiles (the region list
        // forgets them, so delete's refcount never frees them) — surface it.
        do {
            let data = try JSONEncoder().encode(regions)
            try data.write(to: manifestURL)
        } catch {
            NSLog("RegionStore: manifest save failed: \(error)")
            statusText = "Couldn't save the region list."
        }
    }
}
