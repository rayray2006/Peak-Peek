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
    let onPick: (PanoramaViewModel.Viewpoint) -> Void

    @State private var pin: CLLocationCoordinate2D?
    @State private var resolving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: startPosition) {
                    UserAnnotation()
                    if let currentViewpoint {
                        Annotation(currentViewpoint.name, coordinate: currentCoordinate, anchor: .center) {
                            ViewpointMarkerDot()
                        }
                    }
                    if let pin {
                        Annotation("Selected viewpoint", coordinate: pin, anchor: .center) {
                            ViewpointMarkerDot()
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .realistic))
                .onTapGesture { screenPoint in
                    if let coordinate = proxy.convert(screenPoint, from: .local) {
                        pin = coordinate
                    }
                }
            }
            .navigationTitle("Drop a viewpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let pin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(format: "Selected %.4f°, %.4f°", pin.latitude, pin.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button { go(to: pin) } label: {
                            HStack {
                                if resolving { ProgressView().tint(.white) }
                                Text(resolving ? "Naming location..." : "Stand here")
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "eye.fill")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                        }
                        .disabled(resolving)
                    }
                    // Landscape: don't stretch the confirm button across the whole
                    // (wide) screen — cap the content and center it in the bar.
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap")
                        Text("Tap the map to choose where to stand")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial)
                }
            }
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
    let onTap: () -> Void
    @StateObject private var location = MapLocationModel()
    /// Held in @State and updated ONLY when the viewpoint moves — so the map keeps a
    /// stable camera across the parent's re-renders instead of getting a freshly built
    /// `.constant(.region(...))` binding every time (which can reset the camera and
    /// interrupt tile loading).
    @State private var position: MapCameraPosition

    init(viewpoint: PanoramaViewModel.Viewpoint, onTap: @escaping () -> Void) {
        self.viewpoint = viewpoint
        self.onTap = onTap
        _position = State(initialValue: .region(Self.region(for: viewpoint)))
    }

    var body: some View {
        Map(position: $position, interactionModes: []) {
            if let coordinate = location.coordinate {
                Annotation("You", coordinate: coordinate, anchor: .center) {
                    MiniMapLocationDot()
                }
            }
            Annotation(viewpoint.name, coordinate: center, anchor: .center) {
                ViewpointMarkerDot()
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text("Map")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

private struct MiniMapLocationDot: View {
    var body: some View {
        Circle()
            .fill(.blue)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }
}

private struct ViewpointMarkerDot: View {
    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }
}
