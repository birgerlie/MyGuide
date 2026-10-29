import Foundation

/// What the expanded walking notification shows (spec 7.4, 12.9), carried in `userInfo[userInfoKey]` as JSON `Data`.
/// Shared by the app, which writes it, and the extensions, which read it; it must not use MyGuideCore. Every text is
/// already in the story language.
struct NotificationPayload: Codable, Equatable {
    /// The card's label before uppercasing: "Sted i nærheten" (BUZZ), "Neste del" (MORE), "Her du stoppet" (STOP).
    var label: String
    /// The place name, or the stop story's title.
    var name: String
    /// Distance and direction, such as "50 m foran deg"; nil when there is none to show (STOP, MORE).
    var line: String?
    /// The factual line (`FactLine`), or the stop story's first two lines for STOP; nil when there is none.
    var fact: String?
    /// "Foto: <author>, <licence>, Wikimedia Commons" for the attached picture; nil without one.
    var credit: String?

    static let userInfoKey = "payload"

    /// JSON. Encoding plain strings cannot fail; an empty `Data` would only decode to nil.
    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// The payload in `userInfo`, nil when it is missing or unreadable (a notification from before payloads, or
    /// one of another category).
    static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationPayload? {
        guard let data = userInfo[userInfoKey] as? Data else { return nil }
        return try? JSONDecoder().decode(NotificationPayload.self, from: data)
    }
}
