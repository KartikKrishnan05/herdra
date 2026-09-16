import Foundation
import CoreLocation

/// Thin wrapper around CLLocationManager. The manager is created on the main
/// thread, so its delegate callbacks arrive on the main queue too.
final class LocationManager: NSObject, ObservableObject {

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        authorization = manager.authorizationStatus
    }

    // MARK: - Control

    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func startUpdating() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - Convenience

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// A fix is good enough to pin a trough when it is recent and reasonably tight.
    var hasUsableFix: Bool {
        guard let location else { return false }
        return location.horizontalAccuracy > 0
            && location.horizontalAccuracy <= 50
            && abs(location.timestamp.timeIntervalSinceNow) < 60
    }

    var accuracyText: String {
        guard let location, location.horizontalAccuracy > 0 else { return "Waiting for a fix" }
        return String(format: "Accurate to about %.0f m", location.horizontalAccuracy)
    }

    var coordinateText: String {
        guard let location else { return "—" }
        return String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
    }
}

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        location = newest
        lastError = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }
}
