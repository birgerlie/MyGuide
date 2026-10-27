import MyGuideCore
import UserNotifications

/// Posts and manages buzz notifications: the BUZZ category with its Skip action, time-sensitive delivery.
enum BuzzNotifier {
    nonisolated static let category = "BUZZ"
    nonisolated static let skipAction = "SKIP"
    private static let thread = "walk"

    /// Registers category BUZZ, merging with the categories other features registered (never replacing them).
    static func registerCategory() async {
        let center = UNUserNotificationCenter.current()
        let skip = UNNotificationAction(identifier: skipAction, title: "Skip", options: [])
        let buzz = UNNotificationCategory(identifier: category, actions: [skip], intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories().filter { $0.identifier != category }
        categories.insert(buzz)
        center.setNotificationCategories(categories)
    }

    /// Delivers the buzz at once; the request identifier is the buzz id.
    static func post(_ buzz: Buzz) async throws {
        let content = UNMutableNotificationContent()
        content.title = buzz.title
        content.body = buzz.detail
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = thread
        content.sound = .default
        content.userInfo = ["buzzID": buzz.id.uuidString, "placeID": buzz.place.candidate.id]
        let request = UNNotificationRequest(identifier: buzz.id.uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    /// Removes the BUZZ notifications still in the notification centre.
    static func removeDelivered() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == category }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// The command a response to a BUZZ notification stands for; nil for actions this build does not handle.
    @MainActor
    static func command(for response: UNNotificationResponse) -> WalkingCommand? {
        guard response.actionIdentifier == skipAction,
              let text = response.notification.request.content.userInfo["buzzID"] as? String,
              let id = UUID(uuidString: text) else { return nil }
        return .skip(buzzID: id)
    }
}
