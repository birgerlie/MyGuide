import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingStoryFlowTests {
    static func body(_ inner: String) -> Data {
        let escaped = String(data: try! JSONEncoder().encode(inner), encoding: .utf8)!
        return Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":\#(escaped)}]}],"usage":{"input_tokens":10,"output_tokens":5},"status":"completed"}"#.utf8)
    }
    static func http(_ story: String = "S") -> StubHTTPClient {
        StubHTTPClient { _ in (200, body(#"{"title":"T","story":"\#(story)"}"#)) }
    }
    static let fixedID = UUID()
    static func flow(_ http: StubHTTPClient, priors: @escaping PriorStoryLookup = { _, _, _ in [] }) -> WalkingStoryFlow {
        WalkingStoryFlow(openAI: OpenAIClient(apiKey: "k", http: http), priors: priors,
                         now: { Date(timeIntervalSince1970: 5) }, makeID: { fixedID })
    }
    static let gate = WalkPromptTests.gate
    static let buzz = WalkPromptTests.buzz
    static let here = Coordinate(latitude: 0.0001, longitude: 0.0002)

    @Test func buzzStoryBuildsAWalkStory() async throws {
        let http = Self.http()
        let (story, usage) = try await Self.flow(http).buzzStory(Self.buzz, position: Self.here, course: 90,
                                                                 nearby: WalkPromptTests.facts, language: .english)
        #expect(story.title == "T" && story.levels == ["S"] && story.kind == .buzz && story.place?.id == Self.buzz.place.candidate.id)
        #expect(story.id == Self.buzz.id && story.detail == "50 m left" && story.address == nil)
        #expect(story.position == Self.here && story.course == 90 && story.createdAt == Date(timeIntervalSince1970: 5))
        #expect(usage == [UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .story, model: "gpt-5-mini",
                                     inputTokens: 10, outputTokens: 5, words: 0, images: 0)])
        let request = try #require(http.requests.first)
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!text.contains("input_image") && text.contains(#""name":"walk_story""#) && text.contains(#""store":false"#))
    }
    @Test func emptyStoryIsMalformed() async {
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(" ")).buzzStory(Self.buzz, position: Self.here, course: nil, nearby: [], language: .english)
        }
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(" ")).stopStory(position: Self.here, address: nil, nearby: [], language: .english)
        }
    }
    @Test func undecodableResponseIsMalformed() async {
        let http = StubHTTPClient { _ in (200, Self.body(#"{"nope":1}"#)) }
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(http).stopStory(position: Self.here, address: nil, nearby: [], language: .english)
        }
    }
    @Test func buzzPriorsStartWithTheBuzzedPlace() async throws {
        let seen = LockedBox<(ids: [String], near: Coordinate, session: UUID?)?>(nil)
        let flow = Self.flow(Self.http()) { ids, near, session in seen.set((ids, near, session)); return [] }
        _ = try await flow.buzzStory(Self.buzz, position: Self.here, course: nil, nearby: WalkPromptTests.facts, language: .english)
        let call = try #require(seen.value)
        // Buzzed place first, then the other places by tier and distance: castle, church, plaque.
        #expect(call.ids == ["osm:node/1", "osm:node/4", "osm:node/2", "osm:node/3"])
        #expect(call.near == Self.here && call.session == nil)
    }
    @Test func priorsReachThePrompt() async throws {
        let http = Self.http()
        let flow = Self.flow(http) { _, _, _ in [PriorStory(placeID: nil, level: .more, text: "Earlier tale.", toldAt: .now)] }
        _ = try await flow.buzzStory(Self.buzz, position: Self.here, course: nil, nearby: [], language: .english)
        #expect(String(decoding: http.requests[0].httpBody!, as: UTF8.self).contains("Earlier tale."))
    }
    @Test func stopStoryHasNoPlace() async throws {
        let seen = LockedBox<[String]>([])
        let flow = Self.flow(Self.http()) { ids, _, _ in seen.set(ids); return [] }
        let address = Address(line: "Graben 1", city: "Wien")
        // Facts are measured from `here` (≈ 25 m from the origin): gate, church, plaque are within 150 m, castle (200 m) is not.
        let (story, usage) = try await flow.stopStory(position: Self.here, address: address,
                                                      nearby: WalkPromptTests.facts, language: .norwegian)
        #expect(story.kind == .stop && story.place == nil && story.id == Self.fixedID)
        #expect(story.address == address && story.detail == nil && story.course == nil && story.language == .norwegian)
        #expect(story.title == "T" && story.levels == ["S"] && usage.count == 1)
        #expect(seen.value == ["osm:node/1", "osm:node/2", "osm:node/3"])
    }
    @Test func continuationAppendsUpToThreeLevels() async throws {
        let seen = LockedBox<(ids: [String], session: UUID?)?>(nil)
        // Each call answers with a distinct text: "Text 1", "Text 2", ...
        let calls = LockedBox(0)
        let http = StubHTTPClient { _ in
            let n = calls.withValue { $0 += 1; return $0 }
            return (200, Self.body(#"{"title":"T\#(n)","story":"Text \#(n)"}"#))
        }
        let flow = Self.flow(http) { ids, _, session in seen.set((ids, session)); return [] }
        let (first, _) = try await flow.buzzStory(Self.buzz, position: Self.here, course: nil, nearby: [], language: .english)
        let (second, usage) = try await flow.continueStory(first)
        #expect(second.levels == ["Text 1", "Text 2"] && second.title == "T1" && usage.count == 1)
        #expect(seen.value?.ids == ["osm:node/1"] && seen.value?.session == first.id)
        let (third, _) = try await flow.continueStory(second)
        #expect(third.levels == ["Text 1", "Text 2", "Text 3"])
        await #expect(throws: PhotoStoryError.noFurtherLevel) { try await flow.continueStory(third) }
    }
}
