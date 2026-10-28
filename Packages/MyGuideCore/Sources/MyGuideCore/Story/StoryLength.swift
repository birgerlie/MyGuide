import Foundation

/// What triggered a story; decides how long the first level is.
public enum StoryKind: String, Sendable, Codable { case photo, buzz, stop }

/// How long a story should be, in words and talking points. Spoken at about 150 words per minute.
public struct StoryLength: Sendable, Equatable {
    public var words: Int
    /// How many separate points the story makes, e.g. "2–3".
    public var points: String

    public init(words: Int, points: String) {
        self.words = words
        self.points = points
    }

    /// First level of an unprompted buzz scales with the place's tier; a stop is capped at 50 words;
    /// everything the listener asks for is 200 words, then 300.
    public static func of(kind: StoryKind, level: StoryLevel, tier: PlaceTier?) -> StoryLength {
        switch level {
        case .more: return StoryLength(words: 200, points: "3–4")
        case .evenMore: return StoryLength(words: 300, points: "as many as the facts carry")
        case .first:
            let buzzWords: Int
            switch tier {
            case .top: buzzWords = 75
            case .good: buzzWords = 60
            case .wikiOnly, nil: buzzWords = 40
            }
            switch kind {
            case .photo: return StoryLength(words: 200, points: "3–4")
            case .buzz: return StoryLength(words: buzzWords, points: "2–3")
            case .stop: return StoryLength(words: min(buzzWords, 50), points: "2–3")
            }
        }
    }

    /// `words` · 60 / 150, rounded down.
    public var seconds: Int { words * 60 / 150 }

    public var line: String {
        let spoken: String
        if seconds >= 60 && seconds % 60 == 0 {
            spoken = seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
        } else {
            spoken = "\(seconds) seconds"
        }
        let pointsText = points.first?.isNumber == true ? "\(points) points" : points
        return "Length: about \(words) words (\(spoken) spoken), \(pointsText)"
    }
}
