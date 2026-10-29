import HealthKit
import MyGuideCore
import UserNotifications
import WatchKit

/// Owns the app's models, so the system's workout callbacks reach them even before the first screen appears.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let walk = GuidedWalkModel()
    let check = WatchCheckModel()

    override init() {
        super.init()
        // HealthKit allows one session: the Check screen's test workout gives way to a guided walk.
        walk.willStartWorkout = { [check] in await check.stopWorkoutIfRunning() }
        // Set before launch finishes, so a notification arriving at launch reaches it (spec 18).
        UNUserNotificationCenter.current().delegate = self
    }

    /// The phone called `startWatchApp(with:)`: begin the workout. The walk state comes from the application context.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        walk.startForWorkoutLaunch()
    }

    /// The app was killed during a workout and relaunched to pick it up again.
    func handleActiveWorkoutRecovery() {
        Task {
            guard let recovered = await WorkoutKeeper.recoverActiveSession(HKHealthStore()) else { return }
            walk.adopt(recovered.session)
        }
    }
}

/// Notifications forwarded from the phone while the app is frontmost. Without a delegate the system may not present
/// them at all; with one, a buzz the watch already showed through WatchConnectivity is skipped, so it is felt once
/// (spec 18). Nonisolated: UserNotifications calls in on its own queue, where a main-actor method would trap.
extension WatchAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let content = notification.request.content
        guard let id = GuidedWalkBuzz.notificationBuzzID(category: content.categoryIdentifier,
                                                         userInfo: content.userInfo)
        else { return [.banner, .sound] }
        let shown = await walk.hasShownBuzz(id)
        return shown ? [] : [.banner, .sound]
    }
}
