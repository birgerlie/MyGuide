import Foundation
import Testing
@testable import MyGuideCore

@Suite struct ThenImageTests {
    let s = PromptBuilderTests.session()   // subject Michaelertor, era "around 1890", address Michaelerplatz, Vienna, Austria

    @Test func labelAndRequestConstants() {
        #expect(ThenImage.label == "AI reconstruction — not a real photo")
        #expect(ThenImage.size == "1024x1536" && ThenImage.quality == "medium")
    }
    @Test func promptNamesSubjectPlaceEraAndStyle() {
        let p = PromptBuilder.thenImagePrompt(session: s)
        #expect(p.hasPrefix("Historical reconstruction illustration of Michaelertor at Michaelerplatz, Vienna, Austria, as it looked around 1890."))
        #expect(p.contains("Painterly illustration style with visible brushwork, clearly not a photograph."))
        #expect(p.contains("No text, no captions, no modern objects."))
    }
    @Test func promptWithoutAddressDropsAtClause() {
        var g = PromptBuilderTests.grounding; g.address = nil
        #expect(PromptBuilder.thenImagePrompt(session: PromptBuilderTests.session(grounding: g))
            .hasPrefix("Historical reconstruction illustration of Michaelertor, as it looked around 1890."))
    }
    @Test func flowRequestsImageAndReportsUsage() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}]}"#.utf8)) }
        let (data, usage) = try await PhotoStoryFlowTests.flow(http).thenImage(for: s)
        #expect(data == png)
        #expect(usage == UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .image, model: "gpt-image-2.5-flare",
                                    inputTokens: 0, outputTokens: 0, words: 0, images: 1))
        let r = http.requests[0]
        #expect(r.url!.absoluteString == "https://api.openai.com/v1/images/generations" && r.timeoutInterval == 120)
        let b = r.jsonBody
        #expect(b["size"] as? String == "1024x1536" && b["quality"] as? String == "medium" && b["n"] as? Int == 1)
        #expect(b["model"] as? String == "gpt-image-2.5-flare")
        #expect(b["prompt"] as? String == PromptBuilder.thenImagePrompt(session: s))
    }
    @Test func imageUsageTokensReachTheEntry() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}],"usage":{"input_tokens":1000,"output_tokens":1575}}"#.utf8)) }
        let (_, usage) = try await PhotoStoryFlowTests.flow(http).thenImage(for: s)
        #expect(usage.inputTokens == 1000 && usage.outputTokens == 1575 && usage.images == 1)
    }
    @Test func partialImageUsageCountsMissingAsZero() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}],"usage":{"output_tokens":7}}"#.utf8)) }
        let (_, usage) = try await PhotoStoryFlowTests.flow(http).thenImage(for: s)
        #expect(usage.inputTokens == 0 && usage.outputTokens == 7)
    }
    @Test func malformedUsageStillReturnsTheImage() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        for usageJSON in [#""n/a""#, #"{"input_tokens":1.5,"output_tokens":"x"}"#] {
            let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}],"usage":\#(usageJSON)}"#.utf8)) }
            let (data, usage) = try await PhotoStoryFlowTests.flow(http).thenImage(for: s)
            #expect(data == png && usage.inputTokens == 0 && usage.outputTokens == 0 && usage.images == 1)
        }
    }
    @Test func missingImageDataIsMalformed() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        await #expect(throws: OpenAIError.malformedResponse) { try await PhotoStoryFlowTests.flow(http).thenImage(for: s) }
    }
    @Test func invalidBase64IsMalformed() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":"!!!not base64"}]}"#.utf8)) }
        await #expect(throws: OpenAIError.malformedResponse) { try await PhotoStoryFlowTests.flow(http).thenImage(for: s) }
    }
    @Test func emptyBase64IsMalformed() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"data":[{"b64_json":""}]}"#.utf8)) }
        await #expect(throws: OpenAIError.malformedResponse) { try await PhotoStoryFlowTests.flow(http).thenImage(for: s) }
    }
    @Test func httpErrorIsMapped() async {
        let http = StubHTTPClient { _ in (401, Data("{}".utf8)) }
        await #expect(throws: OpenAIError.invalidAPIKey) { try await PhotoStoryFlowTests.flow(http).thenImage(for: s) }
    }
}
