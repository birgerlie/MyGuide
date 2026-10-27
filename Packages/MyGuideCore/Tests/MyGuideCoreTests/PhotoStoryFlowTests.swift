import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PhotoStoryFlowTests {
    struct Geo: ReverseGeocoding { func address(for: Coordinate) async throws -> Address { Address(line: "Platz", city: "Wien", country: nil) } }
    static let storyJSON = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":"osm:node/1","title":"T","era":"around 1890","story":"Once a coachman waited here."}"#
    static func openAIBody(_ inner: String) -> Data {
        let escaped = String(data: try! JSONEncoder().encode(inner), encoding: .utf8)!
        return Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":\#(escaped)}]}],"usage":{"input_tokens":900,"output_tokens":120}}"#.utf8)
    }
    static func http(_ openAI: Data = openAIBody(storyJSON)) -> StubHTTPClient {
        StubHTTPClient { r in
            switch r.url!.host! {
            case let h where h.contains("overpass"): (200, Data(GroundingTests.osmJSON.utf8))
            case let h where h.contains("wikipedia"): (200, Data(GroundingTests.wikiJSON.utf8))
            default: (200, openAI)
            }
        }
    }
    static func flow(_ http: StubHTTPClient, priors: @escaping PriorStoryLookup = { _, _, _ in [] }) -> PhotoStoryFlow {
        PhotoStoryFlow(grounding: GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo()),
                       openAI: OpenAIClient(apiKey: "k", http: http), priors: priors, now: { Date(timeIntervalSince1970: 5) })
    }
    static let capture = GroundingTests.capture(heading: 0, acc: 10)

    @Test func tellsFirstStory() async throws {
        let http = Self.http()
        let (s, usage) = try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 4032, height: 3024, orientation: 6),
                                                                capture: Self.capture, language: .english)
        #expect(s.levels == ["Once a coachman waited here."] && s.nextLevel == .more)
        #expect(s.matchedCandidate?.candidate.name == "Gate")
        // Compare components: tuples with labels do not compare directly.
        // 400/4032·3024 = 300, portrait
        let thumb = ImageProcessing.pixelSize(of: s.thumbnailJPEG)!
        #expect(thumb.width == 300 && thumb.height == 400)
        // 1536/4032·3024 = 1152, portrait
        let photo = ImageProcessing.pixelSize(of: s.photoJPEG)!
        #expect(photo.width == 1152 && photo.height == 1536)
        #expect(usage == [UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .story, model: "gpt-5-mini",
                                     inputTokens: 900, outputTokens: 120, words: 0, images: 0)])
        let openAIRequest = http.requests.first { $0.url!.host == "api.openai.com" }!
        let content = ((openAIRequest.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        let b64 = (content[1]["image_url"] as! String).replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        let sent = ImageProcessing.pixelSize(of: Data(base64Encoded: b64)!)!
        #expect(sent.width == 1152 && sent.height == 1536)
    }
    @Test func noPositionThrowsBeforeAnyRequest() async {
        let http = Self.http(); var cap = Self.capture; cap.coordinate = nil
        await #expect(throws: PhotoStoryError.noPosition) {
            try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english)
        }
        #expect(http.requests.isEmpty)
    }
    @Test func priorsAreLookedUpByCandidateIDsAndSent() async throws {
        let http = Self.http()
        let seen = LockedBox<(ids: [String], near: Coordinate, session: UUID?)?>(nil)
        let flow = Self.flow(http) { ids, near, session in
            seen.set((ids, near, session))
            return [PriorStory(placeID: "osm:node/1", level: .first, text: "Told before: the coachman.", toldAt: .now)]
        }
        // Non-zero coordinate so a hard-coded (0, 0) would be caught.
        var cap = Self.capture
        cap.coordinate = Coordinate(latitude: 0.0001, longitude: 0.0002)
        _ = try await flow.tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english)
        let call = try #require(seen.value)
        #expect(Set(call.ids) == ["osm:node/1", "wiki:en/5"])
        #expect(call.near == cap.coordinate)
        #expect(call.session == nil)
        let body = String(decoding: http.requests.first { $0.url!.host == "api.openai.com" }!.httpBody!, as: UTF8.self)
        #expect(body.contains("Told before: the coachman."))
    }
    @Test func refusalPropagates() async {
        let refusal = Data(#"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.refused("no")) {
            try await Self.flow(Self.http(refusal)).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        }
    }
    @Test(arguments: ["", "   \n\t "])
    func emptyStoryIsMalformed(story: String) async {
        let json = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"\#(story.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))"}"#
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(Self.openAIBody(json))).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        }
    }
    @Test func unreadablePhotoThrowsBeforeAnyRequest() async {
        let http = Self.http()
        await #expect(throws: ImageProcessingError.unreadableImage) {
            try await Self.flow(http).tellFirstStory(photoJPEG: Data("not a jpeg".utf8), capture: Self.capture, language: .english)
        }
        #expect(http.requests.isEmpty)
    }
    @Test func nextLevelRunsOutAfterThreeLevels() async throws {
        var (s, _) = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        s.levels += ["two", "three"]
        #expect(s.nextLevel == nil)
    }

    @Test func continueAddsLevelWithoutImage() async throws {
        let http = Self.http(Self.openAIBody(#"{"story":"Level two."}"#))
        let flow = Self.flow(http)
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        let (next, usage) = try await flow.continueStory(s)
        #expect(next.levels == ["Once a coachman waited here.", "Level two."] && next.nextLevel == .evenMore)
        #expect(usage.count == 1 && usage[0].kind == .story)
        let r = http.requests.first { $0.url!.host == "api.openai.com" }!
        let content = ((r.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        #expect(content.count == 1)                        // text only, no image
        #expect(String(decoding: r.httpBody!, as: UTF8.self).contains("about 75 words"))
        s.levels = ["a", "b", "c"]
        let before = http.requests.count
        await #expect(throws: PhotoStoryError.noFurtherLevel) { try await flow.continueStory(s) }
        #expect(http.requests.count == before)
    }
    @Test func continuePassesSessionIDToPriorsForExclusion() async throws {
        let s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        let excluded = LockedBox<UUID?>(nil)
        let ids = LockedBox<[String]>([])
        let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { placeIDs, _, exclude in
            excluded.set(exclude); ids.set(placeIDs); return []
        }
        _ = try await flow.continueStory(s)
        #expect(excluded.value == s.id)
        #expect(ids.value == ["osm:node/1"])   // matched candidate only
    }
    @Test(arguments: ["", "   \n\t "])
    func emptyContinuationIsMalformed(story: String) async throws {
        let s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        let inner = #"{"story":"\#(story.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))"}"#
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(Self.openAIBody(inner))).continueStory(s)
        }
    }
    @Test func continueWithoutCoordinateSkipsPriorsAndDoesNotThrow() async throws {
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        s.capture.coordinate = nil
        let called = LockedBox<Bool>(false)
        let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { _, _, _ in called.set(true); return [] }
        let (next, _) = try await flow.continueStory(s)
        #expect(next.levels.last == "Two." && called.value == false)
    }
}
