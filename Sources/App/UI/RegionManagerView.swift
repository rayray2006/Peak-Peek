import CoreLocation
import MapKit
import SwiftUI

/// Pick an area on a map and download its terrain for offline use, plus manage
/// already-downloaded regions. Pan/zoom the map; the accent frame in the centre is the
/// area that gets downloaded. (Built on PeakPeek's `DEMFetcher` persistent tile
/// store via `RegionStore`; styled to match the app's dark/accent chrome.)
struct RegionManagerView: View {
    @ObservedObject var store: RegionStore
    var currentViewpoint: PanoramaViewModel.Viewpoint?
    @Environment(\.dismiss) private var dismiss

    /// Fraction of the (square) map side covered by the selection frame.
    private static let selectionFraction: CGFloat = 0.72

    @State private var position: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    /// Landscape (compact height): the stacked layout can't fit the map AND the
    /// controls, so they go side by side instead.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(store: RegionStore, currentViewpoint: PanoramaViewModel.Viewpoint?) {
        self._store = ObservedObject(wrappedValue: store)
        self.currentViewpoint = currentViewpoint
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
        .background(Color(TopoStyle.background).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var portraitLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            selector
            if !store.regions.isEmpty { regionList }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Landscape: map selector on the left (full height), header + download
    /// controls + saved regions + footer in a column on the right.
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            mapSelector
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                header
                downloadControls
                if !store.regions.isEmpty { regionList }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.dashed.inset.filled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(store.isDownloading ? Color.orange : .white.opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Regions").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                Text("Pick an area on the map to use without a connection")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    // MARK: Area selector (map + selection frame)

    private var selector: some View {
        VStack(alignment: .leading, spacing: 12) {
            mapSelector
                .frame(height: 300)

            downloadControls
        }
    }

    private var mapSelector: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.selectionFraction
            ZStack {
                Map(position: $position,
                    interactionModes: store.isDownloading ? [] : [.pan, .zoom]) {
                    if let vp = currentViewpoint {
                        Annotation(vp.name, coordinate:
                            CLLocationCoordinate2D(latitude: vp.latitude, longitude: vp.longitude)) {
                            Circle().fill(.orange)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .onMapCameraChange(frequency: .continuous) { ctx in visibleRegion = ctx.region }
                .clipShape(RoundedRectangle(cornerRadius: 14))

                selectionFrame(side: side)
            }
            .onAppear { mapSize = geo.size }
            .onChange(of: geo.size) { _, new in mapSize = new }
        }
        .opacity(store.isDownloading ? 0.6 : 1)
    }

    /// Dim everything outside a centred square + an accent frame around it.
    private func selectionFrame(side: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.34)
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .frame(width: side, height: side)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(TopoStyle.accent), lineWidth: 2)
                .frame(width: side, height: side)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var downloadControls: some View {
        if store.isDownloading {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.statusText ?? "Downloading…")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                ProgressView(value: store.progress).tint(Color(TopoStyle.accent))
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Button {
                Task { await downloadSelected() }
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download selected area").font(.system(size: 15, weight: .semibold))
                        Text("~\(tileEstimate) tile\(tileEstimate == 1 ? "" : "s") · pan & zoom to choose")
                            .font(.system(size: 11)).foregroundStyle(Color(TopoStyle.accentText).opacity(0.8))
                    }
                    Spacer()
                }
                .foregroundStyle(Color(TopoStyle.accentText))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color(TopoStyle.accent), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(tileEstimate == 0)
            .opacity(tileEstimate == 0 ? 0.5 : 1)

            if let status = store.statusText {
                Text(status).font(.system(size: 12)).foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    // MARK: Downloaded regions list

    private var regionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.regions) { region in
                    HStack(spacing: 12) {
                        Image(systemName: "map").foregroundStyle(Color(TopoStyle.accent))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                            Text("\(Int(region.radiusKm)) km · \(store.sizeText(region))")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Button { store.delete(region) } label: {
                            Image(systemName: "trash").foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private var footer: some View {
        HStack {
            Text(store.regions.isEmpty ? "No regions downloaded" : "\(store.regions.count) region(s)")
            Spacer()
            Text("Storage: \(store.totalSizeText)")
        }
        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
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
        return DEMFetcher.regionTiles(south: b.south, north: b.north, west: b.west, east: b.east).count
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
