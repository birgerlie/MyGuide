import Foundation

public enum StoryLanguage: String, Sendable, Codable, CaseIterable {
    case english = "en"
    case norwegian = "nb"

    /// Language edition code used for Wikipedia hosts.
    public var wikipediaCode: String {
        switch self {
        case .english: "en"
        case .norwegian: "no"
        }
    }

    /// Language name used in prompts.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .norwegian: "Norwegian Bokmål"
        }
    }
}

/// How deep into a place's story the listener is. Spoken at about 150 words per minute (spec 6).
public enum StoryLevel: Int, Sendable, Codable, CaseIterable {
    case first = 1, more = 2, evenMore = 3

    public var targetSeconds: Int {
        switch self {
        case .first: 20
        case .more: 30
        case .evenMore: 120
        }
    }

    /// `targetSeconds` · 150 words per minute / 60.
    public var targetWords: Int { targetSeconds * 150 / 60 }

    public var lengthPhrase: String {
        let spoken = targetSeconds >= 60 ? "\(targetSeconds / 60) minutes" : "\(targetSeconds) seconds"
        return "about \(targetWords) words (\(spoken) spoken)"
    }

    public var next: StoryLevel? { StoryLevel(rawValue: rawValue + 1) }
}

public enum SubjectConfidence: String, Sendable, Codable {
    case certain, likely, unsure
}

/// The model's reading of the photo plus the first story.
public struct IdentifiedStory: Sendable, Equatable, Codable {
    public var subject: String
    public var confidence: SubjectConfidence
    public var matchedCandidateID: String?
    public var title: String
    public var era: String
    public var story: String

    public init(subject: String, confidence: SubjectConfidence, matchedCandidateID: String?,
                title: String, era: String, story: String) {
        self.subject = subject
        self.confidence = confidence
        self.matchedCandidateID = matchedCandidateID
        self.title = title
        self.era = era
        self.story = story
    }
}

/// A story the listener has already heard, kept so new ones take a new angle.
public struct PriorStory: Sendable, Equatable {
    public var placeID: String?
    public var level: StoryLevel
    public var text: String
    public var toldAt: Date

    public init(placeID: String?, level: StoryLevel, text: String, toldAt: Date) {
        self.placeID = placeID
        self.level = level
        self.text = text
        self.toldAt = toldAt
    }
}

/// One photo's story as it is being told: the capture, what was found, and the levels told so far.
public struct StorySession: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var capture: CaptureContext
    /// The 1536 px upload version, kept as "photos taken" (spec 8.2).
    public var photoJPEG: Data
    public var thumbnailJPEG: Data
    public var language: StoryLanguage
    public var grounding: Grounding
    public var identified: IdentifiedStory
    /// Story texts told so far; `levels[0]` is level 1.
    public var levels: [String]

    public init(id: UUID, capture: CaptureContext, photoJPEG: Data, thumbnailJPEG: Data, language: StoryLanguage,
                grounding: Grounding, identified: IdentifiedStory, levels: [String]) {
        self.id = id
        self.capture = capture
        self.photoJPEG = photoJPEG
        self.thumbnailJPEG = thumbnailJPEG
        self.language = language
        self.grounding = grounding
        self.identified = identified
        self.levels = levels
    }

    public var matchedCandidate: RankedCandidate? {
        grounding.candidates.first { $0.candidate.id == identified.matchedCandidateID }
    }

    public var nextLevel: StoryLevel? { StoryLevel(rawValue: levels.count + 1) }
}
