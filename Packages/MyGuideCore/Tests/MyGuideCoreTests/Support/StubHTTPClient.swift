import Foundation
@testable import MyGuideCore

/// Small lock-protected box for sharing mutable state with `@Sendable` closures in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T { lock.withLock { stored } }

    func set(_ newValue: T) {
        lock.withLock { stored = newValue }
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&stored) }
    }
}

/// HTTPClient that never touches the network. The handler returns (status, body) or throws.
private extension LockedBox where T == [URLRequest] {
    func append(_ request: URLRequest) { withValue { $0.append(request) } }
}

final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) throws -> (Int, Data)
    private let recorded = LockedBox<[URLRequest]>([])
    /// Literal lines for `lines(_:)`; nil means "split the handler's body", like the protocol's default.
    private let streamLines: [String]?
    /// Thrown by the line stream after the last of `streamLines`, to simulate a connection that breaks.
    private let streamFailure: (any Error & Sendable)?

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
        self.streamLines = nil
        self.streamFailure = nil
    }

    /// A streaming stub: `lines(_:)` yields `lines` exactly as given (blank lines included), then finishes,
    /// or throws `failure` when one is given. `send(_:)` answers the same lines joined with "\n".
    init(status: Int = 200, lines: [String], failure: (any Error & Sendable)? = nil) {
        let body = Data(lines.joined(separator: "\n").utf8)
        self.handler = { _ in (status, body) }
        self.streamLines = lines
        self.streamFailure = failure
    }

    var requests: [URLRequest] { recorded.value }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        let (status, data) = try handler(request)
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        guard let streamLines else {
            let (data, response) = try await send(request)
            return (AsyncThrowingStream(lines: ServerSentEventLineSplitter.lines(in: data)), response)
        }
        recorded.append(request)
        let (status, _) = try handler(request)
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let failure = streamFailure
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in streamLines { continuation.yield(line) }
            continuation.finish(throwing: failure)
        }
        return (stream, response)
    }
}

extension URLRequest {
    /// The request body parsed as a JSON object; empty if absent or not an object.
    var jsonBody: [String: Any] {
        guard let httpBody, let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else { return [:] }
        return object
    }
}
