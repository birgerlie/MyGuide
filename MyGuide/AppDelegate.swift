import UIKit
import UserNotifications

/// The notification-center delegate: shows notifications while the app is open and forwards taps and actions.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Receives every notification response. Set once at launch by `MyGuideApp`, which routes by category.
    @MainActor static var responseHandler: (@MainActor (UNNotificationResponse) -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // The completion-handler form runs synchronously on the main thread, so handlers can take a
    // background task before this returns and iOS may suspend the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // UserNotifications delivers on the main thread, so this value never leaves the main actor.
        nonisolated(unsafe) let response = response
        MainActor.assumeIsolated { Self.responseHandler?(response) }
        completionHandler()
    }
}
