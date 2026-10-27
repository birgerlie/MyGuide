import AVFoundation
import CoreLocation
import MyGuideCore
import Observation
import UIKit
import UserNotifications

/// State behind the Walking check screen: a background-location run and a notification-action audio test.
/// Owned by `AppServices`, so a run continues while the phone is locked and the screen is gone.
@MainActor
@Observable
final class WalkingCheckModel: NSObject {
    nonisolated static let category = "CHECK"
    nonisolated static let tellAction = "CHECK_TELL"
    nonisolated static let skipAction = "CHECK_SKIP"
    private static let buzzDelay: TimeInterval = 10

    // Background location
    private(set) var locationRunning = false
    private(set) var authorization: CLAuthorizationStatus
    private(set) var totalFixes = 0
    private(set) var backgroundFixes = 0
    private(set) var longestGap: TimeInterval = 0

    // Buzz from the watch
    private(set) var buzzPending = false
    private(set) var buzzStatus = "Not started"
    private(set) var buzzResult: CheckResult?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var activitySession: CLBackgroundActivitySession?
    @ObservationIgnored private var lastFixAt: Date?
    @ObservationIgnored private let player = AudioPlayer()
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var buzzTimer: Task<Void, Never>?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        player.onFinish = { [weak self] in self?.endBackgroundWork() }
    }

    // MARK: - Background location

    var locationStatus: String {
        let fixes = locationRunning || totalFixes > 0
            ? " · \(totalFixes) fixes, \(backgroundFixes) in background, longest gap \(Int(longestGap.rounded())) s"
            : ""
        return "Authorization: \(Self.describe(authorization))\(fixes)"
    }

    /// Nil while a run is still waiting for its first background fix.
    var locationResult: CheckResult? {
        if backgroundFixes > 0 {
            return CheckResult(passed: true, detail: "\(backgroundFixes) fixes while in background, longest gap \(Int(longestGap.rounded())) s")
        }
        if locationRunning { return nil }
        if authorization == .denied || authorization == .restricted {
            return CheckResult(passed: false, detail: "Location permission not granted")
        }
        return totalFixes > 0 ? CheckResult(passed: false, detail: "No fixes arrived while in background") : nil
    }

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        totalFixes = 0
        backgroundFixes = 0
        longestGap = 0
        lastFixAt = nil
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        activitySession = CLBackgroundActivitySession()
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        continueLocation()
    }

    func stopLocation() {
        locationRunning = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        activitySession?.invalidate()
        activitySession = nil
    }

    /// Escalates When In Use to Always, and starts updates once any authorization is in place.
    private func continueLocation() {
        guard locationRunning else { return }
        switch authorization {
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
        case .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            stopLocation()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func record(_ fix: CLLocation) {
        let now = Date.now
        totalFixes += 1
        if UIApplication.shared.applicationState == .background { backgroundFixes += 1 }
        if let lastFixAt { longestGap = max(longestGap, now.timeIntervalSince(lastFixAt)) }
        lastFixAt = now
    }

    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not asked"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedWhenInUse: "When In Use"
        case .authorizedAlways: "Always"
        @unknown default: "unknown"
        }
    }

    // MARK: - Buzz from the watch

    func startBuzz() async {
        guard !buzzPending else { return }
        buzzResult = nil
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])  // time-sensitive needs only the entitlement
            guard granted else {
                buzzStatus = "Notification permission not granted"
                buzzResult = CheckResult(passed: false, detail: "Notification permission not granted")
                return
            }
            // Merge, never replace: other features register their own categories.
            let tell = UNNotificationAction(identifier: Self.tellAction, title: "Tell me", options: [])
            let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [])
            let check = UNNotificationCategory(identifier: Self.category, actions: [tell, skip],
                                               intentIdentifiers: [], options: [])
            var categories = await center.notificationCategories().filter { $0.identifier != Self.category }
            categories.insert(check)
            center.setNotificationCategories(categories)

            let content = UNMutableNotificationContent()
            content.title = "MyGuide test"
            content.body = "Tap Tell me on your watch"
            content.categoryIdentifier = Self.category
            content.interruptionLevel = .timeSensitive
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.buzzDelay, repeats: false)
            try await center.add(UNNotificationRequest(identifier: "check-buzz", content: content, trigger: trigger))
        } catch {
            buzzStatus = "Could not schedule: \(error.localizedDescription)"
            buzzResult = CheckResult(passed: false, detail: "Notification error: \(error.localizedDescription)")
            return
        }
        buzzPending = true
        buzzStatus = "Notification in \(Int(Self.buzzDelay)) s. Lock the phone and tap Tell me on the watch."
        buzzTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.buzzDelay + 60)) } catch { return }
            self?.buzzTimedOut()
        }
    }

    /// Withdraws the notification and stops any tone and background task.
    func cancelBuzz() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["check-buzz"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["check-buzz"])
        buzzTimer?.cancel()
        buzzTimer = nil
        player.stop()
        endBackgroundWork()
        buzzPending = false
        buzzStatus = "Cancelled"
    }

    private func buzzTimedOut() {
        guard buzzPending else { return }
        buzzPending = false
        buzzStatus = "No action received"
        buzzResult = CheckResult(passed: false, detail: "No Tell me or Skip within 70 s")
    }

    /// Handles a response to the CHECK notification. Takes its background task synchronously.
    func handle(_ response: UNNotificationResponse) {
        guard response.notification.request.content.categoryIdentifier == Self.category else { return }
        buzzTimer?.cancel()
        buzzTimer = nil
        buzzPending = false
        switch response.actionIdentifier {
        case Self.tellAction:
            let inBackground = UIApplication.shared.applicationState == .background
            beginBackgroundWork()
            do {
                try player.play(try Self.toneURL())
                buzzStatus = "Playing the tone"
                buzzResult = CheckResult(passed: true,
                                         detail: inBackground ? "Played from background ✓" : "Played, but the app was in the foreground")
            } catch {
                endBackgroundWork()
                buzzStatus = "Playback failed"
                buzzResult = CheckResult(passed: false, detail: "Playback error: \(error.localizedDescription)")
            }
        case Self.skipAction:
            buzzStatus = "Skipped"
        default:
            buzzStatus = "Notification opened without an action"
        }
    }

    /// A 2 s tone at 880 Hz in Caches, written again if the system purged it.
    private static func toneURL() throws -> URL {
        let url = URL.cachesDirectory.appending(path: "check-tone.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try TestTone.wavData(frequency: 880, duration: 2, sampleRate: 22050).write(to: url, options: .atomic)
        }
        return url
    }

    // MARK: - Background time

    private func beginBackgroundWork() {
        endBackgroundWork()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MyGuide check tone") { [weak self] in
            // Time is up: stop the tone, and end the task through the same path.
            MainActor.assumeIsolated {
                self?.player.stop()
                self?.endBackgroundWork()
            }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        let id = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}

extension WalkingCheckModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorization = status
            self.continueLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { self.record(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; only denial ends the run.
        guard (error as? CLError)?.code == .denied else { return }
        MainActor.assumeIsolated { self.stopLocation() }
    }
}
