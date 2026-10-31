import Foundation
import Testing
@testable import MyGuideCore

/// One canned answer from `RecordingHTTPClient`.
struct FakeResponse: Sendable {
    var status: Int
    var body: Data = Data()
    var headers: [String: String] = [:]

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> FakeResponse {
        FakeResponse(status: status, body: Data(text.utf8), headers: headers)
    }
}

/// Actor-backed HTTPClient that records every request in arrival order and answers through an async responder,
/// so a test can hold answers back (gates, barriers). `lines(_:)` yields the body's lines and counts how many
/// line streams were read to the end.
actor RecordingHTTPClient: HTTPClient {
    typealias Responder = @Sendable (URLRequest) async throws -> FakeResponse

    private let responder: Responder
    private(set) var requests: [URLRequest] = []
    private(set) var lineRequests = 0
    private(set) var drainedStreams = 0

    init(_ responder: @escaping Responder) {
        self.responder = responder
    }

    /// Request paths in arrival order, relative to the host (`/v1/attest/challenge`).
    var paths: [String] { requests.map { $0.url?.path ?? "" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let answer = try await responder(request)
        return (answer.body, Self.response(for: request, answer))
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        requests.append(request)
        lineRequests += 1
        let answer = try await responder(request)
        let remaining = LockedBox(ServerSentEventLineSplitter.lines(in: answer.body))
        let stream = AsyncThrowingStream<String, Error> {
            if let next = remaining.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
            await self.noteDrained()
            return nil
        }
        return (stream, Self.response(for: request, answer))
    }

    private func noteDrained() { drainedStreams += 1 }

    private static func response(for request: URLRequest, _ answer: FakeResponse) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://stub.invalid")!, statusCode: answer.status,
                        httpVersion: "HTTP/1.1", headerFields: answer.headers)!
    }
}

/// Holds every arriving caller until `count` callers have arrived, then lets them all through.
actor Barrier {
    private let count: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func arrive() async {
        arrived += 1
        if arrived >= count {
            for waiter in waiters { waiter.resume() }
            waiters = []
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// App Attest stand-in: counts calls, records the hash it was given, can hold `attestKey` behind a gate or throw.
final class FakeAttestProvider: AppAttestProvider, @unchecked Sendable {
    let isSupported: Bool
    private let gate: Gate?
    private let failure: (any Error & Sendable)?
    private let state = LockedBox((keys: 0, attests: [(keyId: String, hash: Data)]()))

    init(isSupported: Bool = true, gate: Gate? = nil, failure: (any Error & Sendable)? = nil) {
        self.isSupported = isSupported
        self.gate = gate
        self.failure = failure
    }

    var generateKeyCalls: Int { state.value.keys }
    var attestKeyCalls: Int { state.value.attests.count }
    var attested: [(keyId: String, hash: Data)] { state.value.attests }

    func generateKey() async throws -> String {
        let n = state.withValue { $0.keys += 1; return $0.keys }
        return "key-\(n)"
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let n = state.withValue { $0.attests.append((keyId, clientDataHash)); return $0.attests.count }
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return Data("attestation-\(n)".utf8)
    }
}

/// In-memory token store; reads and writes can be made to fail.
final class MemoryTokenStore: GuideTokenStore, @unchecked Sendable {
    struct Failure: Error {}

    private let stored: LockedBox<String?>
    private let writes = LockedBox(0)
    private let failRead: Bool
    private let failWrite: Bool

    init(_ token: String? = nil, failRead: Bool = false, failWrite: Bool = false) {
        stored = LockedBox(token)
        self.failRead = failRead
        self.failWrite = failWrite
    }

    var token: String? { stored.value }
    var writeCount: Int { writes.value }

    func read() throws -> String? {
        if failRead { throw Failure() }
        return stored.value
    }

    func write(_ token: String?) throws {
        writes.withValue { $0 += 1 }
        if failWrite { throw Failure() }
        stored.set(token)
    }
}

/// The guide server as the app sees it: challenge and attest endpoints with canned answers, tokens `token-1`,
/// `token-2`, … per successful attest, and `proxy` for everything else.
enum FakeGuideServer {
    /// 32 bytes 0x00…0x1F, standard base64 like the server's.
    static let challengeBytes = Data((0..<32).map { UInt8($0) })
    static let challenge = challengeBytes.base64EncodedString()
    static let base = URL(string: "https://guide.test/v1")!

    /// A non-200 attest answers `attestBody`, by default an `attest_required` envelope.
    static func responder(challengeStatus: Int = 200, challengeBody: String? = nil, attestStatus: Int = 200,
                          attestBody: String? = nil,
                          proxy: @escaping RecordingHTTPClient.Responder = { _ in .json(200, "{}") })
        -> RecordingHTTPClient.Responder {
        let issued = LockedBox(0)
        return { request in
            switch request.url?.path {
            case "/v1/attest/challenge":
                return .json(challengeStatus, challengeBody ?? #"{"challenge":"\#(challenge)"}"#)
            case "/v1/attest":
                guard attestStatus == 200 else {
                    return .json(attestStatus, attestBody ?? #"{"error":{"code":"attest_required","message":"no"}}"#)
                }
                let n = issued.withValue { $0 += 1; return $0 }
                return .json(200, #"{"token":"token-\#(n)"}"#)
            default:
                return try await proxy(request)
            }
        }
    }
}

/// Polls `condition` until it holds; records an issue when it still does not after about two seconds.
func eventually(_ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}
