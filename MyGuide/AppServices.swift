import Foundation
import MyGuideCore
import os

/// Builds the network clients and the story flow. The API key is read from the Keychain on every call,
/// so a key saved or removed in Settings takes effect without a relaunch.
@MainActor
final class AppServices {
    nonisolated static let keychainService = "io.github.birgerlie.MyGuide"
    nonisolated static let apiKeyAccount = "openai-api-key"

    nonisolated static let memoryLog = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "memory")

    let keychain = KeychainStore(service: AppServices.keychainService)
    /// The one memory store, over the app's main context. Story saving, priors and History all share it.
    let memory: MemoryStore
    private let http: HTTPClient = URLSessionHTTPClient()

    init(memory: MemoryStore) {
        self.memory = memory
    }

    /// Logs a memory failure without any story text: only the error's type, and domain and code when it has them.
    nonisolated static func logMemoryFailure(_ what: String, _ error: Error) {
        let ns = error as NSError
        memoryLog.error("\(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public) \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
    }

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
        let memory = memory
        // A memory failure must never block a story: log it and tell the flow there are no priors.
        let priors: PriorStoryLookup = { placeIDs, near, excluding in
            await MainActor.run {
                do {
                    return try memory.priorStories(placeIDs: placeIDs, near: near, excludingSession: excluding)
                } catch {
                    AppServices.logMemoryFailure("priors lookup failed", error)
                    return []
                }
            }
        }
        return PhotoStoryFlow(grounding: grounding, openAI: openAI, priors: priors)
    }

    /// Deletes a history entry (its stories cascade), saves, then removes its cached speech files.
    /// On a failed save the context is rolled back and the error rethrown; the cache is left alone.
    func deleteHistoryEntry(_ record: CaptureRecord) throws {
        let id = record.id
        let context = memory.context
        context.delete(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            Self.logMemoryFailure("delete failed", error)
            throw error
        }
        Self.removeSpeechFiles(sessionID: id)
    }

    /// Cached speech is named `<session id>-<level>-<language>.mp3`.
    private static func removeSpeechFiles(sessionID: UUID) {
        let fm = FileManager.default
        let prefix = sessionID.uuidString
        guard let files = try? fm.contentsOfDirectory(at: speechCacheDirectory, includingPropertiesForKeys: nil) else {
            return // no cache directory yet: nothing to remove
        }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            do { try fm.removeItem(at: file) } catch { logMemoryFailure("speech cache cleanup failed", error) }
        }
    }
}
