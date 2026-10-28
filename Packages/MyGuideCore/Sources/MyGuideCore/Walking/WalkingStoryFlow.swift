import Foundation

/// Buzzed-place and stop stories while walking (design 7.5–7.6): text only, one OpenAI call per level.
public struct WalkingStoryFlow: Sendable {
    /// Most nearby places given to a stop story.
    public static let factLimit = 5
    /// A stop story only hears of places this close (metres).
    public static let stopFactRadius = 150.0
    /// With nothing within `stopFactRadius`, a stop story points to a place within this distance (metres); with nothing
    /// here either, there is no stop story (spec 9).
    public static let detourRadius = 500.0
    /// Most places a stop story points to as worth the detour.
    public static let detourLimit = 2

    private let openAI: OpenAIClient
    private let models: OpenAIModels
    private let priors: PriorStoryLookup
    private let recent: RecentStoryLookup
    private let pointsOfInterest: PointsOfInterestSearching?
    private let articles: ArticleTextSource?
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    /// `pointsOfInterest` and `articles` are supplementary: without them (or when they fail) the story is told without
    /// Apple Maps places or the fuller Wikipedia text. `timeZone` is the one the request's `Time:` is written in.
    public init(openAI: OpenAIClient, models: OpenAIModels = .current,
                priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                recent: @escaping RecentStoryLookup = { _, _ in [] },
                pointsOfInterest: PointsOfInterestSearching? = nil, articles: ArticleTextSource? = nil,
                timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = Date.init, makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.openAI = openAI
        self.models = models
        self.priors = priors
        self.recent = recent
        self.pointsOfInterest = pointsOfInterest
        self.articles = articles
        self.timeZone = timeZone
        self.now = now
        self.makeID = makeID
    }

    /// The first level for a buzzed place. The story takes the buzz's id so a notification maps back to it.
    /// `context` (it may look up the address, which can take seconds) runs alongside the other fetches.
    public func buzzStory(_ buzz: Buzz, position: Coordinate, context: @escaping @Sendable () async -> WalkContext,
                          nearby: [WalkingPlace], language: StoryLanguage) async throws -> (WalkStory, [UsageEntry]) {
        let place = buzz.place.candidate
        // The walk context and the supplementary fetches run while the memory lookups do; none fails the story.
        async let walk = context()
        async let applePlaces = ApplePlaces.fetch(pointsOfInterest, around: position, radius: ApplePlaces.walkingRadius)
        async let articleText = fetchArticle(place.wikipediaTitle)
        let facts = PromptBuilder.buzzFacts(nearby, excluding: place.id, position: position)
        let told = await priors([place.id] + facts.map(\.candidate.id), position, nil)
        let at = now()
        let lately = await recent(at - RecentStories.window, nil)
        let found = try await applePlaces
        let context = await walk
        let input = PromptBuilder.walkBuzzInput(
            buzz: buzz, position: position, context: context, neighbours: facts, articleText: await articleText,
            applePlaces: found, recent: lately, priors: told, language: language, now: at, timeZone: timeZone)
        let (title, text, entry) = try await generate(input)
        let story = WalkStory(id: buzz.id, kind: .buzz, place: place, position: position, course: context.bearing,
                              language: language, title: title, levels: [text], createdAt: now(),
                              address: context.address, detail: buzz.detail, applePlaces: found)
        return (story, [entry])
    }

