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
    public func respond(
        model: String,
        reasoningEffort: String?,
        instructions: String,
        text: String,
        imageJPEG: Data?,
        schemaName: String,
        schema: JSONValue
    ) async throws -> (json: Data, usage: TokenUsage) {
        var content: [JSONValue] = [["type": "input_text", "text": .string(text)]]
        if let imageJPEG {
            content.append([
                "type": "input_image",
                "image_url": .string("data:image/jpeg;base64," + imageJPEG.base64EncodedString()),
            ])
        }
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

        let data = try await post(path: "responses", body: .object(body), timeout: 60)
        return try Self.parseResponse(data)
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
            struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
            var usage: Usage?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let b64 = payload.data.first?.b64_json,
              let png = Data(base64Encoded: b64), !png.isEmpty
        else { throw OpenAIError.malformedResponse }
        let tokens = payload.usage.map { TokenUsage(inputTokens: $0.input_tokens ?? 0, outputTokens: $0.output_tokens ?? 0) }
        return (png, tokens)
    }

    // MARK: - Shared plumbing (reused by speech and image calls)

    /// POSTs a JSON body to `baseURL/path` and returns the body of a 2xx response.
    /// Throws `OpenAIError` for a missing key, transport failures and non-2xx statuses.
    private func post(path: String, body: JSONValue, timeout: TimeInterval) async throws -> Data {
        guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

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
