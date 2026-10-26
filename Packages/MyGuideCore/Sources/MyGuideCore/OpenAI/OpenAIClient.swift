import Foundation

public struct OpenAIClient: Sendable {
    private let apiKey: String
    private let http: HTTPClient
    private let baseURL: URL

    public init(apiKey: String, http: HTTPClient, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.baseURL = baseURL
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
            var input_tokens: Int
            var output_tokens: Int
        }
        var output: [Item]
        var usage: Usage?
    }

    private static func parseResponse(_ data: Data) throws -> (json: Data, usage: TokenUsage) {
        guard let payload = try? JSONDecoder().decode(ResponsesPayload.self, from: data),
              let message = payload.output.first(where: { $0.type == "message" })
        else { throw OpenAIError.malformedResponse }

        let usage = TokenUsage(inputTokens: payload.usage?.input_tokens ?? 0,
                               outputTokens: payload.usage?.output_tokens ?? 0)
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
