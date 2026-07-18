import CoreLocation
import Foundation

/// Lightweight location source for the map views. (Ported from RidgeLine; the
/// heading feed was dropped — nothing consumed it, and it kept the magnetometer
/// running whenever the mini-map was visible.)
@MainActor
final class MapLocationModel: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        // Debug: -noLocationPrompt keeps simulator screenshot runs free of the
        // permission dialog (same flag as the motion heading feed).
        guard !ProcessInfo.processInfo.arguments.contains("-noLocationPrompt") else { return }
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension MapLocationModel: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy <= 500 else { return }
        coordinate = location.coordinate
    }
}
