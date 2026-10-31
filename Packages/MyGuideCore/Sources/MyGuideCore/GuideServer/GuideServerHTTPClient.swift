import Foundation

/// HTTPClient in front of the guide server: puts the device token in `Authorization` (replacing the placeholder
/// key `OpenAIClient` sets), and on a 401 `attest_required` renews the token once and resends once. A second 401 is
/// returned as is, so `OpenAIClient.mapError` turns it into `attestUnavailable`. Any other 401 (OpenAI's status passed
/// through, e.g. `invalid_api_key` for the server's own key) is returned as is without renewing: re-attesting cannot
/// help, and every device doing it would rotate keys and run into the server's attest limit.
/// A 403 (`blocked`) is final and never renewed.
/// Every response that carries the server's allowance headers is reported to `onAllowance`.
public struct GuideServerHTTPClient: HTTPClient {
    private let session: GuideServerSession
    private let base: HTTPClient
    private let onAllowance: @Sendable (ServerAllowance) -> Void

    public init(session: GuideServerSession, base: HTTPClient, onAllowance: @escaping @Sendable (ServerAllowance) -> Void) {
        self.session = session
        self.base = base
        self.onAllowance = onAllowance
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await session.token()
        let (data, response) = try await base.send(Self.authorized(request, token: token))
        report(response)
        guard Self.wantsAttestation(response, body: data) else { return (data, response) }

        let renewed = try await session.renewToken(rejected: token)
        let (retryData, retryResponse) = try await base.send(Self.authorized(request, token: renewed))
        report(retryResponse)
        return (retryData, retryResponse)
    }

    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let token = try await session.token()
        let (stream, response) = try await base.lines(Self.authorized(request, token: token))
        report(response)
        guard response.statusCode == 401 else { return (stream, response) }

        // The refusal's short body is read to see its code (and so its transfer ends before a retry). A failure
        // while reading it leaves what was read; a 401 that is not `attest_required` goes back with those lines.
        var refusal: [String] = []
        do { for try await line in stream { refusal.append(line) } } catch {}
        guard Self.wantsAttestation(response, body: Data(refusal.joined(separator: "\n").utf8)) else {
            return (AsyncThrowingStream(lines: refusal), response)
        }
        try Task.checkCancellation()

        let renewed = try await session.renewToken(rejected: token)
        let (retryStream, retryResponse) = try await base.lines(Self.authorized(request, token: renewed))
        report(retryResponse)
        return (retryStream, retryResponse)
    }

    /// Only a 401 whose error code is `attest_required` is the guide server asking for a new token.
    private static func wantsAttestation(_ response: HTTPURLResponse, body: Data) -> Bool {
        response.statusCode == 401 && OpenAIClient.errorCode(in: body) == "attest_required"
    }

    /// A copy of `request` with only `Authorization` replaced.
    private static func authorized(_ request: URLRequest, token: String) -> URLRequest {
        var copy = request
        copy.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return copy
    }

    private func report(_ response: HTTPURLResponse) {
        if let allowance = ServerAllowance(headers: response.allHeaderFields) { onAllowance(allowance) }
    }
}
