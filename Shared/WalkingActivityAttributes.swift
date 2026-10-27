import ActivityKit
import Foundation

/// The Live Activity shown while walking mode runs. Shared by the app, which starts and updates it,
/// and the widget extension, which draws it.
struct WalkingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var headline: String
        var body: String
        var updatedAt: Date
    }

    var startedAt: Date
}
