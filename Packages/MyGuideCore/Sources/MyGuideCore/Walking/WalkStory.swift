import Foundation

/// A story told while walking (design 7.5–7.6): about a buzzed place, or about the spot where the walker stopped.
public struct WalkStory: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case buzz, stop }

    public var id: UUID
    public var kind: Kind
    /// The buzzed place; nil for `.stop`.
    public var place: Candidate?
    /// Where the walker was when the story was made.
    public var position: Coordinate
    /// Walking direction (`WalkContext.bearing`) in degrees clockwise from north; nil when unknown.
    public var course: Double?
    public var language: StoryLanguage
    public var title: String
    /// Story texts told so far; `levels[0]` is level 1.
    public var levels: [String]
    public var createdAt: Date
    /// The walker's address when the story was made (`WalkContext.address`); nil when the lookup failed, or when it
    /// was never looked up (`addressLookedUp`).
    public var address: Address?
    /// False for a story saved before every walk story looked up an address (a buzz story from before the guide
    /// voice): its position is unknown, not a failed lookup.
    public var addressLookedUp: Bool
    /// The buzz direction line, such as "50 m left" (`Buzz.detail`); nil for `.stop`.
    public var detail: String?
    /// The Apple Maps places found for the first level, reused by "More"; nil when not searched or the search failed.
    /// In memory only.
    public var applePlaces: [ApplePlace]?

    public init(id: UUID, kind: Kind, place: Candidate?, position: Coordinate, course: Double?, language: StoryLanguage,
                title: String, levels: [String], createdAt: Date, address: Address? = nil, addressLookedUp: Bool = true,
                detail: String? = nil, applePlaces: [ApplePlace]? = nil) {
        self.id = id
        self.kind = kind
        self.place = place
        self.position = position
        self.course = course
        self.language = language
        self.title = title
        self.levels = levels
        self.createdAt = createdAt
        self.address = address
        self.addressLookedUp = addressLookedUp
        self.detail = detail
        self.applePlaces = applePlaces
    }

    public var nextLevel: StoryLevel? { StoryLevel(rawValue: levels.count + 1) }

    /// Only a buzz story can be skipped: a skip retires its place. A stop story has no place to retire.
    public var canSkip: Bool { kind == .buzz }
}
