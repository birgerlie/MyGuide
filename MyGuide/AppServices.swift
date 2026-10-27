import Foundation
import MyGuideCore

/// Builds the network clients and the story flow. The API key is read from the Keychain on every call,
/// so a key saved or removed in Settings takes effect without a relaunch.
@MainActor
final class AppServices {
    nonisolated static let keychainService = "io.github.birgerlie.MyGuide"
    nonisolated static let apiKeyAccount = "openai-api-key"

    let keychain = KeychainStore(service: AppServices.keychainService)
    private let http: HTTPClient = URLSessionHTTPClient()

    /// Throws `OpenAIError.missingAPIKey` when no non-blank key is stored; Keychain failures propagate.
    func makeOpenAI() throws -> OpenAIClient {
        let key = try keychain.read(Self.apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw OpenAIError.missingAPIKey }
        return OpenAIClient(apiKey: key, http: http)
    }

    /// Generated speech lives in Caches: it can be regenerated, so the system may purge it.
    static var speechCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "Speech", directoryHint: .isDirectory)
    }

    /// Throws `OpenAIError.missingAPIKey` when no non-blank key is stored.
    func makeSpeech() throws -> SpeechService {
        SpeechService(openAI: try makeOpenAI(), cacheDirectory: Self.speechCacheDirectory)
    }

    /// Throws `OpenAIError.missingAPIKey` when no key is stored.
    func makeFlow() throws -> PhotoStoryFlow {
        let openAI = try makeOpenAI()
        let grounding = GroundingService(overpass: OverpassClient(http: http),
                                         wikipedia: WikipediaClient(http: http),
                                         geocoder: MapKitReverseGeocoder())
        return PhotoStoryFlow(grounding: grounding, openAI: openAI)
    }
}
