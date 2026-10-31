import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GuideServerHTTPClientTests {
    static let allowanceHeaders = ["X-MyGuide-Free-Left": "story=12,speech=40,image=4", "X-MyGuide-Credits": "37"]
    static let unauthorized = FakeResponse.json(401, #"{"error":{"code":"attest_required","message":"attest"}}"#)

    /// A proxy that answers 401 to anything but `Bearer <valid>` and 200 `{"ok":true}` otherwise.
    static func proxy(valid: String, headers: [String: String] = [:]) -> RecordingHTTPClient.Responder {
        { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(valid)"
                ? .json(200, #"{"ok":true}"#, headers: headers) : unauthorized
        }
    }

    static func proxyRequest() -> URLRequest {
        var request = URLRequest(url: FakeGuideServer.base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(GuideServer.placeholderKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = Data(#"{"model":"m"}"#.utf8)
        return request
    }

    func makeClient(http: RecordingHTTPClient, attest: FakeAttestProvider = FakeAttestProvider(),
                    store: MemoryTokenStore, allowances: LockedBox<[ServerAllowance]> = LockedBox([]))
        -> GuideServerHTTPClient {
        let session = GuideServerSession(baseURL: FakeGuideServer.base, http: http, attest: attest, store: store)
        return GuideServerHTTPClient(session: session, base: http) { allowance in
            allowances.withValue { $0.append(allowance) }
        }
    }

    func proxyRequests(_ http: RecordingHTTPClient) async -> [URLRequest] {
        await http.requests.filter { $0.url?.path == "/v1/responses" }
    }

    @Test func test_concurrent_401_one_attestation() async throws {
        // Both calls carry the stored "old" token and are held until both have arrived, so both see 401 before
        // anyone renews; the attestation is then held so the second renewal arrives while the first is in flight.
        let barrier = Barrier(count: 2)
        let gate = Gate()
        let attest = FakeAttestProvider(gate: gate)
        let http = RecordingHTTPClient(FakeGuideServer.responder { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" { return .json(200, #"{"ok":true}"#) }
            await barrier.arrive()
            return Self.unauthorized
        })
        let client = makeClient(http: http, attest: attest, store: MemoryTokenStore("old"))

        async let first = client.send(Self.proxyRequest())
        async let second = client.send(Self.proxyRequest())
        try await eventually { attest.attestKeyCalls >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        let statuses = try await [first.1.statusCode, second.1.statusCode]

        #expect(statuses == [200, 200])
        #expect(attest.attestKeyCalls == 1)
        #expect(attest.generateKeyCalls == 1)
        let auth = await proxyRequests(http).map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer old", "Bearer old", "Bearer token-1", "Bearer token-1"])
        #expect(await http.paths.filter { $0.hasPrefix("/v1/attest") } == ["/v1/attest/challenge", "/v1/attest"])
    }

    @Test func secondUnauthorizedIsReturnedAsIsAfterOneRenewal() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in Self.unauthorized })
        let attest = FakeAttestProvider()
        let store = MemoryTokenStore("old")
        let (data, response) = try await makeClient(http: http, attest: attest, store: store).send(Self.proxyRequest())

        #expect(response.statusCode == 401)
        #expect(OpenAIClient.mapError(status: response.statusCode, body: data) == .attestUnavailable)
        #expect(attest.attestKeyCalls == 1)
        let auth = await proxyRequests(http).map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer old", "Bearer token-1"])
        #expect(store.token == "token-1")
    }

    @Test func linesRetriesOnceAfter401AndDrainsTheRefusal() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1"
                ? .json(200, "data: one\n\ndata: two\n") : Self.unauthorized
        })
        let client = makeClient(http: http, store: MemoryTokenStore("old"))
        let (stream, response) = try await client.lines(Self.proxyRequest())
        var lines: [String] = []
        for try await line in stream { lines.append(line) }

        #expect(response.statusCode == 200)
        #expect(lines == ["data: one", "", "data: two"])
        #expect(await http.lineRequests == 2)
        #expect(await http.drainedStreams == 2)
        let auth = await proxyRequests(http).map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer old", "Bearer token-1"])
    }

    @Test func linesSecondUnauthorizedIsReturnedAsIs() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in Self.unauthorized })
        let attest = FakeAttestProvider()
        let (stream, response) = try await makeClient(http: http, attest: attest, store: MemoryTokenStore("old"))
            .lines(Self.proxyRequest())
        var body = ""
        for try await line in stream { body += line }

        #expect(response.statusCode == 401)
        #expect(OpenAIClient.mapError(status: 401, body: Data(body.utf8)) == .attestUnavailable)
        #expect(await http.lineRequests == 2)
        #expect(attest.attestKeyCalls == 1)
    }

    @Test func authorizationReplacesPlaceholderAndKeepsTheRest() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(proxy: Self.proxy(valid: "token-1")))
        let original = Self.proxyRequest()
        let (_, response) = try await makeClient(http: http, store: MemoryTokenStore()).send(original)

        #expect(response.statusCode == 200)
        let sent = try #require(await proxyRequests(http).first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(sent.url == original.url)
        #expect(sent.httpMethod == "POST")
        #expect(sent.httpBody == original.httpBody)
        #expect(sent.timeoutInterval == 60)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.allHTTPHeaderFields?.count == original.allHTTPHeaderFields?.count)
    }

    @Test func requestWithoutAuthorizationGetsTheToken() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(proxy: Self.proxy(valid: "kept")))
        let request = URLRequest(url: FakeGuideServer.base.appendingPathComponent("responses"))
        _ = try await makeClient(http: http, store: MemoryTokenStore("kept")).send(request)
        #expect(try #require(await proxyRequests(http).first).value(forHTTPHeaderField: "Authorization") == "Bearer kept")
    }

    @Test func allowanceIsReportedFromHeaders() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(proxy: Self.proxy(valid: "kept", headers: Self.allowanceHeaders)))
        let allowances = LockedBox<[ServerAllowance]>([])
        let client = makeClient(http: http, store: MemoryTokenStore("kept"), allowances: allowances)
        _ = try await client.send(Self.proxyRequest())
        let (stream, _) = try await client.lines(Self.proxyRequest())
        for try await _ in stream {}

        #expect(allowances.value.count == 2)
        #expect(allowances.value.first?.freeLeft == ["story": 12, "speech": 40, "image": 4])
        #expect(allowances.value.first?.credits == 37)
    }

    @Test func allowanceIsNotReportedWithoutHeaders() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(proxy: Self.proxy(valid: "kept")))
        let allowances = LockedBox<[ServerAllowance]>([])
        let client = makeClient(http: http, store: MemoryTokenStore("kept"), allowances: allowances)
        _ = try await client.send(Self.proxyRequest())
        _ = try await client.lines(Self.proxyRequest())
        #expect(allowances.value.isEmpty)
    }

    @Test func allowanceFromRefusalAfterAuthIsReported() async throws {
        // A daily_quota refusal still carries the headers (constraints: every proxy answer after auth).
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in
            .json(429, #"{"error":{"code":"daily_quota","message":"q"}}"#,
                  headers: ["X-MyGuide-Free-Left": "story=0,speech=40,image=4", "X-MyGuide-Credits": "0"])
        })
        let allowances = LockedBox<[ServerAllowance]>([])
        let (_, response) = try await makeClient(http: http, store: MemoryTokenStore("kept"), allowances: allowances)
            .send(Self.proxyRequest())
        #expect(response.statusCode == 429)
        #expect(allowances.value == [ServerAllowance(freeLeft: ["story": 0, "speech": 40, "image": 4], credits: 0)])
    }

    /// OpenAI's own 401, passed through by the proxy after auth (the server's OpenAI key revoked or mistyped).
    static let upstreamUnauthorized = #"{"error":{"code":"invalid_api_key","message":"Incorrect API key"}}"#

    @Test func otherUnauthorizedIsReturnedUnchangedWithoutAttesting() async throws {
        for body in [Self.upstreamUnauthorized, "", "not json", #"{"error":{"message":"no code"}}"#] {
            let http = RecordingHTTPClient(FakeGuideServer.responder { _ in .json(401, body) })
            let attest = FakeAttestProvider()
            let store = MemoryTokenStore("kept")
            let (data, response) = try await makeClient(http: http, attest: attest, store: store).send(Self.proxyRequest())

            #expect(response.statusCode == 401)
            #expect(data == Data(body.utf8))
            #expect(attest.generateKeyCalls == 0)
            #expect(attest.attestKeyCalls == 0)
            #expect(await http.requests.count == 1)
            #expect(store.token == "kept")
        }
    }

    @Test func otherUnauthorizedReachesOpenAIClientAsItsOwnError() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in .json(401, Self.upstreamUnauthorized) })
        let attest = FakeAttestProvider()
        let openAI = OpenAIClient(apiKey: GuideServer.placeholderKey,
                                  http: makeClient(http: http, attest: attest, store: MemoryTokenStore("kept")),
                                  baseURL: FakeGuideServer.base)
        await #expect(throws: OpenAIError.invalidAPIKey) {
            try await openAI.respond(model: "m", reasoningEffort: nil, instructions: "s", text: "t", imageJPEG: nil,
                                     schemaName: "s", schema: ["type": "object"])
        }
        #expect(attest.attestKeyCalls == 0)
    }

    @Test func linesOtherUnauthorizedIsReturnedWithItsBodyWithoutAttesting() async throws {
        let body = "{\"error\":\n{\"code\":\"invalid_api_key\",\"message\":\"Incorrect API key\"}}"
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in .json(401, body) })
        let attest = FakeAttestProvider()
        let (stream, response) = try await makeClient(http: http, attest: attest, store: MemoryTokenStore("kept"))
            .lines(Self.proxyRequest())
        var lines: [String] = []
        for try await line in stream { lines.append(line) }

        #expect(response.statusCode == 401)
        #expect(lines == ServerSentEventLineSplitter.lines(in: Data(body.utf8)))
        #expect(lines.count == 2)
        #expect(OpenAIClient.mapError(status: 401, body: Data(lines.joined(separator: "\n").utf8)) == .invalidAPIKey)
        #expect(attest.generateKeyCalls == 0)
        #expect(await http.lineRequests == 1)
    }

    @Test func blockedIsFinalAndNeverReattests() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder { _ in .json(403, #"{"error":{"code":"blocked","message":"b"}}"#) })
        let attest = FakeAttestProvider()
        let (_, response) = try await makeClient(http: http, attest: attest, store: MemoryTokenStore("kept"))
            .send(Self.proxyRequest())
        #expect(response.statusCode == 403)
        #expect(attest.generateKeyCalls == 0)
        #expect(await proxyRequests(http).count == 1)
    }

    @Test func sessionFailureIsThrownBeforeAnyProxyCall() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let client = makeClient(http: http, attest: FakeAttestProvider(isSupported: false), store: MemoryTokenStore())
        await #expect(throws: OpenAIError.attestUnavailable) { try await client.send(Self.proxyRequest()) }
        await #expect(throws: OpenAIError.attestUnavailable) { try await client.lines(Self.proxyRequest()) }
        #expect(await http.requests.isEmpty)
    }

    @Test func failedRenewalAfter401IsThrown() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(attestStatus: 401) { _ in Self.unauthorized })
        let store = MemoryTokenStore("old")
        await #expect(throws: OpenAIError.attestUnavailable) {
            try await makeClient(http: http, store: store).send(Self.proxyRequest())
        }
        #expect(await proxyRequests(http).count == 1)
        #expect(store.token == "old")
    }

    @Test func placeholderKeyAndBaseURL() {
        #expect(GuideServer.placeholderKey == "guide-server")
        #expect(GuideServer.baseURL.absoluteString == "https://myguide.itsalie.xyz/v1")
    }
}
