import CryptoKit
import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GuideServerSessionTests {
    func makeSession(http: RecordingHTTPClient, attest: FakeAttestProvider = FakeAttestProvider(),
                     store: MemoryTokenStore = MemoryTokenStore()) -> GuideServerSession {
        GuideServerSession(baseURL: FakeGuideServer.base, http: http, attest: attest, store: store)
    }

    @Test func firstTokenAttestsAndStoresIt() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider()
        let store = MemoryTokenStore()
        let token = try await makeSession(http: http, attest: attest, store: store).token()

        #expect(token == "token-1")
        #expect(store.token == "token-1")
        let requests = await http.requests
        #expect(requests.map { $0.url?.absoluteString } == ["https://guide.test/v1/attest/challenge",
                                                           "https://guide.test/v1/attest"])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[0].httpBody == nil || requests[0].httpBody?.isEmpty == true)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = requests[1].jsonBody
        #expect(body["keyId"] as? String == "key-1")
        #expect(body["attestation"] as? String == Data("attestation-1".utf8).base64EncodedString())
        #expect(body["challenge"] as? String == FakeGuideServer.challenge)
        #expect(body.keys.contains("previousToken") == false)
        #expect(Set(body.keys) == ["keyId", "attestation", "challenge"])

        // The server checks nonce = SHA256(authData ‖ SHA256(decoded challenge bytes)): the hash is over the 32 raw
        // bytes, not over the base64 text.
        let expected = Data(SHA256.hash(data: FakeGuideServer.challengeBytes))
        #expect(attest.attested.map(\.hash) == [expected])
        #expect(attest.attested.map(\.keyId) == ["key-1"])
        #expect(expected != Data(SHA256.hash(data: Data(FakeGuideServer.challenge.utf8))))
    }

    @Test func storedTokenNeedsNoNetwork() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider()
        let session = makeSession(http: http, attest: attest, store: MemoryTokenStore("kept"))
        #expect(try await session.token() == "kept")
        #expect(try await session.token() == "kept")
        #expect(await http.requests.isEmpty)
        #expect(attest.generateKeyCalls == 0)
    }

    @Test func unsupportedDeviceIsAttestUnavailableWithoutNetwork() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let session = makeSession(http: http, attest: FakeAttestProvider(isSupported: false))
        await #expect(throws: OpenAIError.attestUnavailable) { try await session.token() }
        #expect(await http.requests.isEmpty)
    }

    @Test func attestEndpoint401IsAttestUnavailable() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(attestStatus: 401))
        let store = MemoryTokenStore()
        let session = makeSession(http: http, store: store)
        await #expect(throws: OpenAIError.attestUnavailable) { try await session.token() }
        #expect(store.token == nil)
        #expect(store.writeCount == 0)
    }

    @Test(arguments: [400, 403, 413, 429, 500])
    func attestEndpointRefusalIsAttestUnavailable(status: Int) async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(attestStatus: status))
        await #expect(throws: OpenAIError.attestUnavailable) { try await makeSession(http: http).token() }
    }

    @Test(arguments: [429, 500, 502])
    func challengeRefusalIsAttestUnavailable(status: Int) async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(challengeStatus: status))
        let attest = FakeAttestProvider()
        await #expect(throws: OpenAIError.attestUnavailable) { try await makeSession(http: http, attest: attest).token() }
        #expect(await http.paths == ["/v1/attest/challenge"])
        #expect(attest.generateKeyCalls == 0)
    }

    @Test func offlineChallengeIsNetwork() async throws {
        let http = RecordingHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let session = makeSession(http: http)
        await #expect(throws: OpenAIError.network(URLError(.notConnectedToInternet).localizedDescription)) {
            try await session.token()
        }
    }

    @Test func networkErrorFromTransportPassesThrough() async throws {
        // URLSessionHTTPClient already maps URLError to OpenAIError.network; that must not become attestUnavailable.
        let http = RecordingHTTPClient { _ in throw OpenAIError.network("offline") }
        await #expect(throws: OpenAIError.network("offline")) { try await makeSession(http: http).token() }
    }

    @Test func cancelledTransportStaysCancellation() async throws {
        let cancelledURL = RecordingHTTPClient { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await makeSession(http: cancelledURL).token() }
        let cancelled = RecordingHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await makeSession(http: cancelled).token() }
    }

    @Test func attestProviderFailureIsAttestUnavailable() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider(failure: URLError(.badServerResponse))
        await #expect(throws: OpenAIError.attestUnavailable) { try await makeSession(http: http, attest: attest).token() }
        #expect(await http.paths == ["/v1/attest/challenge"])
    }

    @Test func attestProviderCancellationStaysCancellation() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider(failure: CancellationError())
        await #expect(throws: CancellationError.self) { try await makeSession(http: http, attest: attest).token() }
    }

    @Test func undecodableChallengeIsMalformedWithoutAttesting() async throws {
        for body in [#"{"challenge":"not base64!"}"#, #"{"other":1}"#, "nope"] {
            let http = RecordingHTTPClient(FakeGuideServer.responder(challengeBody: body))
            let attest = FakeAttestProvider()
            await #expect(throws: OpenAIError.malformedResponse) { try await makeSession(http: http, attest: attest).token() }
            #expect(attest.generateKeyCalls == 0)
        }
    }

    @Test func emptyTokenIsMalformedAndNotStored() async throws {
        let store = MemoryTokenStore()
        let http = RecordingHTTPClient { request in
            request.url?.path == "/v1/attest/challenge"
                ? .json(200, #"{"challenge":"\#(FakeGuideServer.challenge)"}"#) : .json(200, #"{"token":""}"#)
        }
        await #expect(throws: OpenAIError.malformedResponse) { try await makeSession(http: http, store: store).token() }
        #expect(store.writeCount == 0)
    }

    @Test func renewSendsRejectedTokenAsPreviousToken() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let store = MemoryTokenStore("old")
        let session = makeSession(http: http, store: store)
        #expect(try await session.token() == "old")
        #expect(try await session.renewToken(rejected: "old") == "token-1")
        #expect(store.token == "token-1")
        #expect(try await session.token() == "token-1")
        let attestBody = try #require(await http.requests.last).jsonBody
        #expect(attestBody["previousToken"] as? String == "old")
        #expect(await http.paths == ["/v1/attest/challenge", "/v1/attest"])
    }

    @Test func renewWithStaleRejectedTokenReturnsCurrentWithoutAttesting() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider()
        let session = makeSession(http: http, attest: attest, store: MemoryTokenStore("current"))
        #expect(try await session.renewToken(rejected: "stale") == "current")
        #expect(attest.attestKeyCalls == 0)
        #expect(await http.requests.isEmpty)
    }

    @Test func renewWithEmptyStoreStillSendsPreviousToken() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let session = makeSession(http: http)
        #expect(try await session.renewToken(rejected: "lost") == "token-1")
        #expect(try #require(await http.requests.last).jsonBody["previousToken"] as? String == "lost")
    }

    @Test func everyAttestationUsesAFreshKey() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider()
        let session = makeSession(http: http, attest: attest)
        let first = try await session.token()
        _ = try await session.renewToken(rejected: first)
        #expect(attest.generateKeyCalls == 2)
        let keyIds = await http.requests.filter { $0.url?.path == "/v1/attest" }.map { $0.jsonBody["keyId"] as? String }
        #expect(keyIds == ["key-1", "key-2"])
    }

    @Test func failedRenewalLeavesStoredTokenAndPropagates() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder(attestStatus: 401))
        let store = MemoryTokenStore("old")
        let session = makeSession(http: http, store: store)
        await #expect(throws: OpenAIError.attestUnavailable) { try await session.renewToken(rejected: "old") }
        #expect(store.token == "old")
        #expect(store.writeCount == 0)
        #expect(try await session.token() == "old")
    }

    @Test func storeReadFailurePropagates() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let session = makeSession(http: http, store: MemoryTokenStore(failRead: true))
        await #expect(throws: MemoryTokenStore.Failure.self) { try await session.token() }
        #expect(await http.requests.isEmpty)
    }

    @Test func storeWriteFailureStillReturnsTokenForThisProcess() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let attest = FakeAttestProvider()
        let store = MemoryTokenStore(failWrite: true)
        let session = makeSession(http: http, attest: attest, store: store)
        #expect(try await session.token() == "token-1")
        #expect(store.writeCount == 1)
        #expect(store.token == nil)
        #expect(try await session.token() == "token-1")
        #expect(attest.attestKeyCalls == 1)
    }

    @Test func concurrentFirstTokensShareOneAttestation() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let gate = Gate()
        let attest = FakeAttestProvider(gate: gate)
        let session = makeSession(http: http, attest: attest)
        async let a = session.token()
        async let b = session.token()
        try await eventually { attest.attestKeyCalls >= 1 }
        // Give the other caller time to reach the session while the first attestation is held; without sharing it
        // would start a second challenge and a second attestKey here.
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        let tokens = try await [a, b]
        #expect(tokens == ["token-1", "token-1"])
        #expect(attest.attestKeyCalls == 1)
        #expect(await http.paths == ["/v1/attest/challenge", "/v1/attest"])
    }

    @Test func tokenDuringRenewalWaitsForTheNewToken() async throws {
        let http = RecordingHTTPClient(FakeGuideServer.responder())
        let gate = Gate()
        let attest = FakeAttestProvider(gate: gate)
        let session = makeSession(http: http, attest: attest, store: MemoryTokenStore("old"))
        async let renewed = session.renewToken(rejected: "old")
        try await eventually { attest.attestKeyCalls >= 1 }
        async let plain = session.token()
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        #expect(try await [renewed, plain] == ["token-1", "token-1"])
        #expect(attest.attestKeyCalls == 1)
    }
}
