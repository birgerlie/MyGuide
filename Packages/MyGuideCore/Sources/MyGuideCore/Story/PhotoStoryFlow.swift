import Foundation
import Synchronization

/// Looks up stories already told near a place so new ones take a new angle.
/// `excludingSession` leaves out the session being continued.
public typealias PriorStoryLookup = @Sendable (_ placeIDs: [String], _ near: Coordinate, _ excludingSession: UUID?) async -> [PriorStory]

public enum PhotoStoryError: Error, Equatable {
    /// The capture has no coordinate; the caller offers to use the current position (spec 8.1.1).
    case noPosition
    case noFurtherLevel
}

/// Photo plus capture context in, first-level story out (spec 8.1.1–5).
public struct PhotoStoryFlow: Sendable {
    static let uploadLongSide = 1536
    static let thumbnailLongSide = 400
    static let jpegQuality = 0.7

    private let grounding: GroundingService
    private let openAI: OpenAIClient
    private let models: OpenAIModels
    private let priors: PriorStoryLookup
    private let recent: RecentStoryLookup
    private let pointsOfInterest: PointsOfInterestSearching?
    private let articles: ArticleTextSource?
    private let timeZone: TimeZone
    private let storyDeadline: Duration
    private let now: @Sendable () -> Date

    /// `pointsOfInterest` and `articles` are supplementary: without them (or when they fail) the story is told without
    /// Apple Maps places or the fuller Wikipedia text. `timeZone` is the one the request's `Time:` is written in.
    /// `storyDeadline` bounds a streamed story from request to completion. `now` is the clock of the dates and timings.
    public init(grounding: GroundingService, openAI: OpenAIClient, models: OpenAIModels = .current,
                priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                recent: @escaping RecentStoryLookup = { _, _ in [] },
                pointsOfInterest: PointsOfInterestSearching? = nil, articles: ArticleTextSource? = nil,
                timeZone: TimeZone = .current,
                storyDeadline: Duration = PhotoStoryFlow.defaultStoryDeadline,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.grounding = grounding
        self.openAI = openAI
        self.models = models
        self.priors = priors
        self.recent = recent
        self.pointsOfInterest = pointsOfInterest
        self.articles = articles
        self.timeZone = timeZone
        self.storyDeadline = storyDeadline
        self.now = now
    }

