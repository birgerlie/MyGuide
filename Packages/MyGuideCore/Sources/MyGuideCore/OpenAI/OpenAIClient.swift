import Foundation

public struct OpenAIClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let apiKey: String
    private let http: HTTPClient
    private let baseURL: URL

    public init(apiKey: String, http: HTTPClient, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.baseURL = baseURL
    }

    // The API key must never leak through print/dump/interpolation.
    public var description: String { "OpenAIClient(apiKey: <redacted>, baseURL: \(baseURL.absoluteString))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["apiKey": "<redacted>", "baseURL": baseURL.absoluteString], displayStyle: .struct)
    }

    /// Structured-output call to the Responses API. Returns the model's JSON text and token usage.
    /// `promptCacheKey`, when given, is sent as `prompt_cache_key` so requests sharing a prefix land on the same cache.
    public func respond(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        text: String,
        imageJPEG: Data?,
        schemaName: String,
        schema: JSONValue,
        promptCacheKey: String? = nil
    ) async throws -> (json: Data, usage: TokenUsage) {
        try await respond(model: model, reasoningEffort: reasoningEffort, instructions: instructions,
                          content: Self.singleImageContent(text: text, imageJPEG: imageJPEG),
                          schemaName: schemaName, schema: schema, promptCacheKey: promptCacheKey)
    }

    /// Structured-output call with several JPEG images, attached after the text in the order given, each at
    /// `imageDetail` (`"low"`, `"high"` or `"auto"`). Otherwise as the single-image call.
    public func respond(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        text: String,
        images: [Data],
        imageDetail: String,
        schemaName: String,
        schema: JSONValue,
        promptCacheKey: String?
    ) async throws -> (json: Data, usage: TokenUsage) {
        let content: [JSONValue] = [["type": "input_text", "text": .string(text)]] + images.map { jpeg in
            [
                "type": "input_image",
                "image_url": .string("data:image/jpeg;base64," + jpeg.base64EncodedString()),
                "detail": .string(imageDetail),
            ]
        }
        return try await respond(model: model, reasoningEffort: reasoningEffort, instructions: instructions,
                                 content: content, schemaName: schemaName, schema: schema, promptCacheKey: promptCacheKey)
    }

    /// Sends one user message made of `content` parts to the Responses API.
    private func respond(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        content: [JSONValue],
        schemaName: String,
        schema: JSONValue,
        promptCacheKey: String?
    ) async throws -> (json: Data, usage: TokenUsage) {
        let body = Self.responsesBody(model: model, reasoningEffort: reasoningEffort, instructions: instructions,
                                      content: content, schemaName: schemaName, schema: schema, promptCacheKey: promptCacheKey)
        let data = try await post(path: "responses", body: .object(body), timeout: 60)
        return try Self.parseResponse(data)
    }

    /// The content parts of the single-image calls: the text, then the JPEG when there is one (no `detail`).
    private static func singleImageContent(text: String, imageJPEG: Data?) -> [JSONValue] {
        var content: [JSONValue] = [["type": "input_text", "text": .string(text)]]
        if let imageJPEG {
            content.append([
                "type": "input_image",
                "image_url": .string("data:image/jpeg;base64," + imageJPEG.base64EncodedString()),
            ])
        }
        return content
    }

    /// The Responses API body for one user message made of `content` parts. Always `store: false`.
    private static func responsesBody(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        content: [JSONValue],
        schemaName: String,
        schema: JSONValue,
        promptCacheKey: String?
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "store": false,
            "instructions": .string(instructions),
            "input": [["role": "user", "content": .array(content)]],
            "text": ["format": [
                "type": "json_schema",
                "name": .string(schemaName),
                "strict": true,
                "schema": schema,
            ]],
        ]
        if let reasoningEffort {
            body["reasoning"] = ["effort": .string(reasoningEffort)]
        }
        if let promptCacheKey {
            body["prompt_cache_key"] = .string(promptCacheKey)
        }
        return body
    }

    /// Text-to-speech call. Returns the MP3 bytes. `text` must be within the API's per-request limit.
    // `store` is deliberately not sent: audio/speech does not accept it (exemption from the global store:false rule).
    public func speech(model: String, voice: String, instructions: String, text: String) async throws -> Data {
        let body: JSONValue = [
            "model": .string(model),
            "voice": .string(voice),
            "instructions": .string(instructions),
            "input": .string(text),
            "response_format": "mp3",
        ]
        return try await post(path: "audio/speech", body: body, timeout: 60)
    }

    /// Image generation. Returns the decoded PNG bytes of `data[0].b64_json` and the optional top-level `usage`
    /// (a missing or partial `usage` is not an error; absent counts are 0, and no `usage` at all is nil).
    // `store` is deliberately not sent: images/generations does not accept it (same exemption as speech).
    // `response_format` is not sent either: gpt-image models always answer with base64.
    public func image(model: String, prompt: String, size: String, quality: String) async throws -> (png: Data, usage: TokenUsage?) {
        let body: JSONValue = [
            "model": .string(model),
            "prompt": .string(prompt),
            "size": .string(size),
            "quality": .string(quality),
            "n": 1,
        ]
        let data = try await post(path: "images/generations", body: body, timeout: 120)
        struct Payload: Decodable {
            struct Item: Decodable { var b64_json: String? }
            var data: [Item]
        }
        struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
        struct UsageEnvelope: Decodable { var usage: Usage? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let b64 = payload.data.first?.b64_json,
              let png = Data(base64Encoded: b64), !png.isEmpty
        else { throw OpenAIError.malformedResponse }
        // Decoded on its own: a malformed `usage` must never discard a paid, valid image.
        let tokens = (try? JSONDecoder().decode(UsageEnvelope.self, from: data))?.usage.map { TokenUsage(inputTokens: $0.input_tokens ?? 0, outputTokens: $0.output_tokens ?? 0) }
        return (png, tokens)
    }

    // MARK: - Shared plumbing (reused by speech and image calls)

    /// POSTs a JSON body to `baseURL/path` and returns the body of a 2xx response.
    /// Throws `OpenAIError` for a missing key, transport failures and non-2xx statuses.
    private func post(path: String, body: JSONValue, timeout: TimeInterval) async throws -> Data {
        let request = try makeRequest(path: path, body: body, timeout: timeout)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw OpenAIError.network(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, body: data)
        }
        return data
    }

    /// The authorised JSON POST to `baseURL/path`. The body goes through `JSONValue.jsonData()` (ordered, deterministic).
    /// Throws `missingAPIKey` before anything is built when there is no key.
    private func makeRequest(path: String, body: JSONValue, timeout: TimeInterval) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.jsonData()
        return request
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var message: String?
            var code: String?
            var type: String?
        }
        var error: Detail?
    }

    static func mapError(status: Int, body: Data) -> OpenAIError {
        let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        if let blocked = permanentError(code: detail?.code) { return blocked }
        // Guide-server codes (spec 8): the code decides, whatever the status.
        switch detail?.code {
        case "daily_quota": return .dailyQuota
        case "server_budget": return .serverBudget
        case "attest_required": return .attestUnavailable
        default: break
        }
        switch status {
        case 401:
            return .invalidAPIKey
        case 429:
            if detail?.code == "insufficient_quota" || detail?.type == "insufficient_quota" {
                return .quotaExceeded
            }
            return .rateLimited(detail?.message ?? "Rate limited")
        default:
            return .server(status)
        }
    }

    /// Codes that mean Retry cannot help, whatever the HTTP status or event.
    private static func permanentError(code: String?) -> OpenAIError? {
        guard let code else { return nil }
        if code == "model_not_found" { return .modelRetired }
        if code == "moderation_blocked" || code.contains("content_policy") { return .contentBlocked }
        return nil
    }

    // MARK: - Responses parsing

    private struct ResponsesPayload: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                var type: String
                var text: String?
                var refusal: String?
            }
            var type: String
            var content: [Content]?
        }
        struct Usage: Decodable {
            // Optional: a partial usage block must never discard a paid story.
            // The cost counter undercounts in that case.
            var input_tokens: Int?
            var output_tokens: Int?
        }
        var status: String?
        var output: [Item]
        var usage: Usage?
    }

    private static func parseResponse(_ data: Data) throws -> (json: Data, usage: TokenUsage) {
        guard let payload = try? JSONDecoder().decode(ResponsesPayload.self, from: data)
        else { throw OpenAIError.malformedResponse }
        return try parseResponse(payload)
    }

    /// The model's JSON (`output_text` of the first message) and usage, from a decoded response object.
    private static func parseResponse(_ payload: ResponsesPayload) throws -> (json: Data, usage: TokenUsage) {
        // A truncated or failed response must not be returned as JSON.
        if let status = payload.status, status == "incomplete" || status == "failed" {
            throw OpenAIError.malformedResponse
        }
        let usage = TokenUsage(inputTokens: payload.usage?.input_tokens ?? 0,
                               outputTokens: payload.usage?.output_tokens ?? 0)
        guard let message = payload.output.first(where: { $0.type == "message" })
        else { throw OpenAIError.malformedResponse }
        for part in message.content ?? [] {
            switch part.type {
            case "refusal":
                throw OpenAIError.refused(part.refusal ?? "")
            case "output_text":
                guard let text = part.text else { throw OpenAIError.malformedResponse }
                return (Data(text.utf8), usage)
            default:
                continue
            }
        }
        throw OpenAIError.malformedResponse
    }
}