    /// The first level for the spot where the walker has stopped.
    /// nil: nothing within `detourRadius` — no request is made (spec 9 step 4).
    public func stopStory(position: Coordinate, context: WalkContext, nearby: [WalkingPlace],
                          language: StoryLanguage) async throws -> (WalkStory, [UsageEntry])? {
        // Decided from the places walking mode already has, before any request.
        guard let stop = PromptBuilder.walkStop(nearby, position: position) else { return nil }
        // A detour story lists no Apple Maps places, so it does not search; only a place under `Facts about` gets the
        // fuller text, and a detour's first level has none.
        let isHere = if case .here = stop { true } else { false }
        async let applePlaces = isHere
            ? ApplePlaces.fetch(pointsOfInterest, around: position, radius: ApplePlaces.walkingRadius)
            : nil
        async let articleText = fetchArticle(isHere ? stop.places.first?.candidate.wikipediaTitle : nil)
        let told = await priors(stop.places.map(\.candidate.id), position, nil)
        let at = now()
        let lately = await recent(at - RecentStories.window, nil)
        let found = try await applePlaces
        let input = PromptBuilder.walkStopInput(
            stop, position: position, context: context, articleText: await articleText, applePlaces: found,
            recent: lately, priors: told, language: language, now: at, timeZone: timeZone)
        let (title, text, entry) = try await generate(input)
        let story = WalkStory(id: makeID(), kind: .stop, place: nil, position: position, course: context.bearing,
                              language: language, title: title, levels: [text], createdAt: now(),
                              address: context.address, detail: nil, applePlaces: found)
        return (story, [entry])
    }

    /// Adds the next level, up to three. `nearby` are the places walking mode has now; a stop story runs its ladder over
    /// those around its own position again. The first level's Apple Maps places are reused, or searched again when it
    /// has none (never for a detour, which lists none, nor for a stop with no places left, which has nothing to tell).
    public func continueStory(_ story: WalkStory, nearby: [WalkingPlace]) async throws -> (WalkStory, [UsageEntry]) {
        guard let level = story.nextLevel else { throw PhotoStoryError.noFurtherLevel }
        // The places listed, decided once here so the priors lookup and the request agree. `subject` is the one
        // under `Facts about`.
        let stop: PromptBuilder.WalkStop?
        let subject: Candidate?
        let ids: [String]
        switch story.kind {
        case .buzz:
            stop = nil
            subject = story.place
            ids = subject.map { [$0.id] } ?? []
        case .stop:
            stop = PromptBuilder.walkStop(nearby, position: story.position)
            subject = stop?.places.first?.candidate
            ids = stop?.places.map(\.candidate.id) ?? []
        }
        let searchesApplePlaces = switch (story.kind, stop) {
        case (.buzz, _), (.stop, .here): true
        case (.stop, .detour), (.stop, nil): false
        }
        let stored = story.applePlaces
        async let searched: [ApplePlace]? = stored == nil && searchesApplePlaces
            ? ApplePlaces.fetch(pointsOfInterest, around: story.position, radius: ApplePlaces.walkingRadius)
            : nil
        async let articleText = fetchArticle(subject?.wikipediaTitle)
        let told = await priors(ids, story.position, story.id)
        let at = now()
        let lately = await recent(at - RecentStories.window, story.id)
        let applePlaces: [ApplePlace]?
        if let stored { applePlaces = stored } else { applePlaces = try await searched }
        let input = PromptBuilder.walkContinuationInput(
            story: story, level: level, stop: stop, articleText: await articleText, applePlaces: applePlaces,
            recent: lately, priors: told, now: at, timeZone: timeZone)
        let (_, text, entry) = try await generate(input)
        var next = story
        next.levels.append(text)
        next.applePlaces = applePlaces
        return (next, [entry])
    }

    private func fetchArticle(_ title: String?) async -> String? {
        guard let title, !title.isEmpty, let articles else { return nil }
        return await articles.text(wikipediaTitle: title)
    }

    private func generate(_ input: String) async throws -> (String, String, UsageEntry) {
        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions,
            text: input,
            imageJPEG: nil,
            schemaName: "walk_story",
            schema: PromptBuilder.walkStorySchema,
            promptCacheKey: PromptBuilder.promptCacheKey)
        let decoded = try PromptBuilder.decodeWalkStory(json)
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (decoded.title, decoded.story, entry)
    }
}