    public func tellFirstStory(photoJPEG: Data, capture: CaptureContext,
                               language: StoryLanguage) async throws -> (StorySession, [UsageEntry]) {
        guard let coordinate = capture.coordinate else { throw PhotoStoryError.noPosition }

        let (upload, thumbnail) = try Self.downscaled(photoJPEG)

        // The Apple Maps search runs alongside the grounding; it fails silently and never throws but for cancellation.
        async let applePlaces = ApplePlaces.fetch(pointsOfInterest, around: coordinate, radius: ApplePlaces.photoRadius)
        var found = try await grounding.ground(capture, language: language)
        found.applePlaces = try await applePlaces

        let told = await toldBefore(found, at: coordinate)

        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions,
            text: PromptBuilder.photoFirstInput(capture: capture, grounding: found, recent: told.recent, priors: told.priors,
                                                language: language, now: told.at, timeZone: timeZone),
            imageJPEG: upload,
            schemaName: "first_story",
            schema: PromptBuilder.firstStorySchema,
            promptCacheKey: PromptBuilder.promptCacheKey)
        let (session, entry) = try firstStory(json: json, usage: usage, grounding: found, capture: capture,
                                              language: language, upload: upload, thumbnail: thumbnail)
        return (session, [entry])
    }

    /// The upload and thumbnail versions of the photo.
    static func downscaled(_ photoJPEG: Data) throws -> (upload: Data, thumbnail: Data) {
        (try ImageProcessing.downscaledJPEG(photoJPEG, maxLongSide: uploadLongSide, quality: jpegQuality),
         try ImageProcessing.downscaledJPEG(photoJPEG, maxLongSide: thumbnailLongSide, quality: jpegQuality))
    }

    /// The request time, and the stories told near `found`'s places and lately, for a first story.
    private func toldBefore(_ found: Grounding, at coordinate: Coordinate)
        async -> (at: Date, priors: [PriorStory], recent: [RecentStory]) {
        let at = now()
        let told = await priors(found.candidates.map(\.candidate.id), coordinate, nil)
        let lately = await recent(at - RecentStories.window, nil)
        return (at, told, lately)
    }

    /// The session and usage entry of a first story from the model's final JSON. The JSON is decoded and checked
    /// (an invented id dropped, "certain" on it downgraded); an empty story is malformed and must never reach the user.
    private func firstStory(json: Data, usage: TokenUsage, grounding found: Grounding, capture: CaptureContext,
                            language: StoryLanguage, upload: Data, thumbnail: Data) throws -> (StorySession, UsageEntry) {
        let identified = try PromptBuilder.decodeFirstStory(json, grounding: found)
        guard !identified.story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.malformedResponse
        }
        let session = StorySession(id: UUID(), capture: capture, photoJPEG: upload, thumbnailJPEG: thumbnail,
                                   language: language, grounding: found, identified: identified,
                                   levels: [identified.story])
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (session, entry)
    }

    /// Adds the next level (spec 8.1.6). Text only: the photo is not sent again; the first level's Apple Maps places are reused.
    public func continueStory(_ session: StorySession) async throws -> (StorySession, [UsageEntry]) {
        guard let level = session.nextLevel else { throw PhotoStoryError.noFurtherLevel }

        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions,
            text: await continuationInput(session, level: level),
            imageJPEG: nil,
            schemaName: "continuation",
            schema: PromptBuilder.continuationSchema,
            promptCacheKey: PromptBuilder.promptCacheKey)
        return try continued(session, json: json, usage: usage)
    }

    /// The request text of the next level: the matched place's fuller article text, fetched while the memory lookups run.
    private func continuationInput(_ session: StorySession, level: StoryLevel) async -> String {
        let title = session.matchedCandidate?.candidate.wikipediaTitle
        async let articleText: String? = fetchArticle(title)

        // Sessions always carry a coordinate (tellFirstStory requires one); without it, skip the lookup.
        var told: [PriorStory] = []
        if let coordinate = session.capture.coordinate {
            let ids = PromptBuilder.factCandidates(for: session).map(\.candidate.id)
            told = await priors(ids, coordinate, session.id)
        }
        let at = now()
        let lately = await recent(at - RecentStories.window, session.id)
        return PromptBuilder.photoContinuationInput(session: session, level: level, articleText: await articleText,
                                                    recent: lately, priors: told, now: at, timeZone: timeZone)
    }

    /// The session with the decoded level appended, and its usage entry.
    private func continued(_ session: StorySession, json: Data, usage: TokenUsage) throws -> (StorySession, [UsageEntry]) {
        let story = try PromptBuilder.decodeContinuation(json)
        var next = session
        next.levels.append(story)
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (next, [entry])
    }

    private func fetchArticle(_ title: String?) async -> String? {
        guard let title, let articles else { return nil }
        return await articles.text(wikipediaTitle: title)
    }

    /// Generates the labelled "then" reconstruction as PNG bytes (spec 8.1.7). The label is drawn by the view.
    public func thenImage(for session: StorySession) async throws -> (Data, UsageEntry) {
        let (png, tokens) = try await openAI.image(model: models.image, prompt: PromptBuilder.thenImagePrompt(session: session),
                                         size: ThenImage.size, quality: ThenImage.quality)
        let entry = UsageEntry(date: now(), kind: .image, model: models.image,
                               inputTokens: tokens?.inputTokens ?? 0, outputTokens: tokens?.outputTokens ?? 0,
                               words: 0, images: 1)
        return (png, entry)
    }
}

// MARK: - Streaming (spec 6, 7.1, 8, 10)

