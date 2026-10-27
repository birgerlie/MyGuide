import Foundation

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
    private let now: @Sendable () -> Date

    public init(grounding: GroundingService, openAI: OpenAIClient, models: OpenAIModels = .current,
                priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.grounding = grounding
        self.openAI = openAI
        self.models = models
        self.priors = priors
        self.now = now
    }

    public func tellFirstStory(photoJPEG: Data, capture: CaptureContext,
                               language: StoryLanguage) async throws -> (StorySession, [UsageEntry]) {
        guard let coordinate = capture.coordinate else { throw PhotoStoryError.noPosition }

        let upload = try ImageProcessing.downscaledJPEG(photoJPEG, maxLongSide: Self.uploadLongSide, quality: Self.jpegQuality)
        let thumbnail = try ImageProcessing.downscaledJPEG(photoJPEG, maxLongSide: Self.thumbnailLongSide, quality: Self.jpegQuality)

        let found = try await grounding.ground(capture, language: language)
        let told = await priors(found.candidates.map(\.candidate.id), coordinate, nil)

        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions(language: language),
            text: PromptBuilder.firstStoryInput(capture: capture, grounding: found, priors: told),
            imageJPEG: upload,
            schemaName: "first_story",
            schema: PromptBuilder.firstStorySchema)
        let identified = try PromptBuilder.decodeFirstStory(json, grounding: found)
        // An empty story must never reach the user.
        guard !identified.story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.malformedResponse
        }

        let session = StorySession(id: UUID(), capture: capture, photoJPEG: upload, thumbnailJPEG: thumbnail,
                                   language: language, grounding: found, identified: identified,
                                   levels: [identified.story])
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (session, [entry])
    }

    /// Adds the next level (spec 8.1.6). Text only: the photo is not sent again.
    public func continueStory(_ session: StorySession) async throws -> (StorySession, [UsageEntry]) {
        guard let level = session.nextLevel else { throw PhotoStoryError.noFurtherLevel }

        // Sessions always carry a coordinate (tellFirstStory requires one); without it, skip the lookup.
        var told: [PriorStory] = []
        if let coordinate = session.capture.coordinate {
            let ids = (PromptBuilder.factCandidates(for: session)).map(\.candidate.id)
            told = await priors(ids, coordinate, session.id)
        }

        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.systemInstructions(language: session.language),
            text: PromptBuilder.continuationInput(session: session, level: level, priors: told),
            imageJPEG: nil,
            schemaName: "continuation",
            schema: PromptBuilder.continuationSchema)
        let story = try PromptBuilder.decodeContinuation(json)

        var next = session
        next.levels.append(story)
        let entry = UsageEntry(date: now(), kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (next, [entry])
    }

    /// Generates the labelled "then" reconstruction as PNG bytes (spec 8.1.7). The label is drawn by the view.
    public func thenImage(for session: StorySession) async throws -> (Data, UsageEntry) {
        let png = try await openAI.image(model: models.image, prompt: PromptBuilder.thenImagePrompt(session: session),
                                         size: ThenImage.size, quality: ThenImage.quality)
        let entry = UsageEntry(date: now(), kind: .image, model: models.image,
                               inputTokens: 0, outputTokens: 0, words: 0, images: 1)
        return (png, entry)
    }
}

/// Constants of the "then" image (spec 5: every generated image is clearly labelled as an AI reconstruction).
public enum ThenImage {
    /// Drawn on top of the image wherever it is shown; never optional.
    public static let label = "AI reconstruction — not a real photo"
    public static let size = "1024x1536"
    public static let quality = "medium"
}