// MARK: - Streaming

/// What a streamed Responses call delivers: text fragments as they arrive, then the final JSON and usage.
public enum StoryStreamEvent: Sendable, Equatable {
    /// A fragment of the model's output text (`response.output_text.delta`). Fragments are display hints only.
    case textDelta(String)
    /// The complete JSON from the final response object (the same rule as `respond`), and its usage.
    case completed(json: Data, usage: TokenUsage)
}

extension OpenAIClient {
    /// Streams a structured-output call to the Responses API over server-sent events.
    /// The body is the one `respond(...)` sends for the same arguments, plus `"stream": true`.
    /// The stream yields `.textDelta` per text fragment and ends with exactly one `.completed`, or throws:
    /// - `OpenAIError` for a missing key, a transport failure and a non-2xx status, mapped like `respond`;
    /// - for `response.failed`, `response.incomplete`, `error` and `response.refusal.delta`, the mapped API error
    ///   when the event carries one, otherwise `malformedResponse`;
    /// - `malformedResponse` when the stream ends without `response.completed`.
    /// Ending the iteration early cancels the request.
    public func respondStreaming(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        text: String,
        imageJPEG: Data?,
        schemaName: String,
        schema: JSONValue,
        promptCacheKey: String?
    ) -> AsyncThrowingStream<StoryStreamEvent, Error> {
        var body = Self.responsesBody(model: model, reasoningEffort: reasoningEffort, instructions: instructions,
                                      content: Self.singleImageContent(text: text, imageJPEG: imageJPEG),
                                      schemaName: schemaName, schema: schema, promptCacheKey: promptCacheKey)
        body["stream"] = true
        let finalBody = body
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(body: .object(finalBody)) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Sends the request and hands each event to `yield`. Returns after `.completed`; throws otherwise.
    private func stream(body: JSONValue, yield: (StoryStreamEvent) -> Void) async throws {
        var request = try makeRequest(path: "responses", body: body, timeout: 60)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (lines, response) = try await http.lines(request)
            guard (200..<300).contains(response.statusCode) else {
                var errorLines: [String] = []
                for try await line in lines { errorLines.append(line) }
                throw Self.mapError(status: response.statusCode, body: Data(errorLines.joined(separator: "\n").utf8))
            }
            var parser = ServerSentEventParser()
            for try await line in lines {
                guard let event = parser.feed(line: line) else { continue }
                if let output = try Self.interpret(event) {
                    yield(output)
                    if case .completed = output { return }
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw OpenAIError.network(error.localizedDescription)
        }
        try Task.checkCancellation()
        // The connection closed before `response.completed`: a broken stream, never a partial story.
        throw OpenAIError.malformedResponse
    }

    private struct StreamEnvelope: Decodable {
        struct APIError: Decodable {
            var code: String?
            var type: String?
            var message: String?
        }
        struct FailedResponse: Decodable {
            var error: APIError?
        }
        var type: String?
        var delta: String?
        // The `error` event carries its fields at the top level, or nested under `error`.
        var code: String?
        var message: String?
        var error: APIError?
        var response: FailedResponse?
    }

    private struct CompletedEnvelope: Decodable {
        var response: ResponsesPayload
    }

    /// The story event for one SSE event, nil for events that carry nothing the story needs.
    private static func interpret(_ event: ServerSentEvent) throws -> StoryStreamEvent? {
        let data = Data(event.data.utf8)
        let envelope = try? JSONDecoder().decode(StreamEnvelope.self, from: data)
        guard let type = event.event ?? envelope?.type else { return nil }

        switch type {
        case "response.output_text.delta":
            guard let delta = envelope?.delta else { throw OpenAIError.malformedResponse }
            return .textDelta(delta)
        case "response.completed":
            guard let completed = try? JSONDecoder().decode(CompletedEnvelope.self, from: data)
            else { throw OpenAIError.malformedResponse }
            let (json, usage) = try parseResponse(completed.response)
            return .completed(json: json, usage: usage)
        case "response.failed", "response.incomplete", "error", "response.refusal.delta":
            let detail = envelope?.error ?? envelope?.response?.error
            throw streamError(code: detail?.code ?? envelope?.code,
                              type: detail?.type,
                              message: detail?.message ?? envelope?.message)
        default:
            return nil
        }
    }

    /// The `OpenAIError` an API error inside the stream maps to; `malformedResponse` when nothing specific applies.
    private static func streamError(code: String?, type: String?, message: String?) -> OpenAIError {
        if let permanent = permanentError(code: code) { return permanent }
        if code == "insufficient_quota" || type == "insufficient_quota" { return .quotaExceeded }
        if code == "rate_limit_exceeded" { return .rateLimited(message ?? "Rate limited") }
        if code == "invalid_api_key" { return .invalidAPIKey }
        return .malformedResponse
    }
}
