import CoreLocation
import MapKit
import SwiftUI

/// Full-screen teleport map — tap anywhere to drop a pin, confirm to move the eye
/// there and look around (PeakFinder's viewpoint picker). (Ported from RidgeLine.)
struct TeleportMapView: View {
    let currentViewpoint: PanoramaViewModel.Viewpoint?
    let onPick: (PanoramaViewModel.Viewpoint) -> Void

    @StateObject private var location = MapLocationModel()
    @State private var pin: CLLocationCoordinate2D?
    @State private var resolving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: startPosition) {
                    if let coordinate = location.coordinate {
                        Annotation("You", coordinate: coordinate, anchor: .center) {
                            HeadingDot(headingDeg: location.headingDeg)
                        }
                    }
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
                        Button {
                            go(to: pin)
                        } label: {
                            HStack {
                                if resolving { ProgressView().tint(.white) }
                                Text(resolving ? "Naming location..." : "Stand here")
                                    .font(.callout.weight(.semibold))
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
            .task { location.start() }
            .onDisappear { location.stop() }
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

    /// Resolve a friendly name (best effort, ~a second), then teleport.
    private func go(to coordinate: CLLocationCoordinate2D) {
        resolving = true
        Task {
            var name = String(format: "%.3f°, %.3f°", coordinate.latitude, coordinate.longitude)
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
               let friendly = placemark.name ?? placemark.locality ?? placemark.administrativeArea {
                name = friendly
            }
            onPick(PanoramaViewModel.Viewpoint(
                name: name, latitude: coordinate.latitude, longitude: coordinate.longitude
            ))
            resolving = false
            dismiss()
        }
    }
}

/// The corner mini-map: a non-interactive peek at where the eye stands; tapping
/// opens the full teleport map.
struct MiniMapView: View {
    let viewpoint: PanoramaViewModel.Viewpoint
    let onTap: () -> Void
    @StateObject private var location = MapLocationModel()

    var body: some View {
        Map(position: .constant(.region(region)), interactionModes: []) {
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
        .accessibilityLabel("Map — tap to choose a viewpoint")
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: viewpoint.latitude, longitude: viewpoint.longitude)
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
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

struct HeadingDot: View {
    let headingDeg: Double?

    var body: some View {
        ZStack {
            if let headingDeg {
                HeadingCone()
                    .fill(.blue.opacity(0.22))
                    .frame(width: 54, height: 54)
                    .rotationEffect(.degrees(headingDeg))
            }
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 2)
        }
        .frame(width: 58, height: 58)
        .allowsHitTesting(false)
    }
}

private struct HeadingCone: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.08))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.08),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.05)
        )
        path.closeSubpath()
        return path
    }
}
