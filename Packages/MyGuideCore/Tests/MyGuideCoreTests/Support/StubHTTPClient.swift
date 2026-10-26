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

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [URLRequest] { recorded.value }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        let (status, data) = try handler(request)
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

extension URLRequest {
    /// The request body parsed as a JSON object; empty if absent or not an object.
    var jsonBody: [String: Any] {
        guard let httpBody, let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else { return [:] }
        return object
    }
}
