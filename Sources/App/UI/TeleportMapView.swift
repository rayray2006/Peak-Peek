import CoreLocation
import MapKit
import SwiftUI

/// Full-screen teleport map — tap anywhere to drop a pin, confirm to move the eye
/// there and look around (PeakFinder's viewpoint picker). (Ported from RidgeLine.)
///
/// A plain maps view with its own default labels (mountains, lakes, towns) — no
/// custom peak markers. Tap anywhere to drop a pin at that exact point; the pin's
/// friendly name is reverse-geocoded on confirm.
struct TeleportMapView: View {
    let currentViewpoint: PanoramaViewModel.Viewpoint?
    /// When the eye follows GPS, the viewpoint IS the user's location — drawing
    /// both the blue GPS dot and the white viewpoint dot stacks two markers on
    /// the same spot, so the viewpoint marker only renders for manual viewpoints.
    let isManualViewpoint: Bool
    /// The live lists: badge dots AND the embedded info card's Save/Been
    /// toggles stay in sync while the sheet is up.
    @ObservedObject var lists: PeakListStore
    /// Sightline verdict from the renderer, for the embedded info card.
    let visibility: (Peak) -> Bool?
    let onPick: (PanoramaViewModel.Viewpoint) -> Void

    private var climbedPeaks: [Peak] { lists.peaks(in: .climbed).map(\.peak) }
    private var bookmarkedPeaks: [Peak] { lists.peaks(in: .wantToClimb).map(\.peak) }

