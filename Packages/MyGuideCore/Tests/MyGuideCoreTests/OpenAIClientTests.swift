import Foundation
import Testing
@testable import MyGuideCore

@Suite struct OpenAIClientTests {
    static let okBody = Data(#"""
    {"id":"resp_1","output":[{"type":"reasoning","summary":[]},
     {"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"story\":\"Hi\"}"}]}],
     "usage":{"input_tokens":1200,"output_tokens":400}}
    """#.utf8)
    static let schema: JSONValue = ["type": "object", "properties": ["story": ["type": "string"]], "required": ["story"], "additionalProperties": false]

    func call(_ client: OpenAIClient, image: Data? = Data([0xFF, 0xD8])) async throws -> (json: Data, usage: TokenUsage) {
        try await client.respond(model: "m", reasoningEffort: "low", instructions: "sys", text: "hello",
                                 imageJPEG: image, schemaName: "s", schema: Self.schema)
    }

    @Test func buildsResponsesRequest() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await call(OpenAIClient(apiKey: "sk-test", http: http))
        let r = try #require(http.requests.first)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(r.timeoutInterval == 60)
        let b = r.jsonBody
        #expect(b["model"] as? String == "m")
        #expect(b["store"] as? Bool == false)
        #expect(b["instructions"] as? String == "sys")
        #expect((b["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        let format = ((b["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format?["type"] as? String == "json_schema")
        #expect(format?["strict"] as? Bool == true)
        #expect(format?["name"] as? String == "s")
        let content = (((b["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "input_text")
        #expect((content.last?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }
    @Test func omitsImageAndReasoningWhenNil() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await OpenAIClient(apiKey: "k", http: http).respond(model: "m", reasoningEffort: nil, instructions: "s",
            text: "t", imageJPEG: nil, schemaName: "s", schema: Self.schema)
        let b = http.requests[0].jsonBody
        #expect(b["reasoning"] == nil)
        let content = (((b["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
        #expect(content.count == 1)
    }
    @Test func parsesOutputTextAndUsage() async throws {
        let r = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, Self.okBody) }))
        #expect(String(decoding: r.json, as: UTF8.self) == #"{"story":"Hi"}"#)
        #expect(r.usage == TokenUsage(inputTokens: 1200, outputTokens: 400))
    }
    @Test func refusalThrowsRefused() async {
        let body = Data(#"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.refused("I can't help")) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) })) }
    }
    @Test func missingMessageIsMalformed() async {
        let body = Data(#"{"output":[],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.malformedResponse) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) })) }
    }
    @Test func emptyKeyThrowsWithoutSending() async {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        await #expect(throws: OpenAIError.missingAPIKey) { try await call(OpenAIClient(apiKey: "  ", http: http)) }
        #expect(http.requests.isEmpty)
    }
    @Test(arguments: [
        (401, #"{"error":{"message":"bad key","code":"invalid_api_key"}}"#, OpenAIError.invalidAPIKey),
        (429, #"{"error":{"message":"no money","code":"insufficient_quota"}}"#, OpenAIError.quotaExceeded),
        (429, #"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#, OpenAIError.rateLimited("slow down")),
        (500, "oops", OpenAIError.server(500)),
    ])
    func mapsHTTPErrors(status: Int, body: String, expected: OpenAIError) async {
        await #expect(throws: expected) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (status, Data(body.utf8)) })) }
    }
}
