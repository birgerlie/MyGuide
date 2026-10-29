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

    /// The language that matches a device's preferred languages (spec 17): Norwegian when the first one is
    /// Norwegian (nb, no or nn, with or without a region), English for any other language or none. Only the first
    /// language decides. The app reads it for its screen texts and as the story language on first launch.
    public static func matching(preferredLanguages: [String]) -> StoryLanguage {
        guard let first = preferredLanguages.first,
              let code = Locale.Language(identifier: first).languageCode?.identifier.lowercased()
        else { return .english }
        return ["nb", "no", "nn"].contains(code) ? .norwegian : .english
    }

    /// The screen language (spec 17): the localization iOS picked for the app bundle when there is one ("Base" and
    /// "" are none), so the app's texts match the system's texts for it; else `matching(preferredLanguages:)`.
    public static func screen(bundleLocalization: String?, preferredLanguages: [String]) -> StoryLanguage {
        if let localization = bundleLocalization, !localization.isEmpty, localization != "Base" {
            return matching(preferredLanguages: [localization])
        }
        return matching(preferredLanguages: preferredLanguages)
    }
}

/// How deep into a place's story the listener is. Lengths: see `StoryLength`.
public enum StoryLevel: Int, Sendable, Codable, CaseIterable {
    case first = 1, more = 2, evenMore = 3

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
