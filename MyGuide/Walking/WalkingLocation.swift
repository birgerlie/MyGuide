import CoreLocation

/// The walking controller's own location manager, so the capture screen's `LocationProvider` and the Walking check
/// screen keep working untouched. Background updates, a 5 m distance filter, no automatic pausing.
@MainActor
final class WalkingLocation: NSObject {
    /// Every fix CoreLocation delivers, oldest first within one delivery.
    var onLocation: ((CLLocation) -> Void)?
    /// Called whenever the authorization status changes (also with the status at the time the delegate is set).
    var onAuthorization: (() -> Void)?
    /// Called when access is denied or restricted while updates run.
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private var activitySession: CLBackgroundActivitySession?
    private var running = false
    private var authorizationWaiter: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// The last position CoreLocation knows, if any; used to name the city before the first fix arrives.
    var lastKnown: CLLocation? { manager.location }

    /// Shows the When In Use prompt when access is undetermined and waits for the answer.
    func requestWhenInUse() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationWaiter = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks to upgrade When In Use to Always. The prompt is answered later, so this does not wait; a refusal
    /// leaves walking mode running with a reminder.
    func requestAlways() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func start() {
        guard !running else { return }
        running = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        activitySession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        activitySession?.invalidate()
        activitySession = nil
    }
}

// CLLocationManager calls its delegate on the thread it was created on; it is created on the main actor.
extension WalkingLocation: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status != .notDetermined, let waiter = self.authorizationWaiter {
                self.authorizationWaiter = nil
                waiter.resume()
            }
            if self.running, status == .denied || status == .restricted { self.onDenied?() }
            self.onAuthorization?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { for location in locations { self.onLocation?(location) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; only denial ends the run.
        guard (error as? CLError)?.code == .denied else { return }
        MainActor.assumeIsolated { if self.running { self.onDenied?() } }
    }
}
