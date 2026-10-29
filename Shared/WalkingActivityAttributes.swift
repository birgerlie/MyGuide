import ActivityKit
import Foundation

/// The Live Activity shown while walking mode runs. Shared by the app, which starts and updates it,
/// and the widget extension, which draws it. The app computes every text; the widget only displays (spec 7.5).
struct WalkingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The walking status («Gåmodus» / «Walking», or the paused text), or a stop story's title.
        var headline: String
        /// The waiting text before the first place, or a stop story's text.
        var body: String
        var updatedAt: Date
        /// The stop story the activity shows; nil while it only reports that the owner is walking.
        var storyID: UUID?
        /// The latest buzzed or playing place and its factual line (`FactLine`); nil before the first one and while a
        /// stop story is on show. Optional, so the state of an activity started by an older build still decodes.
        var placeName: String?
        var placeFact: String?
    }

    var startedAt: Date
    /// The iPhone's screen language when the activity started (`UILanguage`), "nb" or "en"; picks the paused texts.
    var language: String = "en"

    var isNorwegian: Bool { language == "nb" }

    /// Shown instead of the content once the activity is stale: the app stopped updating it (it was ended, or has had
    /// no usable fix for a while), so it must not claim walking mode is running. The app also uses the headline while
    /// walking mode is paused.
    static func pausedHeadline(norwegian: Bool) -> String { norwegian ? "Gåmodus satt på pause" : "Walking paused" }
    static func pausedBody(norwegian: Bool) -> String { norwegian ? "Åpne MyGuide" : "Open MyGuide" }

    /// `myguide://walk/<id>`: opens the walk story with that id. The widget extension does not link MyGuideCore, so
    /// this is a one-line mirror of `WalkLink.url(for:)`; `WalkLinkTests` pins the format, and the app parses with
    /// `WalkLink.storyID(from:)`.
    static func storyURL(_ id: UUID) -> URL {
        URL(string: "myguide://walk/\(id.uuidString)")!
    }
}

extension WalkingActivityAttributes {
    /// An activity started by a build before `language` existed has none: it decodes as English. Declared in an
    /// extension, so the memberwise initialiser stays.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
    }
}