extension PhotoStoryFlow {
    /// On the fresh-list path the request waits at most this long, from the start of the searches, for the address and
    /// the Apple Maps places, then goes without whatever has not arrived (spec 14.3).
    public static let freshPathWait: Duration = .milliseconds(1500)
    /// Characters of the top candidate's article text sent with the first story (spec 15.2).
    public static let articleLimit = 1500
    /// The guess card needs a candidate in view at most this far (metres) from the photo.
    public static let guessDistance = 250.0
    /// List candidates farther than this (metres) from the photo are not sent: the fresh search's Wikipedia radius.
    public static let listCandidateRadius = Double(GroundingService.wikiRadius)
    /// A streamed story not completed within this time fails like a lost connection.
    public static let defaultStoryDeadline: Duration = .seconds(90)

    /// Tells the first story while reporting `progress`. With a fresh `nearby` list (in `language`), the list's
    /// candidates are sent at once, with the address and Apple Maps places that arrive within `freshPathWait`; otherwise
    /// the request waits for the fresh place search, as `tellFirstStory` does. Either way the top candidate's article
    /// text goes with it, cut to `articleLimit` characters.
    /// A stream that breaks, or does not complete within the story deadline, throws: no session is made, whatever
    /// partial text was reported.
    public func tellFirstStoryStreaming(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage, nearby: NearbyList?,
                                        progress: @escaping @Sendable (PhotoStoryProgress) -> Void) async throws -> PhotoStoryOutcome {
        try await streamFirstStory(photoJPEG: photoJPEG, capture: capture, language: language,
                                   places: .search(nearby?.language == language ? nearby : nil), progress: progress)
    }

    /// "Prøv igjen med flere steder" / "Try again with more places": the first story told from `grounding` (an earlier
    /// outcome's `freshCandidates`), with no list and no new search.
    public func tellFirstStoryStreaming(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage, grounding: Grounding,
                                        progress: @escaping @Sendable (PhotoStoryProgress) -> Void) async throws -> PhotoStoryOutcome {
        try await streamFirstStory(photoJPEG: photoJPEG, capture: capture, language: language,
                                   places: .given(grounding), progress: progress)
    }

    /// As `continueStory`, streamed: `onText` gets the level's text so far each time it grows (never empty).
    /// The returned level is the final decoded text; a broken or late stream throws and adds nothing.
    public func continueStoryStreaming(_ session: StorySession, onText: @escaping @Sendable (String) -> Void)
        async throws -> (StorySession, [UsageEntry]) {
        guard let level = session.nextLevel else { throw PhotoStoryError.noFurtherLevel }
        let (json, usage) = try await streamStory(text: await continuationInput(session, level: level), imageJPEG: nil,
                                                  schemaName: "continuation", schema: PromptBuilder.continuationSchema) { partial in
            if let story = partial.story, !story.isEmpty { onText(story) }
        }
        return try continued(session, json: json, usage: usage)
    }

    // MARK: Places

    private enum PlaceSource {
        /// Search, with the nearby list when there is one in the story's language.
        case search(NearbyList?)
        /// Use these places; no list, no search.
        case given(Grounding)
    }

    /// The lookups started at the shutter. The address task is shared: the fresh search waits for it in full, the
    /// fresh-list path only for `freshPathWait`.
    private struct Searches: Sendable {
        let address: Task<Address?, Error>
        let applePlaces: Task<[ApplePlace]?, Error>
        let places: Task<Grounding, Error>
        /// When the fresh search finished, on the flow's clock; nil while it runs.
        let placesFinishedAt: Latch<Date>
        /// The end of the fresh-list path's wait for the address and Apple Maps places.
        let waitEnds: ContinuousClock.Instant

        func cancel() {
            address.cancel()
            applePlaces.cancel()
            places.cancel()
        }
    }

    private func startSearches(_ capture: CaptureContext, at coordinate: Coordinate, language: StoryLanguage) -> Searches {
        let grounding = self.grounding
        let pointsOfInterest = self.pointsOfInterest
        let now = self.now
        let waitEnds = ContinuousClock.now + Self.freshPathWait
        let finished = Latch<Date>()
        let address = Task { try await grounding.address(for: coordinate) }
        let applePlaces = Task {
            // Fails silently (nil) and never throws but for cancellation.
            try await ApplePlaces.fetch(pointsOfInterest, around: coordinate, radius: ApplePlaces.photoRadius)
        }
        let places = Task {
            let found = try await grounding.ground(capture, language: language, address: { try await address.value })
            finished.set(now())
            return found
        }
        return Searches(address: address, applePlaces: applePlaces, places: places, placesFinishedAt: finished,
                        waitEnds: waitEnds)
    }

