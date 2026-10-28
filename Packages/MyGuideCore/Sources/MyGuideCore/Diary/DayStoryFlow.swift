import Foundation

public enum DayStoryError: Error, Equatable {
    /// The day has no photo that could be sent.
    case noPhotos
}

/// One day's photos and events in, a caption per photo and a summary out (spec 5.2): one request per day.
public struct DayStoryFlow: Sendable {
    /// Long side of each uploaded photo, in pixels.
    public static let uploadLongSide = 768
    static let jpegQuality = 0.7
    static let imageDetail = "low"

    private let openAI: OpenAIClient
    private let models: OpenAIModels
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let photoData: @Sendable (String) async -> Data?

    /// `photoData` returns the full JPEG for a photo id, or nil when it cannot be loaded (the photo is then skipped).
    /// `timeZone` is the one the request's date and clock times are written in.
    public init(openAI: OpenAIClient, models: OpenAIModels = .current, timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = Date.init,
                photoData: @escaping @Sendable (String) async -> Data?) {
        self.openAI = openAI
        self.models = models
        self.timeZone = timeZone
        self.now = now
        self.photoData = photoData
    }

    /// Writes the day's story. Photos over the cap, without data or that fail to downscale are not sent; they count
    /// only in `totalPhotos`. Throws `DayStoryError.noPhotos` when no photo can be sent, before any request.
    public func write(day: DiaryDay, language: StoryLanguage) async throws -> (DayStory, [UsageEntry]) {
        let plan = DayStoryPlan.make(day: day)
        // The user message, the attached images and the decoder's ids must all come from the same photo list, or
        // `p2` would name one photo while the second image shows another.
        var sent = plan
        sent.photos = []
        var images: [Data] = []
        for photo in plan.photos {
            guard let data = await photoData(photo.id),
                  let upload = try? ImageProcessing.downscaledJPEG(data, maxLongSide: Self.uploadLongSide,
                                                                   quality: Self.jpegQuality)
            else { continue }
            sent.photos.append(photo)
            images.append(upload)
        }
        guard !sent.photos.isEmpty else { throw DayStoryError.noPhotos }
        // Loading can take a while; a cancelled write must not start a paid request.
        try Task.checkCancellation()

        let (json, usage) = try await openAI.respond(
            model: models.story,
            reasoningEffort: models.storyReasoningEffort,
            instructions: PromptBuilder.dayStoryInstructions,
            text: PromptBuilder.dayStoryInput(plan: sent, day: day, language: language, timeZone: timeZone),
            images: images,
            imageDetail: Self.imageDetail,
            schemaName: "day_story",
            schema: PromptBuilder.dayStorySchema,
            promptCacheKey: PromptBuilder.dayPromptCacheKey)
        let photoIDs = sent.photos.map(\.id)
        let decoded = try PromptBuilder.decodeDayStory(json, photoIDs: photoIDs)

        let at = now()
        let story = DayStory(dayKey: day.id, createdAt: at, language: language, summary: decoded.summary,
                             captions: decoded.captions, photoIDs: photoIDs, totalPhotos: plan.totalPhotos)
        let entry = UsageEntry(date: at, kind: .story, model: models.story,
                               inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, words: 0, images: 0)
        return (story, [entry])
    }
}
