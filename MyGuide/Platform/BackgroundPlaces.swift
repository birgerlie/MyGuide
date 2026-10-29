import CoreLocation
import MyGuideCore
import Observation
import os
import UIKit

/// Prepares the nearby list while the app is closed (spec 7, 14.5–14.7): the significant-location-change service
/// wakes (or relaunches) the app roughly every 500 m; each wake asks for one accurate fix, and with it the shared
/// `NearbyPlaces` refreshes when its background rule allows (not above 8 m/s, not within 600 s of the last refresh),
/// under a background task capped at 25 s (less when iOS gives less time). Runs only with the setting on and location
/// access Always. A wake that the cheap gates already rule out (too fast, too soon) never asks for a fix, so most
/// wakes while driving do not power GPS.
///
/// Depends on no screen and no `AppServices` instance: the app delegate starts it at launch, also on a relaunch for a
/// location event, and it reaches the list through `AppServices.sharedNearby`.
@MainActor
@Observable
final class BackgroundPlaces: NSObject {
    static let shared = BackgroundPlaces()

    /// The `UserDefaults` / `@AppStorage` key of the "Prepare places in the background" setting (Bool, default true).
    nonisolated static let settingKey = "prepareBackgroundPlaces"
    /// A background refresh not done in this time is dropped.
    nonisolated static let refreshCap: TimeInterval = 25
    /// Kept back from iOS's remaining background time, so the task ends before the system's deadline.
    nonisolated static let backgroundTimeMargin: TimeInterval = 3
    /// The `UserDefaults` key set once this app has asked for Always (here or in walking mode). iOS shows that prompt
    /// only once; after it the setting can only be changed in the Settings app.
    nonisolated static let alwaysRequestedKey = "alwaysAuthorizationRequested"
    /// The wake's fix request is given up after this long. `requestLocation` itself reports a failure after about
    /// 10 s; this only guards against a delivery this class declined (too coarse) leaving the request open.
    nonisolated static let fixTimeout: Duration = .seconds(15)
    /// A delivery coarser than this (metres) while a fix is requested is taken for a significant-change update, not
    /// the fix. Comfortably inside the list's 500 m radius.
    nonisolated static let fixAccuracy = 200.0

    /// The setting as stored; on when never set.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// A location delivery reduced to plain values, so it can cross from the delegate to the main actor.
    private struct Fix: Sendable {
        var coordinate: Coordinate
        var accuracy: Double
        var timestamp: Date
        /// m/s; nil when CoreLocation has none (negative).
        var speed: Double?

        init(_ location: CLLocation) {
            coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            accuracy = location.horizontalAccuracy
            timestamp = location.timestamp
            speed = location.speed >= 0 ? location.speed : nil
        }
    }

    /// The open fix request: the background time held for it, and its timeout.
    private struct FixRequest {
        var hold: BackgroundTaskHold
        var timeout: Task<Void, Never>
    }

    /// The location authorization as last reported; observed by Settings, whose toggle reads on only with Always.
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var monitoring = false
    @ObservationIgnored private var fixRequest: FixRequest?
    @ObservationIgnored private var refreshing = false
    /// True while a significant-change wake's cheap gates are being checked, so a burst of wakes asks once.
    @ObservationIgnored private var wakeCheckRunning = false
    /// Set when the setting was turned on while access was undetermined: once When In Use is granted, Always is asked.
    @ObservationIgnored private var upgradeToAlwaysPending = false

