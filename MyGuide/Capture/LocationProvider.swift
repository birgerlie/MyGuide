import CoreLocation
import MyGuideCore
import Observation

/// Continuous position and compass heading for the capture screen.
@MainActor
@Observable
final class LocationProvider: NSObject {
    var location: CLLocation?
    var compass: CompassReading?
    /// Told every usable fix (`usableFix`) as it arrives; the owner feeds foreground refreshes of the nearby list
    /// with it while this provider runs (camera open, or a story offering "Use where I am now").
    @ObservationIgnored var onFix: ((LocationFix) -> Void)?
    /// Location access as last reported; the map says so when it is denied or restricted (spec 16.6).
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
        // The UI is portrait-only; heading is the direction the top of the device (and the back camera) points.
        manager.headingOrientation = .portrait
        authorization = manager.authorizationStatus
    }

    func start() {
        wantsUpdates = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        beginUpdatesIfAuthorized()
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// The current location as a usable fix, or nil if there is none, it is invalid or it is stale.
    func fix(at now: Date = .now) -> LocationFix? {
        Self.usableFix(location, now: now)
    }

    /// Applies `LocationFix.usable` (sentinel and 60 s staleness rules) to a CoreLocation fix.
    nonisolated static func usableFix(_ location: CLLocation?, now: Date) -> LocationFix? {
        guard let location else { return nil }
        return LocationFix.usable(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                  horizontalAccuracy: location.horizontalAccuracy,
                                  timestamp: location.timestamp, now: now)
    }

    private func beginUpdatesIfAuthorized() {
        guard wantsUpdates else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        case .denied, .restricted:
            location = nil
            compass = nil
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}

// CLLocationManager calls its delegate on the thread it was created on; it is created on the main actor.
extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if self.authorization != status { self.authorization = status }
            self.beginUpdatesIfAuthorized()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated {
            self.location = last
            if let fix = Self.usableFix(last, now: .now) { self.onFix?(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let reading = CompassReading(trueHeading: newHeading.trueHeading,
                                     magneticHeading: newHeading.magneticHeading,
                                     headingAccuracy: newHeading.headingAccuracy)
        MainActor.assumeIsolated { self.compass = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient: CoreLocation keeps trying. Denial clears the readings.
        guard (error as? CLError)?.code == .denied else { return }
        MainActor.assumeIsolated {
            self.location = nil
            self.compass = nil
        }
    }
}
