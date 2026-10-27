import CoreLocation
import MyGuideCore
import Observation

/// A position good enough to send: a valid fix no older than `LocationProvider.maxFixAge`.
struct LocationFix: Sendable, Equatable {
    var coordinate: Coordinate
    /// Metres; always >= 0.
    var accuracy: Double
}

/// Continuous position and compass heading for the capture screen.
@MainActor
@Observable
final class LocationProvider: NSObject {
    /// Brief, Task 10 step 4: a location older than this counts as no coordinate.
    nonisolated static let maxFixAge: TimeInterval = 60

    var location: CLLocation?
    var compass: CompassReading?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
        // The UI is portrait-only; heading is the direction the top of the device (and the back camera) points.
        manager.headingOrientation = .portrait
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

    /// Sanitises CoreLocation sentinels: negative `horizontalAccuracy` marks an invalid fix,
    /// and a fix older than `maxFixAge` counts as none.
    nonisolated static func usableFix(_ location: CLLocation?, now: Date) -> LocationFix? {
        guard let location,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy.isFinite,
              CLLocationCoordinate2DIsValid(location.coordinate),
              now.timeIntervalSince(location.timestamp) <= maxFixAge else { return nil }
        return LocationFix(coordinate: Coordinate(latitude: location.coordinate.latitude,
                                                  longitude: location.coordinate.longitude),
                           accuracy: location.horizontalAccuracy)
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
        MainActor.assumeIsolated { self.beginUpdatesIfAuthorized() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { self.location = last }
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
