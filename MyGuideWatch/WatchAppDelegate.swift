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
/// them at all; with one, a buzz already felt through WatchConnectivity is skipped, and a buzz presented here is
/// counted as felt, so the WatchConnectivity message that follows shows its card without a second haptic (spec 18).
/// Listen tapped on a forwarded buzz reaches the phone as the card's «Lytt» does.
/// Nonisolated: UserNotifications calls in on its own queue, where a main-actor method would trap. The async forms
/// complete the system's request when they return.
extension WatchAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let content = notification.request.content
        guard let id = GuidedWalkBuzz.notificationBuzzID(category: content.categoryIdentifier,
                                                         userInfo: content.userInfo)
        else { return [.banner, .sound] }
        return await walk.notificationArrived(forBuzz: id) ? [.banner, .sound] : []
    }

    /// Listen on a buzz → the phone tells its story. Skip, a tap on the notification itself, a dismissal or any other
    /// notification: nothing to send (the phone moves on by itself).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard response.actionIdentifier == GuidedWalkBuzz.notificationTellAction,
              let id = GuidedWalkBuzz.notificationBuzzID(category: content.categoryIdentifier,
                                                         userInfo: content.userInfo)
        else { return }
        await walk.listenFromNotification(buzzID: id)
    }
}
