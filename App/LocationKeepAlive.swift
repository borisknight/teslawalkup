import CoreLocation
import Foundation

/// Keeps the app alive in the background so the BLE RSSI-polling loop keeps
/// running as you approach the car.
///
/// iOS suspends a backgrounded app's timers after ~30s **even with an active
/// BLE connection** — Core Bluetooth only wakes us for discrete *events*
/// (connect/disconnect/notifications), not for our periodic `readRSSI` poll.
/// A low-power background location session is the standard, reliable way to
/// keep the process running so the poll continues. We don't use the location
/// data at all; the session exists purely to prevent suspension.
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // Lowest accuracy + huge distance filter = minimal GPS/battery; we only
        // need the session to exist, not real fixes.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 3000
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.requestAlwaysAuthorization()
        // allowsBackgroundLocationUpdates requires the `location` UIBackgroundMode
        // and an authorized status; set it before starting.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        DiskLog.log("LOCATION keep-alive start (auth=\(manager.authorizationStatus.rawValue))")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DiskLog.log("LOCATION auth=\(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {
        // Intentionally ignored — the session is only here to keep us alive.
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        DiskLog.log("LOCATION error: \(error.localizedDescription)")
    }
}
