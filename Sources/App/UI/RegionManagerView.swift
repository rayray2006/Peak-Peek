import CoreLocation
import MapKit
import SwiftUI

/// Pick an area on a map and download its terrain for offline use, plus manage
/// already-downloaded regions. Pan/zoom the map; the dashed ink frame in the
/// centre is the area that gets downloaded (template's "SELECT AREA" language).
/// (Built on PeakPeek's `DEMFetcher` persistent tile store via `RegionStore`;
/// hosted in the white PanelCard, which owns the title + ✕.)
struct RegionManagerView: View {
    @ObservedObject var store: RegionStore
    var currentViewpoint: PanoramaViewModel.Viewpoint?
    /// The eye stands away from the GPS position (teleport) — mark it
    /// separately from the system location puck.
    var isManualViewpoint = false
    @Environment(\.dismiss) private var dismiss

    /// Fraction of the (square) map side covered by the selection frame.
    private static let selectionFraction: CGFloat = 0.72

    /// Rough on-disk size of one 1°×1° SRTM tile (gzipped ~5–25 MB by
    /// terrain; mountainous areas run high). Drives the download estimate.
    private static let approxTileBytes: Int64 = 15_000_000

    @State private var position: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    /// Landscape (compact height): the stacked layout can't fit the map AND the
    /// controls, so they go side by side instead.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(store: RegionStore, currentViewpoint: PanoramaViewModel.Viewpoint?,
         isManualViewpoint: Bool = false) {
        self._store = ObservedObject(wrappedValue: store)
        self.currentViewpoint = currentViewpoint
        self.isManualViewpoint = isManualViewpoint
        let region: MKCoordinateRegion
        if let vp = currentViewpoint {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: vp.latitude, longitude: vp.longitude),
                span: MKCoordinateSpan(latitudeDelta: 1.6, longitudeDelta: 1.6))
        } else {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 46.85, longitude: -121.76),
                span: MKCoordinateSpan(latitudeDelta: 1.6, longitudeDelta: 1.6))
        }
        _position = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact { landscapeLayout } else { portraitLayout }
        }
    }

    private var portraitLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            mapSelector
                .frame(maxHeight: .infinity)
            downloadControls
            if !store.regions.isEmpty { regionList }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Landscape: map selector on the left (full height), download controls +
    /// saved regions + footer in a column on the right.
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            mapSelector
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                downloadControls
                if !store.regions.isEmpty { regionList }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: Area selector (map + selection frame)

    private var mapSelector: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.selectionFraction
            ZStack {
                Map(position: $position,
                    interactionModes: store.isDownloading ? [] : [.pan, .zoom]) {
                    // Already-downloaded coverage: the EXACT areas the user
                    // selected (not the underlying 1° tile grid), unioned
                    // across regions into non-overlapping green rectangles —
                    // overlapping downloads read as one seamless shape.
                    ForEach(savedAreas, id: \.self) { box in
                        MapPolygon(coordinates: [
                            CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                            CLLocationCoordinate2D(latitude: box.north, longitude: box.west),
                            CLLocationCoordinate2D(latitude: box.north, longitude: box.east),
                            CLLocationCoordinate2D(latitude: box.south, longitude: box.east),
                        ])
                        .foregroundStyle(TopoStyle.visibleColor.opacity(0.45))
                    }
                    // The 1° tile grid INSIDE the coverage — reads as "stored
                    // in tiles", and gives the flat green some structure.
                    // Lines are clipped to the union rects, so the grid never
                    // suggests coverage beyond the actual saved area.
                    ForEach(Array(savedGridLines.enumerated()), id: \.offset) { _, line in
                        MapPolyline(coordinates: line)
                            .stroke(TopoStyle.visibleColor.opacity(0.5), lineWidth: 1)
                    }
                    // The user's position: the system blue puck, same as
                    // every other map in the app.
                    UserAnnotation()
                    if isManualViewpoint, let vp = currentViewpoint {
                        // Same pin as the teleport map — one marker language
                        // for "where the eye stands" on every map.
                        Annotation(vp.name, coordinate:
                            CLLocationCoordinate2D(latitude: vp.latitude, longitude: vp.longitude)) {
                            ViewpointPin()
                        }
                        .annotationTitles(.hidden)
                    }
                }
                // Same cartography as the full teleport map — one map style
                // app-wide — but FLAT elevation here: with .realistic the
                // coverage polygons drape onto 3D terrain whose mesh LOD
                // re-tessellates at the viewport edges while panning, so the
                // green area's edge visibly crawled. Flat keeps the overlays
                // pinned to their coordinates.
                .mapStyle(.hybrid(elevation: .flat))
                .onMapCameraChange(frequency: .continuous) { ctx in visibleRegion = ctx.region }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(TopoStyle.hairline(0.10), lineWidth: 1)
                )

                selectionFrame(side: side)
            }
            .onAppear { mapSize = geo.size }
            .onChange(of: geo.size) { _, new in mapSize = new }
        }
        .opacity(store.isDownloading ? 0.6 : 1)
    }

    /// Dim everything outside a centred square + the template's dashed ink
    /// frame with its "SELECT AREA" tag.
    private func selectionFrame(side: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .frame(width: side, height: side)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(TopoStyle.inkColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    // Bare mono tag inside the frame's top corner, per the mock.
                    PPMicroLabel(text: "Select area", opacity: 0.7)
                        .padding(10)
                }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var downloadControls: some View {
        if store.isDownloading {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.statusText ?? "Downloading…")
                    .font(PPFont.mono(11))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.6))
                PPProgressLine(progress: store.progress, width: 200)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        } else {
            // One evaluation per render (this body re-runs on every continuous
            // map-camera frame while dragging — it was computed four times).
            let estimate = tileEstimate
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected area")
                        .font(PPFont.ui(15, .medium))
                        .foregroundStyle(TopoStyle.inkColor)
                        .lineLimit(1)
                    // ONE line, whatever the zoom: huge selections clamp to a
                    // "zoom in" nudge — a four-digit readout used to wrap the
                    // row and shove the whole sheet's layout around. The size
                    // (like the template's "240 MB") reads better than a tile
                    // count; it's an estimate, terrain-dependent.
                    Text(estimate > 999
                        ? "over 15 GB · zoom in"
                        : "~\(Self.sizeText(tiles: estimate))")
                        .font(PPFont.mono(11))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await downloadSelected() }
                } label: {
                    Text("Download")
                        .font(PPFont.ui(14, .semibold))
                        .foregroundStyle(TopoStyle.paperColor)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(TopoStyle.inkColor, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(estimate == 0)
                .opacity(estimate == 0 ? 0.4 : 1)
            }

            if let status = store.statusText {
                Text(status)
                    .font(PPFont.mono(11))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.6))
            }
        }
    }

    // MARK: Downloaded regions list

    private var regionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.regions) { region in
                    HStack(spacing: 12) {
                        Image(systemName: "map")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TopoStyle.inkColor.opacity(0.65))
                        Text(region.name)
                            .font(PPFont.ui(14, .medium))
                            .foregroundStyle(TopoStyle.inkColor)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(region.radiusKm)) km · \(store.sizeText(region))")
                            .font(PPFont.mono(11))
                            .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                        Button { store.delete(region) } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundStyle(TopoStyle.occludedColor.opacity(0.85))
                                .contentShape(Rectangle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 40)
                    if region.id != store.regions.last?.id {
                        Rectangle().fill(TopoStyle.hairline(0.08)).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxHeight: 132)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(store.regions.isEmpty ? "No regions downloaded" : "\(store.regions.count) region(s)")
                Spacer()
                Text("Storage: \(store.totalSizeText)")
            }
            // Required credit for the high-latitude source (Copernicus data
            // license); SRTM/Mapzen appreciate one too.
            Text("Elevation: NASA SRTM · Copernicus GLO-30 DEM © ESA/DLR · Mapzen")
                .opacity(0.7)
        }
        .font(PPFont.mono(10))
        .foregroundStyle(TopoStyle.inkColor.opacity(0.45))
    }

    // MARK: Downloaded coverage overlay

    /// The exact saved areas across all regions, decomposed into
    /// non-overlapping rectangles so the union fills seamlessly.
    private var savedAreas: [RegionBox] {
        RegionStore.unionRects(store.regions.flatMap(\.boxes))
    }

    /// Integer-degree (tile-boundary) grid segments clipped to the coverage
    /// rects. The rects are non-overlapping, so no line draws twice.
    private var savedGridLines: [[CLLocationCoordinate2D]] {
        var lines: [[CLLocationCoordinate2D]] = []
        for box in savedAreas {
            var lon = (box.west).rounded(.up)
            while lon < box.east {
                if lon > box.west {
                    lines.append([CLLocationCoordinate2D(latitude: box.south, longitude: lon),
                                  CLLocationCoordinate2D(latitude: box.north, longitude: lon)])
                }
                lon += 1
            }
            var lat = (box.south).rounded(.up)
            while lat < box.north {
                if lat > box.south {
                    lines.append([CLLocationCoordinate2D(latitude: lat, longitude: box.west),
                                  CLLocationCoordinate2D(latitude: lat, longitude: box.east)])
                }
                lat += 1
            }
        }
        return lines
    }

    // MARK: Selection geometry

    /// The lat/lon bounding box of the centred selection square, derived from the
    /// map's visible region and the square's on-screen fraction.
    private var selectedBBox: (south: Double, north: Double, west: Double, east: Double)? {
        guard let r = visibleRegion, mapSize.width > 1, mapSize.height > 1 else { return nil }
        let side = min(mapSize.width, mapSize.height) * Self.selectionFraction
        let latDelta = r.span.latitudeDelta * Double(side / mapSize.height)
        let lonDelta = r.span.longitudeDelta * Double(side / mapSize.width)
        return (r.center.latitude - latDelta / 2, r.center.latitude + latDelta / 2,
                r.center.longitude - lonDelta / 2, r.center.longitude + lonDelta / 2)
    }

    private var tileEstimate: Int {
        guard let b = selectedBBox else { return 0 }
        return DEMFetcher.regionTileCount(south: b.south, north: b.north, west: b.west, east: b.east)
    }

    /// "~60 MB" for a tile-count estimate. (RegionStore's shared formatter:
    /// numeric-only, so 0 renders "0 bytes", never the word "Zero".)
    private static func sizeText(tiles: Int) -> String {
        RegionStore.byteFormatter.string(fromByteCount: Int64(tiles) * approxTileBytes)
    }

    private func downloadSelected() async {
        guard let b = selectedBBox else { return }
        let cLat = (b.south + b.north) / 2, cLon = (b.west + b.east) / 2
        var name = String(format: "%.3f°, %.3f°", cLat, cLon)
        if let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(CLLocation(latitude: cLat, longitude: cLon)).first,
           let friendly = placemark.locality ?? placemark.administrativeArea ?? placemark.name {
            name = friendly
        }
        await store.download(name: name, south: b.south, north: b.north, west: b.west, east: b.east)
    }
}