    @State private var pin: CLLocationCoordinate2D?
    @State private var selectedPeak: Peak?
    @State private var resolving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The map IS the sheet: edge to edge, with the title floating over it
        // as a paper tag (it read as a dead white bar as a header strip).
        // Cancel button removed deliberately: swipe down (or tap outside on
        // iPad) is the one way out.
        MapReader { proxy in
            Map(initialPosition: startPosition) { mapAnnotations }
            .mapStyle(.hybrid(elevation: .realistic))
            .onTapGesture { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    selectedPeak = nil
                    pin = coordinate
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Text("Drop a viewpoint")
                .font(PPFont.ui(15, .semibold))
                .foregroundStyle(TopoStyle.inkColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TopoStyle.paperColor, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.top, 22)      // clears the sheet's drag indicator
        }
        .safeAreaInset(edge: .bottom) {
            if let selectedPeak {
                peakCard(for: selectedPeak)
            } else if let pin {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: "Selected %.4f°, %.4f°", pin.latitude, pin.longitude))
                        .font(PPFont.mono(11))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                    Button { go(to: pin) } label: {
                        standHereLabel
                    }
                    .disabled(resolving)
                }
                // Landscape: don't stretch the confirm button across the whole
                // (wide) screen — cap the content and center it in the bar.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial)
            }
        }
    }

    /// The overlay annotations, shared by the selectable (iOS 18) and plain maps.
    @MapContentBuilder private var mapAnnotations: some MapContent {
        UserAnnotation()
        // The current viewpoint and a freshly dropped pin are the SAME idea —
        // "the eye stands (or will stand) here" — so they share one pin marker,
        // and dropping a new pin replaces the old viewpoint's rather than
        // showing two pins at once.
        if let currentViewpoint, isManualViewpoint, pin == nil {
            Annotation(currentViewpoint.name, coordinate: currentCoordinate, anchor: .center) {
                ViewpointPin()
            }
        }
        // Climbed wins when a peak is on both lists (same precedence
        // as the panorama's saved-label tints).
        ForEach(climbedPeaks) { peak in
            savedPeakAnnotation(peak, kind: .climbed)
        }
        ForEach(bookmarkedPeaks.filter { peak in
            !climbedPeaks.contains(where: { $0.id == peak.id })
        }) { peak in
            savedPeakAnnotation(peak, kind: .wantToClimb)
        }
        if let pin {
            Annotation("Selected viewpoint", coordinate: pin, anchor: .center) {
                ViewpointPin()
            }
        }
    }

    /// A saved-peak badge that opens the peak's info card. The 8 pt padding grows
    /// the 16 pt dot to a 32 pt tap target without changing how the badge looks.
    private func savedPeakAnnotation(_ peak: Peak, kind: PeakListKind) -> some MapContent {
        Annotation(peak.name, coordinate: peak.coordinate, anchor: .center) {
            SavedPeakDot(kind: kind, isSelected: selectedPeak?.id == peak.id)
                .padding(8)
                .contentShape(Circle())
                .onTapGesture {
                    pin = nil
                    selectedPeak = peak
                }
        }
        .annotationTitles(.hidden)
    }

    /// Bottom card for a tapped saved-peak badge: the SAME full info card the
    /// panorama shows — name, been-date, stats, sightline verdict, and the
    /// Save / Been / Stand here buttons — not just a confirm strip.
    private func peakCard(for peak: Peak) -> some View {
        let vp = currentViewpoint
        let distance = vp.map {
            GeoMath.distanceMeters(fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                                   toLatitude: peak.latitude, toLongitude: peak.longitude)
        } ?? 0
        let bearing = vp.map {
            GeoMath.bearingRad(fromLatitude: $0.latitude, fromLongitude: $0.longitude,
                               toLatitude: peak.latitude, toLongitude: peak.longitude) * 180 / .pi
        } ?? 0
        return PeakInfoPanel(
            peak: AnnotatedPeak(peak: peak, azimuthDeg: bearing,
                                elevationAngleDeg: 0, distanceMeters: distance),
            isVisible: visibility(peak),
            isClimbed: lists.contains(peak, in: .climbed),
            beenDate: lists.peaks(in: .climbed).first { $0.peak.id == peak.id }?.climbedAt,
            isBookmarked: lists.contains(peak, in: .wantToClimb),
            onToggleClimbed: { lists.toggle(peak, in: .climbed) },
            onToggleBookmark: { lists.toggle(peak, in: .wantToClimb) },
            onVisit: { go(to: peak) },
            onDismiss: { selectedPeak = nil }
        )
        .frame(maxWidth: 560)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The black "Stand here" confirm button (template button language),
    /// shared by the pin and peak cards.
    private var standHereLabel: some View {
        HStack {
            if resolving { ProgressView().tint(.white) }
            Text(resolving ? "Naming location..." : "Stand here")
                .font(PPFont.ui(15, .semibold))
                .lineLimit(1)
            Spacer()
            Image(systemName: "eye")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(TopoStyle.inkColor, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(TopoStyle.paperColor)
    }

    private var startPosition: MapCameraPosition {
        guard let vp = currentViewpoint else { return .automatic }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: vp.latitude, longitude: vp.longitude),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
        ))
    }

    private var currentCoordinate: CLLocationCoordinate2D {
        guard let currentViewpoint else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        return CLLocationCoordinate2D(latitude: currentViewpoint.latitude, longitude: currentViewpoint.longitude)
    }

    /// Teleport straight to a saved peak — it already has a name, so no geocoding.
    private func go(to peak: Peak) {
        onPick(PanoramaViewModel.Viewpoint(
            name: peak.name, latitude: peak.latitude, longitude: peak.longitude
        ))
        dismiss()
    }

    /// Resolve a friendly name for the pin (best effort, ~a second), then teleport.
    /// The name NEVER gates the move: offline, reverseGeocodeLocation can hang for
    /// minutes, which left "Naming location..." spinning forever — so the lookup
    /// races a short deadline and loses gracefully to the coordinate string.
    private func go(to coordinate: CLLocationCoordinate2D) {
        resolving = true
        Task {
            let fallback = String(format: "%.3f°, %.3f°", coordinate.latitude, coordinate.longitude)
            let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let name = await Self.friendlyName(for: loc, deadlineSeconds: 2.5) ?? fallback
            onPick(PanoramaViewModel.Viewpoint(
                name: name, latitude: coordinate.latitude, longitude: coordinate.longitude
            ))
            resolving = false
            dismiss()
        }
    }

    /// First of: reverse-geocoded name, or nil at the deadline. Resume-once guard
    /// because the loser still finishes eventually (the geocoder ignores task
    /// cancellation, so a task group would keep waiting on it — hence the manual race).
    private static func friendlyName(for loc: CLLocation, deadlineSeconds: Double) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func run(_ body: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; body() }
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            Task {
                let placemark = try? await CLGeocoder().reverseGeocodeLocation(loc).first
                let friendly = placemark.flatMap {
                    $0.name ?? $0.areasOfInterest?.first ?? $0.locality ?? $0.administrativeArea
                }
                once.run { cont.resume(returning: friendly) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                once.run { cont.resume(returning: nil) }
            }
        }
    }
}

/// The corner mini-map: a non-interactive peek at where the eye stands; tapping
/// opens the full teleport map.
struct MiniMapView: View {
    let viewpoint: PanoramaViewModel.Viewpoint
    /// GPS-following: the eye IS the user's location, so a single blue dot marks
    /// both; manual: blue GPS dot + white viewpoint dot are distinct places.
    let isManualViewpoint: Bool
    let onTap: () -> Void
    @StateObject private var location = MapLocationModel()
    /// Held in @State and updated ONLY when the viewpoint moves — so the map keeps a
    /// stable camera across the parent's re-renders instead of getting a freshly built
    /// `.constant(.region(...))` binding every time (which can reset the camera and
    /// interrupt tile loading).
    @State private var position: MapCameraPosition