    private override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        // Only for `requestLocation`: the significant-change service ignores it.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Lets the wake's one fix arrive with the app in the background. No continuous updates are ever started, so
        // this keeps no GPS running and shows no indicator.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    /// Starts monitoring significant changes when the setting is on and access is Always; otherwise does nothing.
    /// Safe to call repeatedly. On a relaunch for a location event, calling it again is what delivers that event.
    func start() {
        guard Self.isEnabled, manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.significantLocationChangeMonitoringAvailable(), !monitoring else { return }
        monitoring = true
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Stops monitoring and gives up an open fix request. A refresh under way finishes (or hits its cap) on its own.
    func stop() {
        monitoring = false
        manager.stopMonitoringSignificantLocationChanges()
        endFixRequest()
    }

    /// The setting was turned on: asks for Always when it is missing (When In Use first when undetermined), and
    /// starts at once when it is already there. A grant later starts monitoring from the authorization callback.
    /// When the prompt can no longer appear (denied, restricted, or When In Use after Always was already asked), it
    /// opens this app's page in the Settings app instead.
    func settingTurnedOn() {
        switch manager.authorizationStatus {
        case .notDetermined:
            upgradeToAlwaysPending = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            if UserDefaults.standard.bool(forKey: Self.alwaysRequestedKey) {
                Self.openAppSettings()
            } else {
                requestAlways()
            }
        case .authorizedAlways:
            start()
        case .denied, .restricted:
            Self.openAppSettings()
        @unknown default:
            break
        }
    }

    /// Asks for Always and remembers that it was asked.
    private func requestAlways() {
        Self.noteAlwaysRequested()
        manager.requestAlwaysAuthorization()
    }

    /// Records that the Always prompt has been asked for; walking mode calls it too.
    nonisolated static func noteAlwaysRequested() {
        UserDefaults.standard.set(true, forKey: alwaysRequestedKey)
    }

    private static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Wakes

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        switch status {
        case .authorizedAlways:
            upgradeToAlwaysPending = false
            start()
        case .authorizedWhenInUse:
            if upgradeToAlwaysPending {
                upgradeToAlwaysPending = false
                requestAlways()
            }
            // Without Always the service cannot wake a closed app; do not leave it running in the foreground only.
            if monitoring { stop() }
        case .denied, .restricted:
            upgradeToAlwaysPending = false
            if monitoring { stop() }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func received(_ fixes: [Fix]) {
        guard let last = fixes.last else { return }
        if fixRequest != nil {
            // The requested fix: valid, at most `LocationFix.maxAge` old (`requestLocation` may answer with a recent
            // cached fix, dated before the request) and accurate enough. Anything else (a coarse significant-change
            // update arriving meanwhile) is ignored; the request stays open until its fix, failure or timeout.
            guard let usable = LocationFix.usable(latitude: last.coordinate.latitude,
                                                  longitude: last.coordinate.longitude,
                                                  horizontalAccuracy: last.accuracy, timestamp: last.timestamp,
                                                  now: .now),
                  usable.accuracy <= Self.fixAccuracy else { return }
            endFixRequest()
            refreshIfNeeded(with: last)
        } else {
            // A significant-change wake. The gates that need no accurate position (speed when the update has one, the
            // 600 s since the last refresh, the 60 s since the last attempt) are checked first; only a wake they allow
            // asks for one accurate fix, which then goes through the whole rule.
            guard monitoring, !wakeCheckRunning, !refreshing else { return }
            wakeCheckRunning = true
            let nearby = AppServices.sharedNearby
            let language = AppServices.currentStoryLanguage()
            let speed = last.speed
            Task { @MainActor [weak self] in
                let allowed = await nearby.backgroundMayRefresh(speed: speed, language: language)
                guard let self else { return }
                self.wakeCheckRunning = false
                guard allowed, self.monitoring else { return }
                self.requestFix()
            }
        }
    }

    private func failed(code: CLError.Code?, error: any Error) {
        if code == .denied {
            stop()
            return
        }
        guard fixRequest != nil else { return }
        endFixRequest()
        AppServices.logNearbyFailure("background fix failed", error)
    }

    /// One `requestLocation`, held under background time so the app is not suspended while it waits.
    private func requestFix() {
        guard fixRequest == nil, !refreshing else { return }
        let hold = BackgroundTaskHold.begin(name: "nearby fix", category: "nearby")
        let timeout = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.fixTimeout)) != nil, let self, self.fixRequest != nil else { return }
            Self.log.notice("background fix timed out")
            self.endFixRequest()
        }
        fixRequest = FixRequest(hold: hold, timeout: timeout)
        manager.requestLocation()
    }

    private func endFixRequest() {
        guard let request = fixRequest else { return }
        fixRequest = nil
        request.timeout.cancel()
        request.hold.end()
    }

    /// With the wake's fix: refreshes when the background rule allows, under a background task, dropped after
    /// `refreshCap` or iOS's remaining background time less `backgroundTimeMargin`, whichever is shorter. The task is
    /// ended exactly once (`BackgroundTaskHold`), whether the refresh finishes, fails, is dropped, or background time
    /// runs out first.
    private func refreshIfNeeded(with fix: Fix) {
        guard !refreshing else { return }
        refreshing = true
        let hold = BackgroundTaskHold.begin(name: "nearby refresh", category: "nearby")
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let cap = Self.cap(backgroundTimeRemaining: remaining)
        let nearby = AppServices.sharedNearby
        let language = AppServices.currentStoryLanguage()
        let position = fix.coordinate
        let speed = fix.speed
        Task { @MainActor [weak self] in
            defer {
                self?.refreshing = false
                hold.end()
            }
            guard await nearby.shouldRefresh(at: position, trigger: .background(speed: speed), language: language) else {
                return
            }
            // In the foreground iOS reports an unbounded remaining time (DBL_MAX).
            let remainingText = remaining > 1_000_000 ? "unbounded" : "\(Int(remaining.rounded())) s"
            Self.log.info("background refresh starting, background time \(remainingText, privacy: .public)")
            guard let cap else {
                Self.log.notice("background refresh skipped: too little background time")
                return
            }
            switch await Self.refresh(nearby, at: position, language: language, cap: cap) {
            case .done:
                Self.log.info("background refresh done")
            case .failed(let error):
                AppServices.logNearbyFailure("background refresh failed", error)
            case .timedOut:
                Self.log.notice("background refresh dropped after \(Int(cap.rounded()), privacy: .public) s")
            }
        }
    }

    /// min(`refreshCap`, remaining − `backgroundTimeMargin`); nil when that leaves no time at all.
    nonisolated static func cap(backgroundTimeRemaining remaining: TimeInterval) -> TimeInterval? {
        let cap = min(refreshCap, remaining - backgroundTimeMargin)
        return cap > 0 ? cap : nil
    }

    private enum RefreshOutcome: Sendable {
        case done
        case failed(any Error)
        case timedOut
    }

    /// Races the refresh against `cap` seconds; the loser is cancelled. A cancelled refresh caller stops waiting at
    /// once (`NearbyPlaces.refresh`), so this returns by the cap.
    nonisolated private static func refresh(_ nearby: NearbyPlaces, at position: Coordinate,
                                            language: StoryLanguage, cap: TimeInterval) async -> RefreshOutcome {
        await withTaskGroup(of: RefreshOutcome?.self) { group in
            group.addTask {
                do {
                    try await nearby.refresh(at: position, language: language)
                    return .done
                } catch is CancellationError {
                    return nil
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                // Cancelled (the refresh won): nil, so it never counts as a timeout.
                guard (try? await Task.sleep(for: .seconds(cap))) != nil else { return nil }
                return .timedOut
            }
            var outcome: RefreshOutcome = .timedOut
            for await result in group {
                if let result {
                    outcome = result
                    break
                }
            }
            group.cancelAll()
            return outcome
        }
    }

    nonisolated private static var log: Logger { AppServices.nearbyLog }
}

// Every delegate method is nonisolated and hops to the main actor (the class is main-actor isolated, so `self` is
// Sendable) with plain values: on a relaunch for a location event nothing here relies on which thread CoreLocation
// calls on.
extension BackgroundPlaces: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Fix.init)
        Task { @MainActor in self.received(fixes) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        Task { @MainActor in self.failed(code: code, error: error) }
    }
}
