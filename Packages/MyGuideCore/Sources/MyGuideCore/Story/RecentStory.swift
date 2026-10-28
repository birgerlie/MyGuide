import Foundation

/// A story level told lately, listed to the model so it does not repeat itself on a walk back and forth.
public struct RecentStory: Sendable, Equatable {
    /// `StoryRecord.createdAt`.
    public var toldAt: Date
    /// The capture's subject or the buzz's place name; nil for stop stories.
    public var placeName: String?
    public var level: StoryLevel
    public var text: String
    /// A buzz story's level 1, written but not heard yet.
    public var prepared: Bool

    public init(toldAt: Date, placeName: String?, level: StoryLevel, text: String, prepared: Bool) {
        self.toldAt = toldAt
        self.placeName = placeName
        self.level = level
        self.text = text
        self.prepared = prepared
    }
}

/// Looks up the stories told since `since`, leaving out the story session `excludingSession`.
public typealias RecentStoryLookup = @Sendable (_ since: Date, _ excludingSession: UUID?) async -> [RecentStory]

public enum RecentStories {
    /// How far back "told lately" reaches.
    public static let window: TimeInterval = 3 * 3600
    /// The most recent stories listed.
    public static let limit = 10
    /// The most characters kept of a story's first sentence.
    public static let sentenceLimit = 160

    /// Up to and including the first ". ", "! " or "? " (or the whole text), then `TextTrim.truncate` to `sentenceLimit`.
    /// Only punctuation followed by whitespace ends a sentence, so abbreviations such as "St. Olav" cut early.
    /// Whitespace is trimmed and every run of it (newlines included) becomes one space first, so the result is one line.
    public static func firstSentence(_ story: String) -> String {
        let text = story.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next < text.endIndex, text[next].isWhitespace {
                end = next
                break
            }
            index = next
        }
        return TextTrim.truncate(String(text[..<end]), maxCharacters: sentenceLimit)
    }

    /// `- 11:58 Akershus Fortress level 1: "…"`; `this spot` stands for a missing name, ` (prepared)` ends a prepared story.
    /// A `"` inside the sentence becomes `'` so the quote stays unambiguous.
    public static func line(_ story: RecentStory, timeZone: TimeZone) -> String {
        let name = story.placeName ?? "this spot"
        let tail = story.prepared ? " (prepared)" : ""
        return "- \(GuideText.clock(story.toldAt, timeZone: timeZone)) \(name) level \(story.level.rawValue): "
            + "\"\(firstSentence(story.text).replacingOccurrences(of: "\"", with: "'"))\"\(tail)"
    }

    /// Priors whose (level, text) is not among `recent`, so a story is not listed twice.
    public static func priorsNotRecent(_ priors: [PriorStory], recent: [RecentStory]) -> [PriorStory] {
        priors.filter { prior in
            !recent.contains { $0.level == prior.level && $0.text == prior.text }
        }
    }
}