    init(viewpoint: PanoramaViewModel.Viewpoint, isManualViewpoint: Bool, onTap: @escaping () -> Void) {
        self.viewpoint = viewpoint
        self.isManualViewpoint = isManualViewpoint
        self.onTap = onTap
        _position = State(initialValue: .region(Self.region(for: viewpoint)))
    }

    var body: some View {
        Map(position: $position, interactionModes: []) {
            Group {
                if isManualViewpoint {
                    if let coordinate = location.coordinate {
                        Annotation("You", coordinate: coordinate, anchor: .center) {
                            MiniMapLocationDot()
                        }
                    }
                    Annotation(viewpoint.name, coordinate: center, anchor: .center) {
                        ViewpointPin()
                    }
                } else {
                    // Following GPS: one dot at the eye — not a GPS dot with a
                    // viewpoint marker stacked on top of it. The template
                    // captions it "You" in mono; the anchor keeps the DOT on
                    // the coordinate, not the pair's midpoint.
                    Annotation("You", coordinate: center,
                               anchor: UnitPoint(x: 0.5, y: 0.21)) {
                        VStack(spacing: 2) {
                            MiniMapLocationDot()
                            Text("You")
                                .font(PPFont.mono(9))
                                .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                        }
                    }
                }
            }
            // The 104 pt peek has no room for annotation captions.
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .realistic))
        // The template's pale cartography: wash most of the color out of the
        // map tiles. The peek follows the day/night theme (dark tiles after
        // sunset) via the scene-wide scheme.
        .saturation(0.25)
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            // Bare mono tag, as in the template.
            PPMicroLabel(text: "Map", opacity: 0.55)
                .padding(8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: onTap)
        .task { location.start() }
        .onDisappear { location.stop() }
        // Follow the eye only when it actually moves (not on every parent re-render).
        .onChange(of: viewpoint.latitude) { position = .region(Self.region(for: viewpoint)) }
        .onChange(of: viewpoint.longitude) { position = .region(Self.region(for: viewpoint)) }
        .accessibilityLabel("Map — tap to choose a viewpoint")
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: viewpoint.latitude, longitude: viewpoint.longitude)
    }

    private static func region(for viewpoint: PanoramaViewModel.Viewpoint) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: viewpoint.latitude, longitude: viewpoint.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
        )
    }
}

/// The template's "You" marker: an ink dot with a paper ring and halo
/// (both dynamic — the pair inverts with the day/night theme).
private struct MiniMapLocationDot: View {
    var body: some View {
        Circle()
            .fill(TopoStyle.inkColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(TopoStyle.paperColor, lineWidth: 2))
            .background(Circle().fill(TopoStyle.inkColor.opacity(0.12)).padding(-4))
            .allowsHitTesting(false)
    }
}

/// The viewpoint badge — one marker for "the eye stands (or will stand) here":
/// the current viewpoint AND a freshly dropped pin. Same circular language as
/// `SavedPeakDot`: ink pin glyph on a paper disc.
private struct ViewpointPin: View {
    var body: some View {
        Image(systemName: "mappin")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(TopoStyle.inkColor)
            .frame(width: 22, height: 22)
            .background(TopoStyle.paperColor, in: Circle())
            .overlay(Circle().stroke(TopoStyle.inkColor.opacity(0.25), lineWidth: 1))
            .shadow(radius: 1.5)
            .allowsHitTesting(false)
    }
}

/// Small saved-peak badge: green seal = completed, gold bookmark = saved
/// (same tints as the info-card badges and the panorama's saved labels).
/// Selected (its info card is up): the badge grows and gains a halo ring so
/// the map shows WHICH peak the card describes.
private struct SavedPeakDot: View {
    let kind: PeakListKind
    var isSelected = false

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: isSelected ? 10 : 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: isSelected ? 22 : 16, height: isSelected ? 22 : 16)
            .background(kind == .climbed ? TopoStyle.visibleColor : TopoStyle.goldColor,
                        in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2.5 : 1.5))
            .overlay {
                if isSelected {
                    Circle().stroke(.white.opacity(0.45), lineWidth: 2).padding(-4)
                }
            }
            .shadow(radius: isSelected ? 3 : 1.5)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

private extension Peak {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