    /// The fresh search's places with the Apple Maps places, as `tellFirstStory` grounds a story.
    private static func searched(_ searches: Searches) async throws -> Grounding {
        var found = try await searches.places.value
        found.applePlaces = try await searches.applePlaces.value
        return found
    }

    /// The task's value if it arrives before `deadline`, else nil; the task itself keeps running.
    /// Only the caller's cancellation propagates.
    private static func value<T: Sendable>(of task: Task<T?, Error>, before deadline: ContinuousClock.Instant) async throws -> T? {
        let remaining = max(.zero, deadline - ContinuousClock.now)
        do {
            // Cancelling the wait (when the sleep wins) does not cancel `task`: awaiting a task's value never does.
            return try await GroundingService.withTimeout(remaining) { try await task.value }
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    // MARK: Article

    private struct ArticleStep: Sendable {
        var article: (candidate: Candidate, text: String)?
        var ms: Int?
    }

    /// The top candidate's article text, collapsed to one line and cut to `articleLimit` characters: from the list
    /// when it has it, else from `articles`, which on the fresh-list path must answer before `deadline` (the shared
    /// head-start budget) and otherwise within the source's own timeout.
    /// Nothing when the top candidate is out of view (with a usable heading every candidate has a view flag; without
    /// one it is nil and the top candidate counts), has no article title, or no text was found.
    private func articleStep(for top: RankedCandidate?, list: NearbyList?,
                             deadline: ContinuousClock.Instant? = nil) async -> ArticleStep {
        guard let top, top.inView != false,
              let title = top.candidate.wikipediaTitle, !title.isEmpty else { return ArticleStep() }
        let started = now()
        var raw = list?.articleTexts[title]
        if raw.map(GuideText.oneLine)?.isEmpty ?? true, let articles {
            let fetch: @Sendable () async throws -> String? = { await articles.text(wikipediaTitle: title) }
            if let deadline {
                raw = try? await GroundingService.withTimeout(max(.zero, deadline - ContinuousClock.now), fetch)
            } else {
                // Abandoned on cancellation: a source's shared fetch may not stop for one caller.
                raw = try? await GroundingService.abandoningOnCancel(fetch)
            }
        }
        let ms = Self.milliseconds(from: started, to: now())
        let text = String(GuideText.oneLine(raw ?? "").prefix(Self.articleLimit))
        guard !text.isEmpty else { return ArticleStep(article: nil, ms: ms) }
        return ArticleStep(article: (candidate: top.candidate, text: text), ms: ms)
    }

    // MARK: First story

    private func streamFirstStory(photoJPEG: Data, capture: CaptureContext, language: StoryLanguage, places: PlaceSource,
                                  progress: @escaping @Sendable (PhotoStoryProgress) -> Void) async throws -> PhotoStoryOutcome {
        guard let coordinate = capture.coordinate else { throw PhotoStoryError.noPosition }
        let started = now()
        progress(.finding)
        let feedbackMs = Self.milliseconds(from: started, to: now())

        let list: NearbyList?
        let searches: Searches?
        switch places {
        case .search(let nearby):
            list = nearby
            searches = startSearches(capture, at: coordinate, language: language)
        case .given:
            list = nil
            searches = nil
        }
        let listFresh = list?.isFresh(for: coordinate, now: started) ?? false

        return try await withTaskCancellationHandler {
            // The searches are only needed until the story is done, unless an "unsure" story from a fresh list hands
            // the fresh search to `freshCandidates`.
            var handedOver = false
            defer { if !handedOver { searches?.cancel() } }

            var guessMs: Int?
            let found: Grounding
            let article: ArticleStep
            let (upload, thumbnail): (Data, Data)
            if case .given(let given) = places {
                (upload, thumbnail) = try Self.downscaled(photoJPEG)
                found = given
                article = await articleStep(for: given.candidates.first, list: nil)
            } else if let searches, let list, listFresh {
                let ranked = CandidateRanker.rank(Self.withinPhotoRadius(list.candidates, of: coordinate), capture: capture)
                if let guess = ranked.first(where: { $0.inView == true && $0.distance <= Self.guessDistance }) {
                    progress(.guess(guess))
                    guessMs = Self.milliseconds(from: started, to: now())
                }
                (upload, thumbnail) = try Self.downscaled(photoJPEG)
                async let articleStep = articleStep(for: ranked.first, list: list, deadline: searches.waitEnds)
                async let address = Self.value(of: searches.address, before: searches.waitEnds)
                async let applePlaces = Self.value(of: searches.applePlaces, before: searches.waitEnds)
                let gotAddress = try await address
                found = Grounding(candidates: ranked, address: gotAddress, failedSources: gotAddress == nil ? [.geocoder] : [],
                                  applePlaces: try await applePlaces)
                article = await articleStep
            } else if let searches {
                (upload, thumbnail) = try Self.downscaled(photoJPEG)
                found = try await Self.searched(searches)
                article = await articleStep(for: found.candidates.first, list: list)
            } else {
                preconditionFailure("a search source always starts its searches")
            }
            try Task.checkCancellation()

            let told = await toldBefore(found, at: coordinate)
            let text = PromptBuilder.photoFirstInput(capture: capture, grounding: found, recent: told.recent,
                                                     priors: told.priors, language: language, now: told.at,
                                                     timeZone: timeZone, article: article.article)

            // The memory lookups do not stop for cancellation; nothing more is reported once cancelled.
            try Task.checkCancellation()
            progress(.writing)
            let modelStarted = now()
            let firstText = Latch<Date>()
            let sentIDs = Set(found.candidates.map(\.candidate.id))
            let now = self.now
            let (json, usage) = try await streamStory(text: text, imageJPEG: upload, schemaName: "first_story",
                                                      schema: PromptBuilder.firstStorySchema) { partial in
                if let story = partial.story, !story.isEmpty, firstText.value == nil { firstText.set(now()) }
                progress(.partial(Self.checked(partial, sentIDs: sentIDs)))
            }
            let modelEnded = now()

            // The final JSON is authoritative; the partials were display only.
            let (session, entry) = try firstStory(json: json, usage: usage, grounding: found, capture: capture,
                                                  language: language, upload: upload, thumbnail: thumbnail)

            var freshCandidates: @Sendable () async -> Grounding? = { nil }
            if listFresh, session.identified.confidence == .unsure, let searches {
                handedOver = true
                freshCandidates = { await Self.newInView(searches, notIn: sentIDs) }
            }

            let timings = PhotoStoryTimings(
                feedbackMs: feedbackMs,
                guessMs: guessMs,
                placeSearchMs: searches?.placesFinishedAt.value.map { Self.milliseconds(from: started, to: $0) },
                articleMs: article.ms,
                firstTextMs: firstText.value.map { Self.milliseconds(from: modelStarted, to: $0) },
                modelMs: Self.milliseconds(from: modelStarted, to: modelEnded),
                listFresh: listFresh,
                listAgeS: list.flatMap { list in
                    let age = started.timeIntervalSince(list.fetchedAt)
                    // A list dated after now (the clock was set back) has no known age.
                    return age >= 0 ? Int(age.rounded(.towardZero)) : nil
                },
                articleChars: article.article?.text.count ?? 0)
            return PhotoStoryOutcome(session: session, usage: [entry], timings: timings, freshCandidates: freshCandidates)
        } onCancel: {
            searches?.cancel()
        }
    }

    /// The list candidates that may be sent for a photo: at most `listCandidateRadius` from it, the reach of the
    /// photo's own search (spec 7.1: the list's 500 m from a centre up to 250 m away reaches much further).
    static func withinPhotoRadius(_ candidates: [Candidate], of photo: Coordinate) -> [Candidate] {
        candidates.filter { GeoMath.distance(photo, $0.coordinate) <= listCandidateRadius }
    }

    /// Waits for the fresh search (b) and returns it, with the Apple Maps places, when it found a candidate in view
    /// whose id is not in `sentIDs`; else nil. Cancelling the caller cancels (b) and nothing else, and gives nil.
    private static func newInView(_ searches: Searches, notIn sentIDs: Set<String>) async -> Grounding? {
        await withTaskCancellationHandler {
            guard let places = try? await searches.places.value, !Task.isCancelled,
                  places.candidates.contains(where: { $0.inView == true && !sentIDs.contains($0.candidate.id) })
            else { return nil }
            var fresh = places
            // Bounded by the Apple Maps timeout; a failed or cancelled search leaves the places out.
            fresh.applePlaces = try? await searches.applePlaces.value
            return fresh
        } onCancel: {
            searches.places.cancel()
        }
    }

    /// A partial identification as the screen may show it: an id that was not sent is dropped, and "certain" stands
    /// only on an id that was sent. With no id yet, the id may still arrive and be invented, so "certain" waits as
    /// "likely"; the final decoded story can raise it again, but a shown "certain" never drops.
    static func checked(_ partial: PartialFirstStory, sentIDs: Set<String>) -> PartialFirstStory {
        var checked = partial
        if let id = checked.matchedCandidateID, !sentIDs.contains(id) { checked.matchedCandidateID = nil }
        if checked.confidence == SubjectConfidence.certain.rawValue, checked.matchedCandidateID == nil {
            checked.confidence = SubjectConfidence.likely.rawValue
        }
        return checked
    }

    // MARK: Stream

    /// Streams one story request and returns the final JSON and usage. `onPartial` gets the parsed state after each
    /// delta that changed it. Fails with `OpenAIError.network` when the story is not complete within `storyDeadline`;
    /// any stream error propagates. Nothing partial is ever returned.
    private func streamStory(text: String, imageJPEG: Data?, schemaName: String, schema: JSONValue,
                             onPartial: @escaping @Sendable (PartialFirstStory) -> Void) async throws -> (json: Data, usage: TokenUsage) {
        let openAI = self.openAI
        let models = self.models
        let deadline = storyDeadline
        do {
            let result = try await GroundingService.withTimeout(deadline) { () async throws -> StreamedStory in
                let events = openAI.respondStreaming(
                    model: models.story,
                    reasoningEffort: models.storyReasoningEffort,
                    instructions: PromptBuilder.systemInstructions,
                    text: text,
                    imageJPEG: imageJPEG,
                    schemaName: schemaName,
                    schema: schema,
                    promptCacheKey: PromptBuilder.promptCacheKey)
                var parser = PartialStoryParser()
                var last = PartialFirstStory()
                for try await event in events {
                    switch event {
                    case .textDelta(let delta):
                        let partial = parser.append(delta)
                        guard partial != last else { continue }
                        last = partial
                        // After the deadline this work is abandoned; it must not report anything more.
                        try Task.checkCancellation()
                        onPartial(partial)
                    case .completed(let json, let usage):
                        return StreamedStory(json: json, usage: usage)
                    }
                }
                // respondStreaming throws when the stream ends without `response.completed`; this is the same rule.
                try Task.checkCancellation()
                throw OpenAIError.malformedResponse
            }
            return (result.json, result.usage)
        } catch is GroundingService.Timeout {
            throw OpenAIError.network("The story did not arrive within \(deadline.components.seconds) seconds.")
        }
    }

    private struct StreamedStory: Sendable {
        var json: Data
        var usage: TokenUsage
    }

    /// Whole milliseconds from `start` to `end`, rounded.
    static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}

/// A value set once, then read from any thread; later sets are ignored.
final class Latch<Value: Sendable>: Sendable {
    private let state = Mutex<Value?>(nil)

    var value: Value? { state.withLock { $0 } }

    func set(_ value: Value) {
        state.withLock { if $0 == nil { $0 = value } }
    }
}

/// Constants of the "then" image (spec 5: every generated image is clearly labelled as an AI reconstruction).
public enum ThenImage {
    /// Drawn on top of the image wherever it is shown; never optional.
    public static let label = "AI reconstruction — not a real photo"
    public static let size = "1024x1536"
    public static let quality = "medium"
}
