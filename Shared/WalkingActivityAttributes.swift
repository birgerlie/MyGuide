import ActivityKit
import Foundation

/// The Live Activity shown while walking mode runs. Shared by the app, which starts and updates it,
/// and the widget extension, which draws it.
struct WalkingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var headline: String
        var body: String
        var updatedAt: Date
        /// The stop story the activity shows; nil while it only reports that the owner is walking.
        var storyID: UUID?
    }

    var startedAt: Date

    /// `myguide://walk/<id>`: opens the walk story with that id.
    static func storyURL(_ id: UUID) -> URL {
        URL(string: "myguide://walk/\(id.uuidString)")!
    }

    /// The story id in a `myguide://walk/<id>` link; nil for any other URL.
    static func storyID(from url: URL) -> UUID? {
        guard url.scheme == "myguide", url.host() == "walk", url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.pathComponents[1])
    }
}
