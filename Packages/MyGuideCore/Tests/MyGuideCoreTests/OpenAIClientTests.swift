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
    @Test func promptCacheKeyIsSentOnlyWhenGiven() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        let client = OpenAIClient(apiKey: "k", http: http)
        _ = try await client.respond(model: "m", reasoningEffort: nil, instructions: "s", text: "t", imageJPEG: nil,
                                     schemaName: "s", schema: Self.schema, promptCacheKey: "myguide-story-v1")
        _ = try await client.respond(model: "m", reasoningEffort: nil, instructions: "s", text: "t", imageJPEG: nil,
                                     schemaName: "s", schema: Self.schema)
        #expect(http.requests.count == 2)
        #expect(http.requests[0].jsonBody["prompt_cache_key"] as? String == "myguide-story-v1")
        #expect(http.requests[1].jsonBody.keys.contains("prompt_cache_key") == false)
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
        (403, "forbidden", OpenAIError.server(403)),
        (200, "not json", OpenAIError.malformedResponse),
        (404, #"{"error":{"message":"The model does not exist","code":"model_not_found"}}"#, OpenAIError.modelRetired),
        (400, #"{"error":{"message":"gone","code":"model_not_found"}}"#, OpenAIError.modelRetired),
        (401, #"{"error":{"message":"gone","code":"model_not_found"}}"#, OpenAIError.modelRetired),
        (400, #"{"error":{"message":"blocked","code":"moderation_blocked"}}"#, OpenAIError.contentBlocked),
        (400, #"{"error":{"message":"policy","code":"content_policy_violation"}}"#, OpenAIError.contentBlocked),
        (400, #"{"error":{"message":"bad request","code":"invalid_value"}}"#, OpenAIError.server(400)),
    ])
    func mapsHTTPErrors(status: Int, body: String, expected: OpenAIError) async {
        await #expect(throws: expected) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (status, Data(body.utf8)) })) }
    }

    @Test func cancelledURLErrorBecomesCancellationError() async {
        let client = OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { try await call(client) }
    }
    @Test func otherURLErrorBecomesNetwork() async {
        let client = OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await call(client)
            Issue.record("expected throw")
        } catch let OpenAIError.network(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
    @Test func missingUsageYieldsZero() async throws {
        let body = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{}"}]}]}"#.utf8)
        let r = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) }))
        #expect(r.usage == TokenUsage(inputTokens: 0, outputTokens: 0))
    }
    @Test func partialUsageKeepsStory() async throws {
        let body = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{}"}]}],"usage":{"input_tokens":7}}"#.utf8)
        let r = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) }))
        #expect(r.usage == TokenUsage(inputTokens: 7, outputTokens: 0))
    }
    @Test(arguments: ["incomplete", "failed"])
    func nonCompletedStatusIsMalformed(status: String) async {
        let body = Data(#"{"status":"\#(status)","output":[{"type":"message","content":[{"type":"output_text","text":"{\"sto"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.malformedResponse) { try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) })) }
    }
    @Test func completedStatusIsAccepted() async throws {
        let body = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{}"}]}]}"#.utf8)
        let r = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (200, body) }))
        #expect(String(decoding: r.json, as: UTF8.self) == "{}")
    }
    @Test func apiKeyIsRedactedInReflection() {
        let client = OpenAIClient(apiKey: "sk-secret-123", http: StubHTTPClient { _ in (200, Data()) })
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
            #expect(!text.contains("sk-secret-123"))
        }
    }
}
