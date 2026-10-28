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

    @Test func sentBodyKeepsOrderedSchemaAndIsDeterministic() async throws {
        let schema: JSONValue = .ordered([JSONMember(key: "z", value: 1), JSONMember(key: "a", value: 2)])
        var bodies: [String] = []
        for _ in 0..<5 {
            let http = StubHTTPClient { _ in (200, Self.okBody) }
            _ = try await OpenAIClient(apiKey: "k", http: http).respond(model: "m", reasoningEffort: "low", instructions: "sys", text: "hello",
                                                                       imageJPEG: nil, schemaName: "s", schema: schema)
            bodies.append(String(decoding: try #require(http.requests.first?.httpBody), as: UTF8.self))
        }
        #expect(bodies[0].contains(#""schema":{"z":1,"a":2}"#))
        #expect(Set(bodies).count == 1)
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

    // MARK: - Multi-image

    static func content(_ request: URLRequest) -> [[String: Any]] {
        (((request.jsonBody["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
    }

    @Test func multiImageRequestAttachesEachImageInOrderWithDetail() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        let images = [Data([0x01]), Data([0x02, 0x03]), Data([0x04, 0x05, 0x06])]
        let r = try await OpenAIClient(apiKey: "k", http: http).respond(
            model: "m", reasoningEffort: "low", instructions: "sys", text: "hello", images: images, imageDetail: "low",
            schemaName: "day", schema: Self.schema, promptCacheKey: "myguide-day-v1")
        #expect(r.usage == TokenUsage(inputTokens: 1200, outputTokens: 400))
        let request = try #require(http.requests.first)
        let b = request.jsonBody
        #expect(b["model"] as? String == "m")
        #expect(b["store"] as? Bool == false)
        #expect(b["instructions"] as? String == "sys")
        #expect(b["prompt_cache_key"] as? String == "myguide-day-v1")
        #expect((b["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(((b["text"] as? [String: Any])?["format"] as? [String: Any])?["name"] as? String == "day")
        let content = Self.content(request)
        // 1 text part + 3 images = 4 parts, the text first.
        #expect(content.count == 4)
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "hello")
        let parts = content.dropFirst()
        #expect(parts.allSatisfy { $0["type"] as? String == "input_image" && $0["detail"] as? String == "low" })
        // Base64 of 01 = "AQ==", of 02 03 = "AgM=", of 04 05 06 = "BAUG".
        #expect(parts.map { $0["image_url"] as? String } == ["AQ==", "AgM=", "BAUG"].map { "data:image/jpeg;base64," + $0 })
    }

    @Test func multiImageRequestWithoutImagesSendsTextOnly() async throws {
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await OpenAIClient(apiKey: "k", http: http).respond(
            model: "m", reasoningEffort: nil, instructions: "s", text: "t", images: [], imageDetail: "high",
            schemaName: "s", schema: Self.schema, promptCacheKey: nil)
        let request = try #require(http.requests.first)
        #expect(request.jsonBody["reasoning"] == nil)
        #expect(request.jsonBody.keys.contains("prompt_cache_key") == false)
        let content = Self.content(request)
        // Text part only: 1.
        #expect(content.count == 1)
        #expect(content.first?["type"] as? String == "input_text")
    }

    @Test func multiImageRequestSharesErrorMapping() async {
        let client = OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (401, Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8)) })
        await #expect(throws: OpenAIError.invalidAPIKey) {
            try await client.respond(model: "m", reasoningEffort: nil, instructions: "s", text: "t", images: [Data([1])],
                                     imageDetail: "low", schemaName: "s", schema: Self.schema, promptCacheKey: nil)
        }
    }

    @Test func singleImageRequestSendsNoDetail() async throws {
        // The single-image call is unchanged: its image part carries no `detail`.
        let http = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await call(OpenAIClient(apiKey: "k", http: http))
        let request = try #require(http.requests.first)
        let image = try #require(Self.content(request).last)
        #expect(image["type"] as? String == "input_image")
        #expect(image.keys.contains("detail") == false)
    }

    // MARK: - Streaming

    /// The lines of one SSE event: its type, its JSON data, and the blank line that ends it.
    static func sse(_ type: String, _ json: String) -> [String] {
        ["event: \(type)", "data: \(json)", ""]
    }

    static func delta(_ text: String) -> [String] {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return sse("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":\#(escaped),"sequence_number":4}"#)
    }

    static func completed(text: String = #"{\"story\":\"Hi\"}"#, usage: String = #"{"input_tokens":120,"output_tokens":40,"total_tokens":160}"#) -> [String] {
        sse("response.completed", #"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_1","status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}],"usage":\#(usage)}}"#)
    }

    static let preamble: [String] =
        sse("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress","output":[]}}"#)
        + [": keep-alive", ""]
        + sse("response.in_progress", #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1","status":"in_progress","output":[]}}"#)

    func stream(_ client: OpenAIClient) -> AsyncThrowingStream<StoryStreamEvent, Error> {
        client.respondStreaming(model: "m", reasoningEffort: "low", instructions: "sys", text: "hello",
                                imageJPEG: Data([0xFF, 0xD8]), schemaName: "s", schema: Self.schema, promptCacheKey: "myguide-story-v1")
    }

    /// Collects every event; rethrows the stream's error.
    func collect(_ client: OpenAIClient) async throws -> [StoryStreamEvent] {
        var events: [StoryStreamEvent] = []
        for try await event in stream(client) { events.append(event) }
        return events
    }

    @Test func streamYieldsDeltasThenCompleted() async throws {
        let http = StubHTTPClient(lines: Self.preamble + Self.delta(#"{"story":"#) + Self.delta(#""Hi"}"#) + Self.completed())
        let events = try await collect(OpenAIClient(apiKey: "k", http: http))
        // usage {"input_tokens":120,"output_tokens":40} maps field for field: inputTokens 120, outputTokens 40
        // (total_tokens 160 = 120 + 40 is not kept).
        #expect(events == [
            .textDelta(#"{"story":"#),
            .textDelta(#""Hi"}"#),
            .completed(json: Data(#"{"story":"Hi"}"#.utf8), usage: TokenUsage(inputTokens: 120, outputTokens: 40)),
        ])
    }

    @Test func completedUsesTheFinalTextNotTheDeltas() async throws {
        // The final JSON comes from `response.output_text`, by the same rule as the non-streaming call.
        let http = StubHTTPClient(lines: Self.delta("partial") + Self.completed(text: #"{\"story\":\"Final\"}"#, usage: #"{"input_tokens":7}"#))
        let events = try await collect(OpenAIClient(apiKey: "k", http: http))
        // A partial usage keeps the story: input 7, missing output counts as 0.
        #expect(events.last == .completed(json: Data(#"{"story":"Final"}"#.utf8), usage: TokenUsage(inputTokens: 7, outputTokens: 0)))
    }

    @Test func streamEndingWithoutCompletedThrows() async {
        let http = StubHTTPClient(lines: Self.preamble + Self.delta(#"{"story":"Half a sto"#))
        let received = LockedBox<[StoryStreamEvent]>([])
        await #expect(throws: OpenAIError.malformedResponse) {
            for try await event in stream(OpenAIClient(apiKey: "k", http: http)) { received.withValue { $0.append(event) } }
        }
        // The partial text was delivered as a delta, but never as a completed story.
        #expect(received.value == [.textDelta(#"{"story":"Half a sto"#)])
    }

    @Test func completedEventWithoutItsBlankLineIsNotAccepted() async {
        // A connection that drops before the blank line that ends `response.completed` is a broken stream.
        let http = StubHTTPClient(lines: Self.delta("x") + Self.completed().dropLast())
        await #expect(throws: OpenAIError.malformedResponse) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test func connectionBreakingMidStreamThrowsNetwork() async {
        let http = StubHTTPClient(lines: Self.delta("x"), failure: OpenAIError.network("The network connection was lost."))
        await #expect(throws: OpenAIError.network("The network connection was lost.")) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test func urlErrorMidStreamBecomesNetwork() async {
        let http = StubHTTPClient(lines: Self.delta("x"), failure: URLError(.networkConnectionLost))
        do {
            _ = try await collect(OpenAIClient(apiKey: "k", http: http))
            Issue.record("expected throw")
        } catch let OpenAIError.network(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func cancelledURLErrorMidStreamBecomesCancellationError() async {
        let http = StubHTTPClient(lines: Self.delta("x"), failure: URLError(.cancelled))
        await #expect(throws: CancellationError.self) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test func failedEventThrows() async {
        let failed = Self.sse("response.failed", #"{"type":"response.failed","sequence_number":5,"response":{"id":"resp_1","status":"failed","output":[],"error":{"code":"server_error","message":"The model failed."}}}"#)
        let http = StubHTTPClient(lines: Self.preamble + Self.delta("x") + failed + Self.completed())
        await #expect(throws: OpenAIError.malformedResponse) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test(arguments: [
        // Failure events with no mappable API error are malformed.
        (#"response.incomplete"#, #"{"type":"response.incomplete","response":{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}}"#, OpenAIError.malformedResponse),
        (#"response.refusal.delta"#, #"{"type":"response.refusal.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"I can't"}"#, OpenAIError.malformedResponse),
        (#"error"#, #"{"type":"error","code":"ERR_SOMETHING","message":"Something went wrong","param":null}"#, OpenAIError.malformedResponse),
        (#"error"#, #"{"type":"error","code":null,"message":"Something","param":null}"#, OpenAIError.malformedResponse),
        // A mapped API error wins, whether its fields are top-level or nested under `error`.
        (#"error"#, #"{"type":"error","code":"insufficient_quota","message":"You exceeded your quota"}"#, OpenAIError.quotaExceeded),
        (#"error"#, #"{"type":"error","error":{"type":"insufficient_quota","code":"insufficient_quota","message":"quota"}}"#, OpenAIError.quotaExceeded),
        (#"error"#, #"{"type":"error","code":"rate_limit_exceeded","message":"Slow down"}"#, OpenAIError.rateLimited("Slow down")),
        (#"error"#, #"{"type":"error","code":"invalid_api_key","message":"bad key"}"#, OpenAIError.invalidAPIKey),
        (#"error"#, #"{"type":"error","code":"model_not_found","message":"gone"}"#, OpenAIError.modelRetired),
        (#"response.failed"#, #"{"type":"response.failed","response":{"id":"r","status":"failed","output":[],"error":{"code":"content_policy_violation","message":"policy"}}}"#, OpenAIError.contentBlocked),
        (#"response.failed"#, #"{"type":"response.failed","response":{"id":"r","status":"failed","output":[],"error":null}}"#, OpenAIError.malformedResponse),
    ])
    func failureEventsThrow(type: String, json: String, expected: OpenAIError) async {
        let http = StubHTTPClient(lines: Self.delta("x") + Self.sse(type, json) + Self.completed())
        await #expect(throws: expected) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test func eventTypeFallsBackToTheJSONTypeWithoutAnEventLine() async throws {
        let lines = Self.delta("a").filter { !$0.hasPrefix("event:") } + Self.completed().filter { !$0.hasPrefix("event:") }
        let events = try await collect(OpenAIClient(apiKey: "k", http: StubHTTPClient(lines: lines)))
        #expect(events.first == .textDelta("a"))
        #expect(events.count == 2)
    }

    @Test func malformedDeltaOrCompletedJSONThrows() async {
        for lines in [Self.sse("response.output_text.delta", #"{"type":"response.output_text.delta"}"#) + Self.completed(),
                      Self.sse("response.output_text.delta", "not json") + Self.completed(),
                      Self.sse("response.completed", #"{"type":"response.completed"}"#),
                      Self.sse("response.completed", #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)] {
            await #expect(throws: OpenAIError.malformedResponse) { try await collect(OpenAIClient(apiKey: "k", http: StubHTTPClient(lines: lines))) }
        }
    }

    @Test func completedRefusalThrowsRefusedLikeTheNonStreamingCall() async {
        let refusal = Self.sse("response.completed", #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help"}]}]}}"#)
        await #expect(throws: OpenAIError.refused("I can't help")) { try await collect(OpenAIClient(apiKey: "k", http: StubHTTPClient(lines: refusal))) }
    }

    @Test func unknownEventsAreIgnored() async throws {
        let noise = Self.sse("response.output_item.added", #"{"type":"response.output_item.added"}"#)
            + Self.sse("response.output_text.done", #"{"type":"response.output_text.done","text":"ignored"}"#)
            + Self.sse("something.new", "not even json")
        let events = try await collect(OpenAIClient(apiKey: "k", http: StubHTTPClient(lines: noise + Self.delta("a") + noise + Self.completed())))
        #expect(events.count == 2)
        #expect(events.first == .textDelta("a"))
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"bad key","code":"invalid_api_key"}}"#),
        (429, #"{"error":{"message":"quota","type":"insufficient_quota","code":"insufficient_quota"}}"#),
        (429, #"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#),
        (400, #"{"error":{"message":"blocked","code":"moderation_blocked"}}"#),
        (500, "upstream exploded"),
    ])
    func non2xxMapsLikePost(status: Int, body: String) async {
        // What the non-streaming call throws for this status and body is the reference.
        var expected: OpenAIError?
        do { _ = try await call(OpenAIClient(apiKey: "k", http: StubHTTPClient { _ in (status, Data(body.utf8)) })) } catch let error as OpenAIError { expected = error } catch {}
        #expect(expected != nil)
        // The error body arrives as stream lines, here pretty-printed over several.
        let lines = body.replacingOccurrences(of: ",", with: ",\n").components(separatedBy: "\n")
        await #expect(throws: expected!) { try await collect(OpenAIClient(apiKey: "k", http: StubHTTPClient(status: status, lines: lines))) }
    }

    @Test func non2xx401IsInvalidAPIKey() async {
        let http = StubHTTPClient(status: 401, lines: ["{", #"  "error": {"message": "bad key", "code": "invalid_api_key"}"#, "}"])
        await #expect(throws: OpenAIError.invalidAPIKey) { try await collect(OpenAIClient(apiKey: "k", http: http)) }
    }

    @Test func bodyHasStreamTrueAndStoreFalse() async throws {
        let http = StubHTTPClient(lines: Self.completed())
        _ = try await collect(OpenAIClient(apiKey: "sk-test", http: http))
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let body = request.jsonBody
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["prompt_cache_key"] as? String == "myguide-story-v1")

        // Apart from `stream`, the body is exactly what `respond(...)` sends for the same arguments.
        let plain = StubHTTPClient { _ in (200, Self.okBody) }
        _ = try await OpenAIClient(apiKey: "sk-test", http: plain).respond(
            model: "m", reasoningEffort: "low", instructions: "sys", text: "hello", imageJPEG: Data([0xFF, 0xD8]),
            schemaName: "s", schema: Self.schema, promptCacheKey: "myguide-story-v1")
        var withoutStream = body
        withoutStream.removeValue(forKey: "stream")
        #expect(NSDictionary(dictionary: withoutStream).isEqual(to: try #require(plain.requests.first).jsonBody))
    }

    @Test func streamingBodyKeepsOrderedSchema() async throws {
        let schema: JSONValue = .ordered([JSONMember(key: "z", value: 1), JSONMember(key: "a", value: 2)])
        let http = StubHTTPClient(lines: Self.completed())
        for try await _ in OpenAIClient(apiKey: "k", http: http).respondStreaming(
            model: "m", reasoningEffort: nil, instructions: "sys", text: "t", imageJPEG: nil,
            schemaName: "s", schema: schema, promptCacheKey: nil) {}
        let body = String(decoding: try #require(http.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains(#""schema":{"z":1,"a":2}"#))
    }

    @Test func streamingWithEmptyKeyThrowsWithoutSending() async {
        let http = StubHTTPClient(lines: Self.completed())
        await #expect(throws: OpenAIError.missingAPIKey) { try await collect(OpenAIClient(apiKey: "  ", http: http)) }
        #expect(http.requests.isEmpty)
    }
}
