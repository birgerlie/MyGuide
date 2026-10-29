import ActivityKit
import AVFoundation
import CoreLocation
import MyGuideCore
import Observation
import UIKit
import UserNotifications

/// State behind the Walking check screen: a background-location run, a notification-action audio test
/// and a Live Activity updated from the background.
/// Owned by `AppServices`, so a run continues while the phone is locked and the screen is gone.
@MainActor
@Observable
final class WalkingCheckModel: NSObject {
    nonisolated static let category = "CHECK"
    nonisolated static let tellAction = "CHECK_TELL"
    nonisolated static let skipAction = "CHECK_SKIP"
    private static let buzzDelay: TimeInterval = 10
    private static let requiredBackgroundFixes = 10
    private static let activityUpdateDelay: TimeInterval = 60

    // Background location
    private(set) var locationRunning = false
    private(set) var authorization: CLAuthorizationStatus
    private(set) var totalFixes = 0
    private(set) var backgroundFixes = 0
    private(set) var longestGap: TimeInterval = 0

    // Buzz from the watch
    private(set) var buzzPending = false
    /// nil until the test runs: the view words that as «Ikke startet» in the iPhone's language.
    private(set) var buzzStatus: String?
    private(set) var buzzResult: CheckResult?

    // Live Activity
    private(set) var activityRunning = false
    /// nil until the test runs (worded by the view).
    private(set) var activityStatus: String?
    private(set) var activityResult: CheckResult?

    // Watch
    /// nil until a Tell me arrives from the watch (worded by the view).
    private(set) var watchTellStatus: String?
    private(set) var watchTellResult: CheckResult?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var activitySession: CLBackgroundActivitySession?
    @ObservationIgnored private var lastFixAt: Date?
    @ObservationIgnored private var lastFixWasBackground = false
    @ObservationIgnored private var activityID: String?
    @ObservationIgnored private var activityTimer: Task<Void, Never>?
    @ObservationIgnored private let player = AudioPlayer()
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var buzzTimer: Task<Void, Never>?

