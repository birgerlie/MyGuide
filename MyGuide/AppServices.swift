import Foundation
import MyGuideCore
import os
import SwiftData

/// Builds the network clients and the story flow. The API key is read from the Keychain on every call,
/// so a key saved or removed in Settings takes effect without a relaunch.
@MainActor
final class AppServices {
    nonisolated static let keychainService = "io.github.birgerlie.MyGuide"
    /// The `@AppStorage` key of the story language setting, shared by Settings and the capture screen.
    nonisolated static let storyLanguageKey = "storyLanguage"
    nonisolated static let apiKeyAccount = "openai-api-key"

    nonisolated static let memoryLog = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "memory")

    let keychain = KeychainStore(service: AppServices.keychainService)
    /// The one memory store, over the app's main context. Story saving, priors and History all share it.
    let memory: MemoryStore
    /// The Walking check model lives here, not in its view, so a running check survives leaving the screen
    /// (the owner locks the phone and walks) and notification actions still find it.
    let walkingCheck = WalkingCheckModel()
    private let http: HTTPClient = URLSessionHTTPClient()

    /// False when the persistent store could not be opened and memory is held in RAM only.
    let memoryIsPersistent: Bool

    init(memory: MemoryStore, memoryIsPersistent: Bool = true) {
        self.memory = memory
        self.memoryIsPersistent = memoryIsPersistent
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

    /// Records usage entries with today's prices. A failure is logged and swallowed: counting must never
    /// block or hide a story, and it does not use the save banner.
    func recordUsage(_ entries: [UsageEntry]) {
        do {
            try memory.recordUsage(entries, prices: .current)
        } catch {
            Self.logMemoryFailure("usage record failed", error)
        }
    }

    /// Deletes a history entry (its stories cascade) and, in the same save, its `PlaceRecord` when no other
    /// capture refers to that place (a deleted visit must not linger). Then removes its cached speech files.
    /// On a failed save the context is rolled back and the error rethrown; the cache is left alone.
    func deleteHistoryEntry(_ record: CaptureRecord) throws {
        let id = record.id
        let placeID = record.placeID
        let context = memory.context
        do {
            context.delete(record)
            if let placeID {
                let others = FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.placeID == placeID && $0.id != id })
                if try context.fetchCount(others) == 0, let place = try memory.place(id: placeID) {
                    context.delete(place)
                }
            }
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
        let prefix = sessionID.uuidString + "-"
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: speechCacheDirectory, includingPropertiesForKeys: nil)
        } catch {
            let ns = error as NSError
            let missing = (ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError))
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            // No cache directory yet means nothing to remove; anything else is worth a log line.
            if !missing { logMemoryFailure("speech cache listing failed", error) }
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            do { try fm.removeItem(at: file) } catch { logMemoryFailure("speech cache cleanup failed", error) }
        }
    }
}
