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
    /// Dropped-pin card phase: naming the spot before saving it.
    @State private var namingPin = false
    @State private var pinName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The map IS the sheet: edge to edge, with the bare title floating
        // over it and a ✕ beside it. Both sit on SATELLITE imagery (dark in
        // either theme), so they're white with a soft shadow — map-label
        // styling, not the themed ink.
        MapReader { proxy in
            Map(initialPosition: startPosition) { mapAnnotations }
            .mapStyle(.hybrid(elevation: .realistic))
            // No compass/scale chrome: they pop in during rotation right where
            // the floating title and ✕ live, and a pin-drop picker needs neither.
            .mapControlVisibility(.hidden)
            .onTapGesture { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    selectedPeak = nil
                    pin = coordinate
                    namingPin = false
                    pinName = ""
                }
            }
        }
        .ignoresSafeArea()
        // No floating title — the map speaks for itself; just the ✕.
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close map")
            .padding(.trailing, 10)
            .padding(.top, 22)          // clears the sheet's drag indicator
        }
        .safeAreaInset(edge: .bottom) {
            if let selectedPeak {
                peakCard(for: selectedPeak)
            } else if let pin {
                pinCard(for: pin)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                // With no card up, .ignoresSafeArea leaves the map thinking it
                // has zero bottom inset, so its Legal/logo attribution hugged
                // the physical edge and got clipped by the rounded corner. A
                // clear inset restores the margin; tiles still bleed beneath it.
                Color.clear.frame(height: 24)
                    .allowsHitTesting(false)
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
            isBookmarked: lists.contains(peak, in: .wantToClimb),
            onToggleClimbed: { lists.toggle(peak, in: .climbed) },
            onToggleBookmark: { lists.toggle(peak, in: .wantToClimb) },
            onVisit: { go(to: peak) },
            onDismiss: { selectedPeak = nil }
        )
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)   // 12 read cramped on narrow phones
        .padding(.bottom, 8)
    }

    /// Dropped-pin card in the SAME language as the panorama's location card:
    /// paper card, mono coordinates line, pill actions — Save (names the spot
    /// into the Saved list, whose gold badge then marks it on the map) or
    /// View (teleport the eye there). Save flips the card into the naming
    /// phase, mirroring the Save Spot sheet's field + black Save button.
    private func pinCard(for pin: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if namingPin {
                TextField("Name this spot", text: $pinName)
                    .font(PPFont.ui(15))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
                    )
                    .padding(.trailing, 28)
                Text(coordsLine(pin))
                    .font(PPFont.mono(12))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                Button {
                    savePin(pin)
                } label: {
                    Text("Save")
                        .font(PPFont.ui(15, .semibold))
                        .foregroundStyle(TopoStyle.paperColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(TopoStyle.inkColor, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                Text("Dropped Pin")
                    .font(PPFont.ui(18, .semibold))
                    .foregroundStyle(TopoStyle.inkColor)
                    .padding(.trailing, 28)
                Text(coordsLine(pin))
                    .font(PPFont.mono(12))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                HStack(spacing: 8) {
                    pinAction("Save", systemImage: "bookmark") { namingPin = true }
                    pinAction(resolving ? "Naming location..." : "View",
                              systemImage: "figure.stand") { go(to: pin) }
                        .disabled(resolving)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(TopoStyle.paperColor, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(TopoStyle.hairline(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
        .overlay(alignment: .topTrailing) {
            Button {
                self.pin = nil
                namingPin = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }

    /// The location-card pill button: icon + label, 46 pt, hairline outline.
    private func pinAction(_ title: String, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.8))
                Text(title)
                    .font(PPFont.ui(14, .semibold))
                    .foregroundStyle(TopoStyle.inkColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// "48.5000° N, 121.0800° W" for the pin card.
    private func coordsLine(_ pin: CLLocationCoordinate2D) -> String {
        String(format: "%.4f° %@, %.4f° %@",
               abs(pin.latitude), pin.latitude >= 0 ? "N" : "S",
               abs(pin.longitude), pin.longitude >= 0 ? "E" : "W")
    }

    /// Save the pinned spot into the Saved list (the same entry Save Spot
    /// makes): the typed name, or the reverse-geocoded one when left blank
    /// (falling back to bare coordinates offline). The pin clears on save —
    /// the gold saved badge takes over marking the spot.
    private func savePin(_ pin: CLLocationCoordinate2D) {
        let typed = pinName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let fallback = String(format: "%.3f°, %.3f°", pin.latitude, pin.longitude)
            let name: String
            if typed.isEmpty {
                let loc = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
                name = await Self.friendlyName(for: loc, deadlineSeconds: 2.5) ?? fallback
            } else {
                name = typed
            }
            lists.toggle(Peak(
                id: "loc_\(UUID().uuidString)", name: name,
                latitude: pin.latitude, longitude: pin.longitude,
                elevationMeters: 0, prominenceMeters: nil
            ), in: .wantToClimb)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            namingPin = false
            pinName = ""
            self.pin = nil
        }
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
    /// GPS-following: the eye IS the user's location (the system puck marks
    /// both); manual: puck + white viewpoint pin are distinct places.
    let isManualViewpoint: Bool
    let onTap: () -> Void
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
            // The full teleport map keeps the system blue puck; at 104 pt the
            // puck (accuracy ring, heading cone) dwarfed the whole peek, so
            // the mini map draws a puck-toned dot scaled to its cartography.
            UserAnnotation(anchor: .center) { _ in
                MiniLocationDot()
            }
            if isManualViewpoint {
                // Manual viewpoint: the eye stands somewhere else — mark it.
                Annotation(viewpoint.name, coordinate: center, anchor: .center) {
                    ViewpointPin(compact: true)
                }
                .annotationTitles(.hidden)
            }
        }
        // Same cartography as the full teleport map — one map style app-wide.
        // (No saturation wash: it was tuned for the pale standard tiles and
        // just greyed the hybrid imagery.)
        .mapStyle(.hybrid(elevation: .realistic))
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

/// The viewpoint badge — one marker for "the eye stands (or will stand) here":
/// the current viewpoint AND a freshly dropped pin. Same circular language as
/// `SavedPeakDot`: ink pin glyph on a paper disc. `compact` is the mini-map
/// size — the full 22 pt badge covered a quarter of the 104 pt peek.
/// The manual-viewpoint marker, shared by every map (teleport, mini, offline)
/// so "where the eye stands" reads identically across them.
struct ViewpointPin: View {
    var compact = false

    var body: some View {
        Image(systemName: "mappin")
            .font(.system(size: compact ? 7 : 12, weight: .bold))
            .foregroundStyle(TopoStyle.inkColor)
            .frame(width: compact ? 13 : 22, height: compact ? 13 : 22)
            .background(TopoStyle.paperColor, in: Circle())
            .overlay(Circle().stroke(TopoStyle.inkColor.opacity(0.25), lineWidth: 1))
            .shadow(radius: compact ? 1 : 1.5)
            .allowsHitTesting(false)
    }
}

/// Mini-map stand-in for the system location puck: the same blue, sized for
/// a 104 pt map instead of a full-screen one.
private struct MiniLocationDot: View {
    var body: some View {
        Circle()
            .fill(Color(red: 0.04, green: 0.52, blue: 1.00))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 1.5)
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
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(kind == .climbed ? TopoStyle.visibleColor : TopoStyle.goldColor,
                        in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 1.8 : 1.5))
            .overlay {
                if isSelected {
                    Circle().stroke(.white.opacity(0.45), lineWidth: 1.5).padding(-3)
                }
            }
            .shadow(radius: isSelected ? 2.2 : 1.5)
            // Selection grows via scaleEffect, NOT a bigger frame: the Map
            // positions the annotation from the bounds it laid out, so an
            // animated frame change kept the top-left pinned and the badge
            // grew toward the bottom-right. scaleEffect never changes layout
            // bounds — the badge breathes about its own center, in place.
            .scaleEffect(isSelected ? 22.0 / 16.0 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

private extension Peak {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