    /// The iPhone's language: every status is a screen text (spec 17).
    private var language: StoryLanguage { UILanguage.current }

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        player.onFinish = { [weak self] _ in self?.endBackgroundWork() }
    }

    // MARK: - Background location

    var locationStatus: String {
        let counts = locationRunning || totalFixes > 0
            ? (total: totalFixes, background: backgroundFixes, gap: Int(longestGap.rounded()))
            : nil
        return WalkingCheckTexts.locationStatus(authorization: authorization, counts: counts, language)
    }

    /// Nil while a run is still waiting for its first background fix.
    var locationResult: CheckResult? {
        if backgroundFixes >= Self.requiredBackgroundFixes {
            return CheckResult(passed: true, detail: WalkingCheckTexts.backgroundPassed(
                fixes: backgroundFixes, gap: Int(longestGap.rounded()), language))
        }
        if locationRunning { return nil }
        if authorization == .denied || authorization == .restricted {
            return CheckResult(passed: false, detail: WalkingCheckTexts.locationNotGranted(language))
        }
        guard totalFixes > 0 else { return nil }
        let detail = backgroundFixes == 0
            ? WalkingCheckTexts.noBackgroundFixes(language)
            : WalkingCheckTexts.tooFewBackgroundFixes(backgroundFixes, needed: Self.requiredBackgroundFixes, language)
        return CheckResult(passed: false, detail: detail)
    }

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        totalFixes = 0
        backgroundFixes = 0
        longestGap = 0
        lastFixAt = nil
        lastFixWasBackground = false
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

    /// Counts one fix. Gaps come from the fix's own timestamp, and only between two consecutive fixes
    /// that both arrived in the background, so time spent in the foreground never inflates them.
    private func record(_ fix: CLLocation) {
        let inBackground = UIApplication.shared.applicationState == .background
        totalFixes += 1
        if inBackground { backgroundFixes += 1 }
        if inBackground, lastFixWasBackground, let lastFixAt {
            longestGap = max(longestGap, fix.timestamp.timeIntervalSince(lastFixAt))
        }
        lastFixAt = fix.timestamp
        lastFixWasBackground = inBackground
    }

    // MARK: - Buzz from the watch

    func startBuzz() async {
        guard !buzzPending else { return }
        buzzResult = nil
        let language = language
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])  // time-sensitive needs only the entitlement
            guard granted else {
                buzzStatus = WalkingCheckTexts.notificationsNotGranted(language)
                buzzResult = CheckResult(passed: false, detail: WalkingCheckTexts.notificationsNotGranted(language))
                return
            }
            // Merge, never replace: other features register their own categories.
            let tell = UNNotificationAction(identifier: Self.tellAction, title: WalkingCheckTexts.tellMe(language),
                                            options: [])
            let skip = UNNotificationAction(identifier: Self.skipAction, title: WalkingCheckTexts.skip(language),
                                            options: [])
            let check = UNNotificationCategory(identifier: Self.category, actions: [tell, skip],
                                               intentIdentifiers: [], options: [])
            var categories = await center.notificationCategories().filter { $0.identifier != Self.category }
            categories.insert(check)
            center.setNotificationCategories(categories)

            let content = UNMutableNotificationContent()
            content.title = WalkingCheckTexts.testTitle(language)
            content.body = WalkingCheckTexts.testBody(language)
            content.categoryIdentifier = Self.category
            content.interruptionLevel = .timeSensitive
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.buzzDelay, repeats: false)
            try await center.add(UNNotificationRequest(identifier: "check-buzz", content: content, trigger: trigger))
        } catch {
            buzzStatus = WalkingCheckTexts.scheduleFailed(error.localizedDescription, language)
            buzzResult = CheckResult(passed: false,
                                     detail: WalkingCheckTexts.notificationError(error.localizedDescription, language))
            return
        }
        buzzPending = true
        buzzStatus = WalkingCheckTexts.notificationScheduled(inS: Int(Self.buzzDelay), language)
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
        buzzStatus = WalkingCheckTexts.cancelled(language)
    }

    private func buzzTimedOut() {
        guard buzzPending else { return }
        buzzPending = false
        buzzStatus = WalkingCheckTexts.noAction(language)
        buzzResult = CheckResult(passed: false,
                                 detail: WalkingCheckTexts.noActionWithin(Int(Self.buzzDelay + 60), language))
    }

    /// Handles a response to the CHECK notification. Takes its background task synchronously.
    func handle(_ response: UNNotificationResponse) {
        guard response.notification.request.content.categoryIdentifier == Self.category else { return }
        buzzTimer?.cancel()
        buzzTimer = nil
        buzzPending = false
        switch response.actionIdentifier {
        case Self.tellAction:
            let outcome = playTone()
            buzzStatus = outcome.status
            buzzResult = outcome.result
        case Self.skipAction:
            buzzStatus = WalkingCheckTexts.skipped(language)
            buzzResult = CheckResult(passed: false, detail: WalkingCheckTexts.skippedDetail(language))
        default:
            buzzStatus = WalkingCheckTexts.openedWithoutAction(language)
        }
    }

    /// Plays the check tone under a background task. Shared by the notification action and the watch's `check.tell`.
    /// Takes the background task synchronously, before anything can suspend the app.
    private func playTone() -> (status: String, result: CheckResult) {
        let inBackground = UIApplication.shared.applicationState == .background
        beginBackgroundWork()
        do {
            try player.play(try Self.toneURL())
        } catch {
            endBackgroundWork()
            return (WalkingCheckTexts.playbackFailed(language),
                    CheckResult(passed: false, detail: WalkingCheckTexts.playbackError(error.localizedDescription, language)))
        }
        let result = inBackground
            ? CheckResult(passed: true, detail: WalkingCheckTexts.playedInBackground(language))
            : CheckResult(passed: false, detail: WalkingCheckTexts.playedInForeground(language))
        return (WalkingCheckTexts.playingTone(language), result)
    }

    /// The watch's Action button (or watch check screen) sent `check.tell`.
    func handleWatchTell() {
        let outcome = playTone()
        watchTellStatus = WalkingCheckTexts.watchTell(outcome.status, language)
        watchTellResult = outcome.result
    }

    /// A 2 s tone at 880 Hz in Caches, written again if the system purged it.
    private static func toneURL() throws -> URL {
        let url = URL.cachesDirectory.appending(path: "check-tone.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try TestTone.wavData(frequency: 880, duration: 2, sampleRate: 22050).write(to: url, options: .atomic)
        }
        return url
    }

    // MARK: - Live Activity

    /// Starts an activity in the foreground, then updates it from the background after 60 s.
    /// The update relies on the background location run (row 1) keeping the app alive until then.
    func startActivity() async {
        guard !activityRunning else { return }
        activityRunning = true  // also guards against a second tap while old activities are being ended
        activityResult = nil
        // Only the check's own earlier activity is ended: walking mode's must survive the check (leftovers from an
        // earlier launch are ended at launch).
        if let previous = activityID {
            activityID = nil
            await Self.endActivity(id: previous)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityRunning = false
            activityStatus = WalkingCheckTexts.activitiesOff(language)
            activityResult = CheckResult(passed: false, detail: WalkingCheckTexts.activitiesOffDetail(language))
            return
        }
        let state = WalkingActivityAttributes.ContentState(headline: WalkingCheckTexts.activityHeadline(language),
                                                           body: WalkingCheckTexts.activityBody(language),
                                                           updatedAt: .now)
        do {
            activityID = try Activity.request(attributes: WalkingActivityAttributes(startedAt: .now),
                                              content: ActivityContent(state: state, staleDate: nil)).id
        } catch {
            activityRunning = false
            activityStatus = WalkingCheckTexts.activityStartFailed(error.localizedDescription, language)
            activityResult = CheckResult(passed: false,
                                         detail: WalkingCheckTexts.activityError(error.localizedDescription, language))
            return
        }
        activityStatus = WalkingCheckTexts.activityStarted(updateInS: Int(Self.activityUpdateDelay),
                                                           locationRunning: locationRunning, language)
        activityTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.activityUpdateDelay)) } catch { return }
            await self?.updateActivityFromTimer()
        }
    }

    func endActivity() {
        activityTimer?.cancel()
        activityTimer = nil
        let id = activityID
        activityID = nil
        activityRunning = false
        activityStatus = WalkingCheckTexts.ended(language)
        if let id { Task { await Self.endActivity(id: id) } }
    }

    // `Activity` is not Sendable, so it is looked up by id inside these nonisolated helpers
    // instead of being held across an await on the main actor.
    private nonisolated static func endActivity(id: String) async {
        await Activity<WalkingActivityAttributes>.activities.first { $0.id == id }?
            .end(nil, dismissalPolicy: .immediate)
    }

    /// Returns whether the activity was still active after the update.
    private nonisolated static func updateActivity(id: String, to state: WalkingActivityAttributes.ContentState) async -> Bool {
        guard let activity = Activity<WalkingActivityAttributes>.activities.first(where: { $0.id == id }) else { return false }
        await activity.update(ActivityContent(state: state, staleDate: nil))
        // `update` does not throw; an activity the system or the user ended is no longer active.
        return activity.activityState == .active
    }

    private func updateActivityFromTimer() async {
        guard let id = activityID else { return }
        let inBackground = UIApplication.shared.applicationState == .background
        let state = WalkingActivityAttributes.ContentState(
            headline: WalkingCheckTexts.updatedFromBackgroundHeadline(language),
            body: Date.now.formatted(date: .omitted, time: .standard),
            updatedAt: .now)
        let succeeded = await Self.updateActivity(id: id, to: state)
        guard activityID == id else { return }  // ended while the update was in flight
        activityTimer = nil
        switch (succeeded, inBackground) {
        case (true, true):
            activityStatus = WalkingCheckTexts.updateSentFromBackground(language)
            activityResult = CheckResult(passed: true, detail: WalkingCheckTexts.updateSentFromBackground(language) + " ✓")
        case (true, false):
            activityStatus = WalkingCheckTexts.updatedInForeground(language)
            activityResult = CheckResult(passed: false, detail: WalkingCheckTexts.updatedInForegroundDetail(language))
        case (false, _):
            activityStatus = WalkingCheckTexts.updateFailed(language)
            activityResult = CheckResult(passed: false, detail: WalkingCheckTexts.activityGone(language))
        }
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
        MainActor.assumeIsolated { for location in locations { self.record(location) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; only denial ends the run.
        guard (error as? CLError)?.code == .denied else { return }
        MainActor.assumeIsolated { self.stopLocation() }
    }
}
