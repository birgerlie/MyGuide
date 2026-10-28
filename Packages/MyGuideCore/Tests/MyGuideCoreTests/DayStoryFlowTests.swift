import Foundation
import Testing
@testable import MyGuideCore

@Suite struct DayStoryFlowTests {
    typealias T = DayStoryPlanTests

    /// 1793192400 = 2026-10-28 13:00 UTC: when the story is written.
    static let writtenAt = Date(timeIntervalSince1970: 1_793_192_400)
    static let landscape = TestImages.jpeg(width: 800, height: 600)
    static let portrait = TestImages.jpeg(width: 600, height: 800)
    static let square = TestImages.jpeg(width: 100, height: 100)

    /// A Responses API body whose output text is the day story JSON, with usage 900 in / 150 out.
    static func responseBody(summary: String = "A walk from the fortress to the cathedral.",
                             captions: [(String, String)] = []) throws -> Data {
        let story: [String: Any] = ["summary": summary, "captions": captions.map { ["photoID": $0.0, "caption": $0.1] }]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: story), as: UTF8.self)
        let body: [String: Any] = [
            "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 900, "output_tokens": 150],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func flow(_ http: StubHTTPClient, models: OpenAIModels = .current,
                     photoData: @escaping @Sendable (String) async -> Data?) -> DayStoryFlow {
        DayStoryFlow(openAI: OpenAIClient(apiKey: "k", http: http), models: models, timeZone: T.oslo,
                     now: { Self.writtenAt }, photoData: photoData)
    }

    static func content(_ request: URLRequest) -> [[String: Any]] {
        (((request.jsonBody["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
    }

    static func text(_ request: URLRequest) -> String {
        content(request).first?["text"] as? String ?? ""
    }

    static func images(_ request: URLRequest) -> [[String: Any]] {
        content(request).filter { $0["type"] as? String == "input_image" }
    }

    /// The attached image bytes, decoded from their data URLs.
    static func imageData(_ request: URLRequest) throws -> [Data] {
        try images(request).map { part in
            let url = try #require(part["image_url"] as? String)
            #expect(url.hasPrefix("data:image/jpeg;base64,"))
            return try #require(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
        }
    }

    // MARK: - Request

    @Test func sendsThePlanWithEveryPhotoAttachedAtLowDetail() async throws {
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        let requested = LockedBox<[String]>([])
        let flow = Self.flow(http) { id in
            requested.withValue { $0.append(id) }
            return Self.landscape
        }
        _ = try await flow.write(day: DayStoryPromptTests.day, language: .norwegian)

        let request = try #require(http.requests.first)
        // One request for the day.
        #expect(http.requests.count == 1)
        let body = request.jsonBody
        #expect(body["store"] as? Bool == false)
        #expect(body["prompt_cache_key"] as? String == "myguide-day-v1")
        #expect(body["instructions"] as? String == PromptBuilder.dayStoryInstructions)
        #expect(body["model"] as? String == OpenAIModels.current.story)
        #expect(((body["text"] as? [String: Any])?["format"] as? [String: Any])?["strict"] as? Bool == true)
        // All three photos are loadable, so the user message is exactly the prompt test's.
        #expect(Self.text(request) == DayStoryPromptTests.input())
        // Photos in plan order: library:near (12:03), capture:s (12:40), library:lonely (13:10).
        #expect(requested.value == ["library:near", "capture:s", "library:lonely"])
        let images = Self.images(request)
        // 3 photos → 3 images.
        #expect(images.count == 3)
        #expect(images.allSatisfy { $0["detail"] as? String == "low" })
    }

    @Test func imagesAreDownscaledTo768() async throws {
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        let day = T.day([T.library("a", at: 0), T.library("b", at: 60), T.library("c", at: 120)])
        let sources = ["library:a": Self.landscape, "library:b": Self.portrait, "library:c": Self.square]
        _ = try await Self.flow(http) { sources[$0] }.write(day: day, language: .english)

        let sizes = try Self.imageData(try #require(http.requests.first)).map { data in
            try #require(ImageProcessing.pixelSize(of: data))
        }
        // 800×600: scale 768/800 = 0.96 → 768×576. 600×800: 0.96 → 576×768. 100×100 is under 768: kept, never upscaled.
        #expect(sizes.map(\.width) == [768, 576, 100])
        #expect(sizes.map(\.height) == [576, 768, 100])
    }

    @Test func twentyPhotoDaySendsTwelveAndCountsTwenty() async throws {
        // 20 library photos one minute apart. Chosen indices round(i·19/11), i = 0…11:
        // 0, 1.73 → 2, 3.45 → 3, 5.18 → 5, 6.91 → 7, 8.64 → 9, 10.36 → 10, 12.09 → 12, 13.82 → 14, 15.55 → 16,
        // 17.27 → 17, 19.
        let entries = (0..<20).map { T.library(String(format: "%02ld", $0), at: Double($0) * 60) }
        let http = StubHTTPClient { _ in (200, try Self.responseBody(captions: [("p12", "The last one.")])) }
        let (story, _) = try await Self.flow(http) { _ in Self.square }.write(day: T.day(entries), language: .english)

        let request = try #require(http.requests.first)
        // At most 12 images: the cap.
        #expect(Self.images(request).count == 12)
        let chosen = [0, 2, 3, 5, 7, 9, 10, 12, 14, 16, 17, 19].map { String(format: "library:%02ld", $0) }
        #expect(story.photoIDs == chosen)
        // Every photo of the day, sent or not: 20.
        #expect(story.totalPhotos == 20)
        // p12 is the twelfth chosen photo, index 19.
        #expect(story.captions == ["library:19": "The last one."])
        #expect(Self.text(request).contains("\n- [p12] 12:19, no matching event\n"))
        #expect(!Self.text(request).contains("[p13]"))
    }

    // MARK: - Skipped photos

    @Test func skippedMiddlePhotoKeepsIdsImagesAndCaptionsAligned() async throws {
        // Three library photos; the middle one has no data. The remaining two become p1 and p2.
        let day = T.day([T.library("first", at: 0), T.library("middle", at: 600), T.library("third", at: 1200)])
        let sources = ["library:first": Self.landscape, "library:third": Self.portrait]
        let http = StubHTTPClient { _ in
            (200, try Self.responseBody(captions: [("p2", "The third photo."), ("p1", "The first photo."),
                                                   ("p3", "Nothing has this id.")]))
        }
        let (story, _) = try await Self.flow(http) { sources[$0] }.write(day: day, language: .english)

        let request = try #require(http.requests.first)
        let text = Self.text(request)
        #expect(text.contains("""
            Photos (in the order the images are attached):
            - [p1] 12:00, no matching event
            - [p2] 12:20, no matching event
            Answer in: English
            """))
        #expect(!text.contains("[p3]"))
        // Exactly two images, first then third: landscape 800×600 → 768×576, portrait 600×800 → 576×768.
        let sizes = try Self.imageData(request).map { try #require(ImageProcessing.pixelSize(of: $0)) }
        #expect(sizes.map(\.width) == [768, 576])
        #expect(sizes.map(\.height) == [576, 768])
        // p2 is the third original photo; p3 is unknown and dropped.
        #expect(story.captions == ["library:first": "The first photo.", "library:third": "The third photo."])
        #expect(story.photoIDs == ["library:first", "library:third"])
        // 3 photos that day, 2 sent: the total is 3.
        #expect(story.totalPhotos == 3)
    }

    @Test func undecodablePhotoIsSkippedLikeAMissingOne() async throws {
        let day = T.day([T.library("broken", at: 0), T.library("good", at: 60)])
        let sources = ["library:broken": Data("not a jpeg".utf8), "library:good": Self.square]
        let http = StubHTTPClient { _ in (200, try Self.responseBody(captions: [("p1", "Good.")])) }
        let (story, _) = try await Self.flow(http) { sources[$0] }.write(day: day, language: .english)

        let request = try #require(http.requests.first)
        // 1 image: only the good photo.
        #expect(Self.images(request).count == 1)
        #expect(Self.text(request).contains("\n- [p1] 12:01, no matching event\nAnswer in:"))
        #expect(story.photoIDs == ["library:good"])
        #expect(story.captions == ["library:good": "Good."])
        // 2 photos that day.
        #expect(story.totalPhotos == 2)
    }

    @Test func skippedMatchedPhotoKeepsTheEventsAndOtherMatches() async throws {
        // `near` matches the buzz but has no data; `lonely` and the photo story's photo are still sent, and the buzz
        // is still in the event list.
        let sources = ["capture:s": Self.square, "library:lonely": Self.square]
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        _ = try await Self.flow(http) { sources[$0] }.write(day: DayStoryPromptTests.day, language: .english)

        let text = Self.text(try #require(http.requests.first))
        #expect(text.contains("- 11:58 walking buzz: Akershus Fortress — \"Built in 1299.\""))
        #expect(text.contains("""
            - [p1] 12:40, photo story: Oslo Cathedral
            - [p2] 13:10, no matching event
            """))
        #expect(!text.contains("[p3]"))
    }

    // MARK: - No photos

    @Test func dayWithoutPhotosThrowsWithoutSending() async {
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        let day = T.day([DayStoryPromptTests.buzz, DayStoryPromptTests.stop])
        await #expect(throws: DayStoryError.noPhotos) {
            try await Self.flow(http) { _ in Self.square }.write(day: day, language: .english)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func dayWhosePhotosAllFailThrowsWithoutSending() async {
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        let day = T.day([T.library("a", at: 0), T.library("b", at: 60)])
        let sources = ["library:a": Data([0xFF, 0xD8, 0x00])]
        await #expect(throws: DayStoryError.noPhotos) {
            try await Self.flow(http) { sources[$0] }.write(day: day, language: .english)
        }
        #expect(http.requests.isEmpty)
    }

    // MARK: - Result

    @Test func resultCarriesDayLanguageClockAndUsage() async throws {
        var models = OpenAIModels()
        models.story = "story-model"
        models.storyReasoningEffort = "medium"
        let http = StubHTTPClient { _ in
            (200, try Self.responseBody(summary: " A day by the fjord. ", captions: [("p1", "Walls."), ("p2", "Tower.")]))
        }
        let (story, usage) = try await Self.flow(http, models: models) { _ in Self.square }
            .write(day: DayStoryPromptTests.day, language: .norwegian)

        let body = try #require(http.requests.first).jsonBody
        #expect(body["model"] as? String == "story-model")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(story == DayStory(dayKey: "2026-10-28", createdAt: Self.writtenAt, language: .norwegian,
                                  summary: "A day by the fjord.",
                                  captions: ["library:near": "Walls.", "capture:s": "Tower."],
                                  photoIDs: ["library:near", "capture:s", "library:lonely"], totalPhotos: 3))
        // One request: one entry, 900 in and 150 out as the stub reports.
        #expect(usage == [UsageEntry(date: Self.writtenAt, kind: .story, model: "story-model",
                                     inputTokens: 900, outputTokens: 150, words: 0, images: 0)])
    }

    @Test func cancelledWhileLoadingSendsNothing() async {
        let http = StubHTTPClient { _ in (200, try Self.responseBody()) }
        // The write is cancelled while it loads photos: no paid request may follow.
        let flow = Self.flow(http) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.square
        }
        await #expect(throws: CancellationError.self) {
            try await flow.write(day: DayStoryPromptTests.day, language: .english)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func failedRequestThrows() async {
        let http = StubHTTPClient { _ in (500, Data("oops".utf8)) }
        await #expect(throws: OpenAIError.server(500)) {
            try await Self.flow(http) { _ in Self.square }.write(day: DayStoryPromptTests.day, language: .english)
        }
    }

    @Test func blankSummaryIsMalformed() async {
        let http = StubHTTPClient { _ in (200, try Self.responseBody(summary: "  ")) }
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(http) { _ in Self.square }.write(day: DayStoryPromptTests.day, language: .english)
        }
    }

    @Test func specValues() {
        #expect(DayStoryFlow.uploadLongSide == 768)
        #expect(DayStoryFlow.jpegQuality == 0.7)
        #expect(DayStoryFlow.imageDetail == "low")
    }
}
