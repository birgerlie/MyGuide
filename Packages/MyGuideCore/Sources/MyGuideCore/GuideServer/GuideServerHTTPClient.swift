import Foundation

/// HTTPClient in front of the guide server: puts the device token in `Authorization` (replacing the placeholder
/// key `OpenAIClient` sets), and on a 401 renews the token once and resends once. A second 401 is returned as is, so
/// `OpenAIClient.mapError` turns it into `attestUnavailable`. A 403 (`blocked`) is final and never renewed.
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
        guard response.statusCode == 401 else { return (data, response) }

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

        // The refusal's short body is read and dropped so its transfer ends before the retry. A failure while
        // reading it changes nothing (the call is retried either way), but a cancelled caller stops here.
        do { for try await _ in stream {} } catch {}
        try Task.checkCancellation()

        let renewed = try await session.renewToken(rejected: token)
        let (retryStream, retryResponse) = try await base.lines(Self.authorized(request, token: renewed))
        report(retryResponse)
        return (retryStream, retryResponse)
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
