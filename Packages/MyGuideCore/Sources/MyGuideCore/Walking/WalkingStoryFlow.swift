import Foundation

/// Buzzed-place and stop stories while walking (design 7.5–7.6): text only, one OpenAI call per level.
public struct WalkingStoryFlow: Sendable {
    /// Most nearby places given to a stop story.
    public static let factLimit = 5
    /// A stop story only hears of places this close (metres).
    public static let stopFactRadius = 150.0

    private let openAI: OpenAIClient
    private let models: OpenAIModels
    private let priors: PriorStoryLookup
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(openAI: OpenAIClient, models: OpenAIModels = .current,
                priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                now: @escaping @Sendable () -> Date = Date.init, makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.openAI = openAI
        self.models = models
        self.priors = priors
        self.now = now
        self.makeID = makeID
    }

    /// The first level for a buzzed place. The story takes the buzz's id so a notification maps back to it.
    public func buzzStory(_ buzz: Buzz, position: Coordinate, course: Double?, nearby: [WalkingPlace],
                          language: StoryLanguage) async throws -> (WalkStory, [UsageEntry]) {
        let placeID = buzz.place.candidate.id
        let facts = PromptBuilder.buzzFacts(nearby, excluding: placeID, position: position)
        let told = await priors([placeID] + facts.map(\.candidate.id), position, nil)
        let (title, text, entry) = try await generate(
            language: language,
            input: PromptBuilder.walkBuzzInput(buzz: buzz, course: course, facts: facts, position: position, priors: told))
        let story = WalkStory(id: buzz.id, kind: .buzz, place: buzz.place.candidate, position: position, course: course,
                              language: language, title: title, levels: [text], createdAt: now(),
                              address: nil, detail: buzz.detail)
        return (story, [entry])
    }

    /// The first level for the spot where the walker has stopped.
    public func stopStory(position: Coordinate, address: Address?, nearby: [WalkingPlace],
                          language: StoryLanguage) async throws -> (WalkStory, [UsageEntry]) {
        let facts = PromptBuilder.stopFacts(nearby, position: position)
        let told = await priors(facts.map(\.candidate.id), position, nil)
        let (title, text, entry) = try await generate(
            language: language,
            input: PromptBuilder.walkStopInput(address: address, facts: nearby, position: position, priors: told))
        let story = WalkStory(id: makeID(), kind: .stop, place: nil, position: position, course: nil,
                              language: language, title: title, levels: [text], createdAt: now(),
                              address: address, detail: nil)
        return (story, [entry])
    }

    /// Adds the next level, up to three.
    public func continueStory(_ story: WalkStory) async throws -> (WalkStory, [UsageEntry]) {
        guard let level = story.nextLevel else { throw PhotoStoryError.noFurtherLevel }
        let ids = story.place.map { [$0.id] } ?? []
        let told = await priors(ids, story.position, story.id)
        let (_, text, entry) = try await generate(
            language: story.language,
            input: PromptBuilder.walkContinuationInput(story: story, level: level, priors: told))
        var next = story
        next.levels.append(text)
        return (next, [entry])
    }

    private func generate(language: StoryLanguage, input: String) async throws -> (String, String, UsageEntry) {
        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions(language: language),
            text: input,
            imageJPEG: nil,
            schemaName: "walk_story",
            schema: PromptBuilder.walkStorySchema)
        let decoded = try PromptBuilder.decodeWalkStory(json)
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (decoded.title, decoded.story, entry)
    }
}
