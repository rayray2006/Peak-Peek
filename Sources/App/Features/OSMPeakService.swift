import Foundation

/// Fetches named peaks (and passes/volcanoes) around a coordinate from the
/// OpenStreetMap **Overpass API**. Scales the directory from the bundled starter
/// set to OSM's millions of named summits. Results decode to `Peak` and are
/// disk-cached per snapped cell, so each region downloads once and then works
/// offline. (Ported from RidgeLine.)
enum OSMPeakService {

    /// Public Overpass instances tried in order — the main one 504s under load.
    static let endpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]

    /// Public Overpass instances time out past ~100 km of "every named peak", so
    /// wide catalogs are fetched as overlapping 80 km circles.
    static let maxRadiusKm: Double = 80
    private static let cacheVersion = "v2"

    static func peaks(
        aroundLatitude lat: Double, longitude lon: Double, radiusKm: Double
    ) async throws -> [Peak] {
        let requestedRadius = min(radiusKm, maxRadiusKm)
        if let cached = loadCached(lat: lat, lon: lon, radiusKm: requestedRadius) { return cached }
        let query = overpassQuery(lat: lat, lon: lon, radiusKm: requestedRadius)
        var lastError: Error = URLError(.badServerResponse)
        for endpoint in endpoints {
            do {
                let data = try await fetch(query: query, from: endpoint)
                let peaks = try parse(data: data)
                // A server-side timeout still returns 200 with zero elements —
                // never cache it, and give the mirrors a chance.
                guard !peaks.isEmpty else { throw URLError(.badServerResponse) }
                saveCached(peaks, lat: lat, lon: lon, radiusKm: requestedRadius)
                return peaks
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Wide peak catalogs are fetched as overlapping 80 km Overpass circles.
    static func peaksTiled(
        aroundLatitude lat: Double, longitude lon: Double, radiusKm: Double,
        onPartial: (@Sendable ([Peak]) -> Void)? = nil
    ) async throws -> [Peak] {
        if radiusKm <= maxRadiusKm {
            let fetched = try await peaks(aroundLatitude: lat, longitude: lon, radiusKm: radiusKm)
            onPartial?(fetched)
            return fetched
        }

        var merged: [Peak] = []
        var failures = 0
        for center in tileCenters(latitude: lat, longitude: lon, radiusKm: radiusKm) {
            try Task.checkCancellation()
            do {
                let fetched = try await peaks(
                    aroundLatitude: center.latitude,
                    longitude: center.longitude,
                    radiusKm: maxRadiusKm
                )
                for peak in fetched where GeoMath.distanceMeters(
                    fromLatitude: lat, fromLongitude: lon,
                    toLatitude: peak.latitude, toLongitude: peak.longitude
                ) <= radiusKm * 1000 && !merged.contains(where: { samePeak($0, peak) }) {
                    merged.append(peak)
                }
                if !merged.isEmpty { onPartial?(merged) }
            } catch {
                if Task.isCancelled || (error as? CancellationError) != nil {
                    throw CancellationError()
                }
                failures += 1
            }
        }

        try Task.checkCancellation()
        guard !merged.isEmpty || failures == 0 else { throw URLError(.badServerResponse) }
        return merged
    }

    static func cachedPeaks(aroundLatitude lat: Double, longitude lon: Double) -> [Peak]? {
        cachedPeaks(
            aroundLatitude: lat,
            longitude: lon,
            radiusKm: PeakSearch.maxRangeMeters / 1000
        )
    }

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

    @discardableResult
    static func downloadRegion(latitude lat: Double, longitude lon: Double, radiusKm: Double) async -> [Peak] {
        (try? await peaksTiled(aroundLatitude: lat, longitude: lon, radiusKm: radiusKm)) ?? []
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

    static func overpassQuery(lat: Double, lon: Double, radiusKm: Double) -> String {
        let at = "(around:\(Int(radiusKm * 1000)),\(lat),\(lon))"
        return """
        [out:json][timeout:25];
        node["natural"~"^(peak|volcano|saddle)$"]["name"]\(at);
        out 8000;
        """
    }

    private static func fetch(query: String, from endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        request.httpBody = ("data=" + encoded).data(using: .utf8)
        request.setValue("PeakPeek/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Parsing

    private struct Response: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        let id: Int64
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
    }

    static func parse(data: Data) throws -> [Peak] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.elements.compactMap { element in
            guard let tags = element.tags, let name = tags["name"], !name.isEmpty,
                  let lat = element.lat, let lon = element.lon else { return nil }
            let elevation = tags["ele"].flatMap(parseElevationMeters)
            return Peak(
                id: "osm-\(element.id)", name: name,
                latitude: lat, longitude: lon,
                elevationMeters: elevation ?? 0,
                prominenceMeters: tags["prominence"].flatMap(parseElevationMeters),
                isSaddle: tags["natural"] == "saddle"
            )
        }
    }

    // MARK: - Disk cache

    private static func cacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("peakcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(lat: Double, lon: Double, radiusKm: Double) -> URL {
        let dir = cacheDirectory()
        let snapLat = (lat * 4).rounded() / 4   // 0.25° cell (~28 km)
        let snapLon = (lon * 4).rounded() / 4
        let radius = Int(min(radiusKm, maxRadiusKm).rounded())
        return dir.appendingPathComponent(String(format: "\(cacheVersion)_%.2f_%.2f_r%d.json", snapLat, snapLon, radius))
    }

    private static func loadCached(lat: Double, lon: Double, radiusKm: Double) -> [Peak]? {
        guard let data = try? Data(contentsOf: cacheURL(lat: lat, lon: lon, radiusKm: radiusKm)),
              let peaks = try? JSONDecoder().decode([Peak].self, from: data), !peaks.isEmpty
        else { return nil }
        return peaks
    }

    private static func saveCached(_ peaks: [Peak], lat: Double, lon: Double, radiusKm: Double) {
        guard let data = try? JSONEncoder().encode(peaks) else { return }
        try? data.write(to: cacheURL(lat: lat, lon: lon, radiusKm: radiusKm))
    }

    private static func tileCenters(latitude lat: Double, longitude lon: Double, radiusKm: Double) -> [(latitude: Double, longitude: Double)] {
        let spacingKm = maxRadiusKm * 1.2
        let steps = Int(ceil(radiusKm / spacingKm))
        var centers: [(latitude: Double, longitude: Double)] = [(lat, lon)]
        for y in -steps...steps {
            for x in -steps...steps where x != 0 || y != 0 {
                let northKm = Double(y) * spacingKm
                let eastKm = Double(x) * spacingKm
                let distanceKm = hypot(northKm, eastKm)
                guard distanceKm <= radiusKm + maxRadiusKm * 0.7 else { continue }
                let bearing = atan2(eastKm, northKm)
                centers.append(GeoMath.destination(
                    latitude: lat,
                    longitude: lon,
                    bearingRad: bearing,
                    distanceMeters: distanceKm * 1000
                ))
            }
        }
        return centers.sorted {
            GeoMath.distanceMeters(fromLatitude: lat, fromLongitude: lon, toLatitude: $0.latitude, toLongitude: $0.longitude)
                < GeoMath.distanceMeters(fromLatitude: lat, fromLongitude: lon, toLatitude: $1.latitude, toLongitude: $1.longitude)
        }
    }

    private static func samePeak(_ a: Peak, _ b: Peak) -> Bool {
        if a.id == b.id { return true }
        guard a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame else { return false }
        return GeoMath.distanceMeters(
            fromLatitude: a.latitude, fromLongitude: a.longitude,
            toLatitude: b.latitude, toLongitude: b.longitude
        ) < 200
    }

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

    static func parseElevationMeters(_ raw: String) -> Double? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        let isFeet = lower.contains("ft") || lower.contains("feet")
        let tokenAllowed = CharacterSet(charactersIn: "-0123456789.,")
        guard let token = String(String.UnicodeScalarView(
            lower.unicodeScalars.map { tokenAllowed.contains($0) ? $0 : " " }
        )).split(separator: " ").first else { return nil }

        let value = String(token)
        let normalized: String
        if let comma = value.lastIndex(of: ","), let dot = value.lastIndex(of: ".") {
            if comma > dot {
                normalized = value
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = value.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = value.lastIndex(of: ",") {
            let after = value[value.index(after: comma)...]
            normalized = after.count == 3
                ? value.replacingOccurrences(of: ",", with: "")
                : value.replacingOccurrences(of: ",", with: ".")
        } else {
            normalized = value
        }

        let allowed = CharacterSet(charactersIn: "-0123456789.")
        let scalars = normalized.unicodeScalars.map { allowed.contains($0) ? $0 : " " }
        let numeric = String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .first
            .flatMap { Double($0) }
        guard let numeric else { return nil }
        return isFeet ? numeric * 0.3048 : numeric
    }
}
