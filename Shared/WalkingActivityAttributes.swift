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

    /// Shown instead of the content once the activity is stale: the app stopped updating it (it was ended, or has had
    /// no usable fix for a while), so it must not claim walking mode is running.
    static let pausedHeadline = "Walking paused"
    static let pausedBody = "Open MyGuide"

    /// `myguide://walk/<id>`: opens the walk story with that id. The widget extension does not link MyGuideCore, so
    /// this is a one-line mirror of `WalkLink.url(for:)`; `WalkLinkTests` pins the format, and the app parses with
    /// `WalkLink.storyID(from:)`.
    static func storyURL(_ id: UUID) -> URL {
        URL(string: "myguide://walk/\(id.uuidString)")!
    }
}
