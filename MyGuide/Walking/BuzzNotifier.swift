import MyGuideCore
import UserNotifications

/// Posts and manages walking-mode notifications: a buzz (Tell me, Skip), the offer of the next part (More, Skip)
/// a story that could not be told and a stop story. Every one carries its buzz id in `userInfo["buzzID"]`.
enum BuzzNotifier {
    nonisolated static let category = "BUZZ"
    nonisolated static let moreCategory = "MORE"
    nonisolated static let failedCategory = "STORY_FAILED"
    nonisolated static let stopCategory = "STOP"
    nonisolated static let tellMeAction = "TELL_ME"
    nonisolated static let moreAction = "MORE"
    nonisolated static let skipAction = "SKIP"
    /// The categories `stop()` clears from the notification centre; a failure report stays.
    private static let walkCategories: Set<String> = [category, moreCategory]
    private static let thread = "walk"
    private static let buzzIDKey = "buzzID"

    static let failedTitle = "Couldn't get the story"
    static let moreBody = "Tap More for the next part."

    /// Registers BUZZ, MORE, STORY_FAILED and STOP, merging with the categories other features registered (never
    /// replacing them). The actions run in the background: the story plays without unlocking the phone.
    static func registerCategories() async {
        let center = UNUserNotificationCenter.current()
        let tellMe = UNNotificationAction(identifier: tellMeAction, title: "Tell me", options: [])
        let more = UNNotificationAction(identifier: moreAction, title: "More", options: [])
        let skip = UNNotificationAction(identifier: skipAction, title: "Skip", options: [])
        let ours = [
            UNNotificationCategory(identifier: category, actions: [tellMe, skip], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: moreCategory, actions: [more, skip], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: failedCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: stopCategory, actions: [], intentIdentifiers: [], options: []),
        ]
        let ourIDs = Set(ours.map(\.identifier))
        var categories = await center.notificationCategories().filter { !ourIDs.contains($0.identifier) }
        categories.formUnion(ours)
        center.setNotificationCategories(categories)
    }

    /// Delivers the buzz at once; the request identifier is the buzz id.
    static func post(_ buzz: Buzz) async throws {
        let content = content(category: category, title: buzz.title, body: buzz.detail, id: buzz.id)
        content.userInfo["placeID"] = buzz.place.candidate.id
        try await add(content, identifier: buzz.id.uuidString)
    }

    /// Offers the next part of a story that just finished.
    static func postMore(id: UUID, title: String) async throws {
        try await add(content(category: moreCategory, title: title, body: moreBody, id: id), identifier: "\(id)-more")
    }

    /// Delivers a stop story: its title and text, the story id as request identifier. `quiet` leaves out the sound
    /// (another story is playing). Used when the Live Activity cannot show it.
    static func postStop(_ story: WalkStory, quiet: Bool) async throws {
        let content = content(category: stopCategory, title: story.title, body: story.levels.first ?? "", id: story.id)
        if quiet { content.sound = nil }
        try await add(content, identifier: story.id.uuidString)
    }

    /// Says a story could not be told; `body` is the user-facing reason.
    static func postFailure(id: UUID, body: String) async throws {
        try await add(content(category: failedCategory, title: failedTitle, body: body, id: id), identifier: "\(id)-failed")
    }

    /// Says walking mode turned itself off. A plain notification: no category, so `stop()` leaves it in place.
    static func postAutoOff(_ message: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "MyGuide"
        content.body = message
        content.sound = .default
        try await add(content, identifier: "auto-off-\(UUID().uuidString)")
    }

    /// Removes the BUZZ and MORE notifications, both those in the notification centre and those not yet shown.
    static func removeWalkNotifications() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
            .filter { walkCategories.contains($0.request.content.categoryIdentifier) }
            .map(\.request.identifier)
        let pending = await center.pendingNotificationRequests()
            .filter { walkCategories.contains($0.content.categoryIdentifier) }
            .map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    /// Removes the buzz and its More offer, shown or not.
    static func removeNotifications(for id: UUID) {
        let ids = [id.uuidString, "\(id)-more"]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// The command a response stands for: Tell me, More and Skip by action, a tap on the notification itself opens
    /// the story. Nil for a dismissal, an unknown action or a notification without a buzz id.
    @MainActor
    static func command(for response: UNNotificationResponse) -> WalkingCommand? {
        guard let text = response.notification.request.content.userInfo[buzzIDKey] as? String,
              let id = UUID(uuidString: text) else { return nil }
        switch response.actionIdentifier {
        case tellMeAction: return .tellMe(buzzID: id)
        case moreAction: return .more(buzzID: id)
        case skipAction: return .skip(buzzID: id)
        case UNNotificationDefaultActionIdentifier: return .open(buzzID: id)
        default: return nil
        }
    }

    private static func content(category: String, title: String, body: String, id: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = thread
        content.sound = .default
        content.userInfo = [buzzIDKey: id.uuidString]
        return content
    }

    private static func add(_ content: UNNotificationContent, identifier: String) async throws {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
