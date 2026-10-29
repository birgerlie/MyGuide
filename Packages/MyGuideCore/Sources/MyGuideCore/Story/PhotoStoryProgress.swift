import Foundation

/// The steps the story screen shows while a photo story is being found and told (spec 6, 14.10), in order.
public enum PhotoStoryProgress: Sendable, Equatable {
    /// "Finner stedet …" / "Finding the place …": reported at once.
    case finding
    /// The likely place, from a fresh nearby list: the first ranked candidate in view and at most
    /// `PhotoStoryFlow.guessDistance` away. Skipped when there is none.
    case guess(RankedCandidate)
    /// "Skriver fortellingen …" / "Writing the story …": the model request starts.
    case writing
    /// What has streamed in so far; display only, the final story replaces it. `matchedCandidateID` is nil unless it
    /// is one of the candidates sent, and "certain" shows only together with such an id (otherwise "likely"), so a
    /// "certain" never appears and then drops.
    case partial(PartialFirstStory)
}

/// How long the steps of one photo story took, in milliseconds on the flow's clock (spec 10). No story text, no photo.
public struct PhotoStoryTimings: Sendable, Equatable, Codable {
    /// Start of the story flow (just after the photo is taken or picked, once it is in memory) to the first feedback
    /// step. The camera's own capture time is not included.
    public var feedbackMs: Int
    /// Start of the story flow to the likely-place card; nil when there was none.
    public var guessMs: Int?
    /// Start to the end of the fresh place search; nil when there was none, or it had not ended when the story did.
    public var placeSearchMs: Int?
    /// The article text step; nil when the top candidate has no article title.
    public var articleMs: Int?
    /// Model request start to the first story characters; nil when none streamed before completion.
    public var firstTextMs: Int?
    /// Model request start to completion.
    public var modelMs: Int
    /// Whether the nearby list was fresh, so its candidates were sent without waiting for the fresh search.
    public var listFresh: Bool
    /// The nearby list's age in whole seconds; nil when there was no list (in the story's language).
    public var listAgeS: Int?
    /// Characters of article text sent; 0 when none was sent.
    public var articleChars: Int
    /// The first level's speech request, from its start to the audio file being ready; nil when speech was not
    /// requested (reading aloud off, or the screen was left), failed or was stopped. Set by the app after the flow;
    /// absent in lines written before it existed, which read as nil.
    public var speechMs: Int?

    public init(feedbackMs: Int, guessMs: Int?, placeSearchMs: Int?, articleMs: Int?, firstTextMs: Int?, modelMs: Int,
                listFresh: Bool, listAgeS: Int?, articleChars: Int, speechMs: Int? = nil) {
        self.feedbackMs = feedbackMs
        self.guessMs = guessMs
        self.placeSearchMs = placeSearchMs
        self.articleMs = articleMs
        self.firstTextMs = firstTextMs
        self.modelMs = modelMs
        self.listFresh = listFresh
        self.listAgeS = listAgeS
        self.articleChars = articleChars
        self.speechMs = speechMs
    }
}

/// A finished first story with what it cost and how long it took.
public struct PhotoStoryOutcome: Sendable {
    public var session: StorySession
    public var usage: [UsageEntry]
    public var timings: PhotoStoryTimings
    /// The fresh search's places for "Prøv igjen med flere steder" / "Try again with more places" (never retried
    /// automatically). Returns nil at once unless the story came from a fresh list and the model was "unsure"; then it
    /// waits for the fresh search, which the outcome does not, and returns its places when it found a candidate in
    /// view that was not sent, else nil. Cancelling the caller cancels only that search.
    public var freshCandidates: @Sendable () async -> Grounding?

    public init(session: StorySession, usage: [UsageEntry], timings: PhotoStoryTimings,
                freshCandidates: @escaping @Sendable () async -> Grounding?) {
        self.session = session
        self.usage = usage
        self.timings = timings
        self.freshCandidates = freshCandidates
    }
}
