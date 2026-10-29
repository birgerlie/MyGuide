import MyGuideCore
import UserNotifications

/// Posts and manages walking-mode notifications: a buzz (Listen, Skip), the offer of the next part (More, Skip)
/// a story that could not be told and a stop story. Every one carries its buzz id in `userInfo["buzzID"]`; BUZZ, MORE
/// and STOP also carry a `NotificationPayload` for the expanded view. Texts and action titles follow the story language
/// (spec 7.1).
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

    /// Registers BUZZ, MORE, STORY_FAILED and STOP, merging with the categories other features registered (never
    /// replacing them). The actions run in the background: the story plays without unlocking the phone. Their titles
    /// are in the story language; call again when it changes.
    static func registerCategories() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        // Read after the wait: of two overlapping calls, the one that sets last uses the language as it is then.
        let language = AppServices.currentStoryLanguage()
        let tellMe = UNNotificationAction(identifier: tellMeAction, title: NotificationText.listen(language), options: [])
        let more = UNNotificationAction(identifier: moreAction, title: NotificationText.more(language), options: [])
        let skip = UNNotificationAction(identifier: skipAction, title: NotificationText.skip(language), options: [])
        let ours = [
            UNNotificationCategory(identifier: category, actions: [tellMe, skip], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: moreCategory, actions: [more, skip], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: failedCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: stopCategory, actions: [], intentIdentifiers: [], options: []),
        ]
        let ourIDs = Set(ours.map(\.identifier))
        var categories = existing.filter { !ourIDs.contains($0.identifier) }
        categories.formUnion(ours)
        center.setNotificationCategories(categories)
    }

    /// The place's picture for its notification: the cached one, else fetched for at most `PlaceImages.notificationCap`
    /// (1.5 s; spec 7.3). nil without a picture, past the cap, or for a place without an article.
    static func picture(for candidate: Candidate, from images: PlaceImages) async -> StoredPlaceImage? {
        guard let title = PlaceImages.title(for: candidate) else { return nil }
        return await images.image(wikipediaTitle: title, within: PlaceImages.notificationCap)
    }

    /// The place's picture only when it is already cached; never fetches.
    static func cachedPicture(for candidate: Candidate?, from images: PlaceImages) async -> StoredPlaceImage? {
        guard let candidate, let title = PlaceImages.title(for: candidate) else { return nil }
        return await images.cached(wikipediaTitle: title)
    }

    /// Delivers the buzz at once; the request identifier is the buzz id. Title the place name, subtitle its distance
    /// and direction from `course` (the one the buzz was decided with), body the factual line (spec 7.1, 7.2).
    static func post(_ buzz: Buzz, course: Double?, language: StoryLanguage, picture: StoredPlaceImage?) async throws {
        let candidate = buzz.place.candidate
        let line = BuzzText.localizedDetail(distance: buzz.distance, bearing: buzz.bearing, course: course,
                                            language: language)
        let fact = FactLine.text(for: candidate, language: language)
        let content = content(category: category, title: buzz.title, body: fact ?? "", id: buzz.id)
        content.subtitle = line
        content.userInfo["placeID"] = candidate.id
        let payload = NotificationPayload(label: NotificationText.nearbyLabel(language), name: buzz.title, line: line,
                                          fact: fact, credit: nil)
        try await add(content, payload: payload, picture: picture, language: language, identifier: buzz.id.uuidString)
    }

    /// Offers the next part of a story that just finished: the place's factual line and picture, no distance (it
    /// would be stale by now).
    static func postMore(id: UUID, title: String, place: Candidate?, language: StoryLanguage,
                         picture: StoredPlaceImage?) async throws {
        let content = content(category: moreCategory, title: title, body: NotificationText.moreBody(language), id: id)
        let payload = NotificationPayload(label: NotificationText.nextPartLabel(language), name: title, line: nil,
                                          fact: place.flatMap { FactLine.text(for: $0, language: language) },
                                          credit: nil)
        try await add(content, payload: payload, picture: picture, language: language, identifier: "\(id)-more")
    }

    /// Delivers a stop story: its title and text, the story id as request identifier, no picture. `quiet` leaves out
    /// the sound (another story is playing). Used when the Live Activity cannot show it.
    static func postStop(_ story: WalkStory, quiet: Bool, language: StoryLanguage) async throws {
        let level1 = story.levels.first ?? ""
        let content = content(category: stopCategory, title: story.title, body: level1, id: story.id)
        if quiet { content.sound = nil }
        let payload = NotificationPayload(label: NotificationText.stoppedLabel(language), name: story.title, line: nil,
                                          fact: NotificationText.stopExcerpt(level1), credit: nil)
        try await add(content, payload: payload, picture: nil, language: language, identifier: story.id.uuidString)
    }

    /// Says a story could not be told; `body` is the reason in the story language (`FailureCategory`).
    static func postFailure(id: UUID, body: String, language: StoryLanguage) async throws {
        let content = content(category: failedCategory, title: NotificationText.failedTitle(language), body: body, id: id)
        try await add(content, identifier: "\(id)-failed")
    }

    /// Says walking mode turned itself off. A plain notification: no category, so `stop()` leaves it in place.
    static func postAutoOff(_ message: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "MyGuide"
        content.body = message
        content.sound = .default
        try await add(content, identifier: "auto-off-\(UUID().uuidString)")
    }

    /// The notification settings as the walk log's `notified` line carries them (spec 9.5): `add` succeeds even when
    /// iOS will show nothing, so this is the only way to see why a buzz never appeared.
    static func settingsSnapshot() async -> NotificationSettingsSnapshot {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationSettingsSnapshot(
            authorization: name(of: settings.authorizationStatus),
            alert: name(of: settings.alertSetting),
            sound: name(of: settings.soundSetting),
            lockScreen: name(of: settings.lockScreenSetting),
            notificationCenter: name(of: settings.notificationCenterSetting),
            timeSensitive: name(of: settings.timeSensitiveSetting))
    }

    private static func name(of status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }

    private static func name(of setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: "notSupported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown"
        }
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

    /// Adds the request with `payload` in its `userInfo` and the picture attached, its credit in the payload. iOS checks
    /// the picture only when the request is added: when that fails with a picture attached, the notification is added
    /// once more without it (spec 7.3: a picture never costs the notification).
    private static func add(_ content: UNMutableNotificationContent, payload: NotificationPayload,
                            picture: StoredPlaceImage?, language: StoryLanguage, identifier: String) async throws {
        var payload = payload
        if let picture, let attachment = attachment(for: picture) {
            content.attachments = [attachment]
            payload.credit = NotificationText.photoCredit(author: picture.info.author, licence: picture.info.licence,
                                                          language)
        }
        content.userInfo[NotificationPayload.userInfoKey] = payload.encoded()
        do {
            try await add(content, identifier: identifier)
        } catch where !content.attachments.isEmpty {
            AppServices.logMemoryFailure("notification with picture refused, adding it without", error)
            content.attachments = []
            payload.credit = nil
            content.userInfo[NotificationPayload.userInfoKey] = payload.encoded()
            try await add(content, identifier: identifier)
        }
    }

    /// An attachment holding a copy of the picture; nil when it cannot be attached (the notification then goes
    /// without one). A copy, because the attachment moves its file into the notification store: the cache keeps its
    /// own. The cache names every file `.jpg` whatever it holds, so the copy is named and typed by its bytes.
    private static func attachment(for picture: StoredPlaceImage) -> UNNotificationAttachment? {
        guard let format = PlaceImageFormat(contentsOf: picture.fileURL) else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-picture-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
        do {
            try FileManager.default.copyItem(at: picture.fileURL, to: copy)
            let attachment = try UNNotificationAttachment(
                identifier: "picture", url: copy,
                options: [UNNotificationAttachmentOptionsTypeHintKey: format.typeIdentifier,
                          UNNotificationAttachmentOptionsThumbnailHiddenKey: false])
            return attachment
        } catch {
            try? FileManager.default.removeItem(at: copy)
            AppServices.logMemoryFailure("notification picture not attached", error)
            return nil
        }
    }

    private static func add(_ content: UNNotificationContent, identifier: String) async throws {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // A refused request leaves its picture copy in the temporary directory otherwise.
            for attachment in content.attachments where attachment.url.isFileURL {
                try? FileManager.default.removeItem(at: attachment.url)
            }
            throw error
        }
    }
}
