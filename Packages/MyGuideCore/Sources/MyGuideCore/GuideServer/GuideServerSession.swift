import CryptoKit
import Foundation
import os

/// Gets and keeps the guide server's device token (spec 5, 8). The first call proves the app with App Attest:
/// `POST {base}/attest/challenge`, a fresh App Attest key, its attestation over SHA-256 of the decoded challenge
/// bytes, then `POST {base}/attest`, which answers the token. The token goes to `store` and is kept in memory.
///
/// At most one attestation is in flight: every caller that arrives while one runs waits for that one's result.
/// Errors: no App Attest, a failed attestation or a refusal (400, 401, 403, 413, …) from either endpoint →
/// `OpenAIError.attestUnavailable`; 429 and 5xx → `OpenAIClient.mapError` (`rateLimited`, `serverBudget`,
/// `server(n)`); a `URLError` → `OpenAIError.network`; cancellation stays `CancellationError`.
/// Tokens, challenges and attestations are never logged.
public actor GuideServerSession {
    private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "guide-server")

    private let baseURL: URL
    private let http: HTTPClient
    private let attest: AppAttestProvider
    private let store: GuideTokenStore
    /// The token this process uses: read from `store` once, then replaced by each attestation, also when writing it
    /// to `store` failed.
    private var current: String?
    private var loaded = false
    private var attestation: Task<String, Error>?

    public init(baseURL: URL, http: HTTPClient, attest: AppAttestProvider, store: GuideTokenStore) {
        self.baseURL = baseURL
        self.http = http
        self.attest = attest
        self.store = store
    }

    /// The kept token, or a new one from an attestation when there is none. Waits for a running attestation
    /// rather than handing out the token it is replacing. A failing `store.read()` throws as is.
    public func token() async throws -> String {
        if let attestation { return try await attestation.value }
        if let token = try keptToken() { return token }
        return try await attestOnce(previousToken: nil)
    }

    /// A token to use instead of `rejected`, which the server refused with 401. When the kept token already differs
    /// (another caller renewed it meanwhile) that one is returned; otherwise the app attests again, sending
    /// `rejected` as `previousToken` so the server re-keys the same device and its wallet stays. A failed attestation
    /// throws and leaves the kept token as it was.
    public func renewToken(rejected: String) async throws -> String {
        // A running attestation that ends with the very token the server refused is no renewal: attest again.
        while let running = attestation {
            let token = try await running.value
            if token != rejected { return token }
            if attestation == running { break }
        }
        if let token = try keptToken(), token != rejected { return token }
        return try await attestOnce(previousToken: rejected)
    }

    private func keptToken() throws -> String? {
        if !loaded {
            current = try store.read().flatMap { $0.isEmpty ? nil : $0 }
            loaded = true
        }
        return current
    }

    /// Starts the one attestation and waits for it. Only called when none is in flight; the actor is not entered
    /// again before `attestation` is set, so later callers find it. The task clears the slot itself as it ends
    /// (before any waiter resumes), so no caller is handed a finished attestation's token as a fresh one, and a
    /// late-resuming starter can never clear a newer attestation's slot.
    private func attestOnce(previousToken: String?) async throws -> String {
        let task = Task {
            defer { self.attestation = nil }
            return try await self.attestAndKeep(previousToken: previousToken)
        }
        attestation = task
        return try await task.value
    }

    private func attestAndKeep(previousToken: String?) async throws -> String {
        guard attest.isSupported else { throw OpenAIError.attestUnavailable }

        let challenge = try decode(ChallengeAnswer.self, from: try await post("attest/challenge", body: nil)).challenge
        guard let challengeBytes = Data(base64Encoded: challenge), !challengeBytes.isEmpty else {
            throw OpenAIError.malformedResponse
        }
        // The server checks nonce = SHA256(authData ‖ clientDataHash) with clientDataHash over the decoded bytes.
        let clientDataHash = Data(SHA256.hash(data: challengeBytes))

        let keyId: String
        let attestationObject: Data
        do {
            // A fresh key every time: the server refuses a key id already registered to another device.
            keyId = try await attest.generateKey()
            attestationObject = try await attest.attestKey(keyId, clientDataHash: clientDataHash)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("App Attest failed: \(String(describing: error), privacy: .public)")
            throw OpenAIError.attestUnavailable
        }

        let request = AttestRequest(keyId: keyId, attestation: attestationObject.base64EncodedString(),
                                    challenge: challenge, previousToken: previousToken)
        let token = try decode(TokenAnswer.self, from: try await post("attest", body: try JSONEncoder().encode(request))).token
        guard !token.isEmpty else { throw OpenAIError.malformedResponse }

        current = token
        loaded = true
        do {
            try store.write(token)
        } catch {
            // The token still works for this process; the next launch attests again.
            Self.log.error("Could not store the guide token: \(String(describing: type(of: error)), privacy: .public)")
        }
        return token
    }

    /// `POST {base}/path` without authorisation. 429 and 5xx are mapped like any guide-server answer
    /// (`rateLimited`, `serverBudget`, `server(n)`); every other non-2xx → `attestUnavailable`.
    private func post(_ path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw OpenAIError.network(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            Self.log.error("Guide server \(path, privacy: .public) answered \(response.statusCode)")
            if response.statusCode == 429 || response.statusCode >= 500 {
                throw OpenAIClient.mapError(status: response.statusCode, body: data)
            }
            throw OpenAIError.attestUnavailable
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenAIError.malformedResponse
        }
    }

    private struct ChallengeAnswer: Decodable {
        var challenge: String
    }

    private struct TokenAnswer: Decodable {
        var token: String
    }

    /// The body of `POST /attest`; a nil `previousToken` is left out.
    private struct AttestRequest: Encodable {
        var keyId: String
        var attestation: String
        var challenge: String
        var previousToken: String?
    }
}
