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
    /// The one WatchConnectivity link. Messages from the watch reach the Walking check through it.
    let watchLink = WatchLink()
    /// The diary's import and day story writes, kept here so they survive a walk story pushed over their screens.
    let diary = DiaryWork()
    private let http: HTTPClient = URLSessionHTTPClient()
    /// The one Wikipedia article text cache, for the app's lifetime: photo and walking stories share it.
    private let articles: ArticleTextCache
    /// The one camera. It lives here, not in the camera screen, so exactly one capture session exists however
    /// often SwiftUI rebuilds the pushed screen, and the preview always shows the session that runs. Home starts
    /// and stops it by what is on top of its stack.
    let camera = CameraController()

    /// The one walking-mode controller. It lives here so walking continues with the phone locked and
    /// notification actions still find it.
    let walking: WalkingController
    /// The walk log of walking mode: the run in progress and where the run files live.
    let walkLog = WalkLog()

    /// False when the persistent store could not be opened and memory is held in RAM only.
    let memoryIsPersistent: Bool

    init(memory: MemoryStore, memoryIsPersistent: Bool = true) {
        self.memory = memory
        self.memoryIsPersistent = memoryIsPersistent
        let http = http
        let keychain = keychain
        let walkLog = walkLog
        let articles = ArticleTextCache(client: WikipediaClient(http: http))
        self.articles = articles
        let stories = WalkingStories(
            memory: memory,
            makeFlow: {
                try Self.walkingFlow(openAI: Self.openAI(keychain: keychain, http: http), memory: memory,
                                     articles: articles)
            },
            makeSpeech: { try Self.speech(openAI: Self.openAI(keychain: keychain, http: http)) },
            recordUsage: { Self.recordUsage($0, memory: memory) })
        walking = WalkingController(
            memory: memory,
            stories: stories,
            walkLog: walkLog,
            makeSource: { Self.walkingSource(http: http) },
            hasAPIKey: { ((try? keychain.read(Self.apiKeyAccount)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
        let walkingCheck = walkingCheck
        watchLink.onMessage = { message in
            if message["type"] as? String == "check.tell" { walkingCheck.handleWatchTell() }
            return [:]
        }
        watchLink.activate()
    }

    /// Logs a memory failure without any story text: only the error's type, and domain and code when it has them.
    nonisolated static func logMemoryFailure(_ what: String, _ error: Error) {
        let ns = error as NSError
        memoryLog.error("\(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public) \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
    }

    /// Throws `OpenAIError.missingAPIKey` when no non-blank key is stored; Keychain failures propagate.
    func makeOpenAI() throws -> OpenAIClient {
        try Self.openAI(keychain: keychain, http: http)
    }

    private static func openAI(keychain: KeychainStore, http: HTTPClient) throws -> OpenAIClient {
        let key = try keychain.read(apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw OpenAIError.missingAPIKey }
        return OpenAIClient(apiKey: key, http: http)
    }

    /// The place source for walking mode: the same shared OSM and Wikipedia clients as phase 1.
    func makeWalkingSource() -> WalkingPlaceSource {
        Self.walkingSource(http: http)
    }

    private static func walkingSource(http: HTTPClient) -> WalkingPlaceSource {
        WalkingPlaceSource(overpass: OverpassClient(http: http), wikipedia: WikipediaClient(http: http))
    }

    /// Generated speech lives in Caches: it can be regenerated, so the system may purge it.
    static var speechCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "Speech", directoryHint: .isDirectory)
    }

    /// Throws `OpenAIError.missingAPIKey` when no non-blank key is stored.
    func makeSpeech() throws -> SpeechService {
        Self.speech(openAI: try makeOpenAI())
    }

    private static func speech(openAI: OpenAIClient) -> SpeechService {
        SpeechService(openAI: openAI, cacheDirectory: speechCacheDirectory)
    }

    /// Throws `OpenAIError.missingAPIKey` when no key is stored.
    func makeWalkingFlow() throws -> WalkingStoryFlow {
        Self.walkingFlow(openAI: try makeOpenAI(), memory: memory, articles: articles)
    }

    /// Walking stories get the same memory, Apple Maps places and article texts as photo stories.
    private static func walkingFlow(openAI: OpenAIClient, memory: MemoryStore,
                                    articles: ArticleTextCache) -> WalkingStoryFlow {
        WalkingStoryFlow(openAI: openAI, priors: priorLookup(memory: memory), recent: recentLookup(memory: memory),
                         pointsOfInterest: MapKitPointsOfInterest(), articles: articles)
    }

    /// Throws `OpenAIError.missingAPIKey` when no key is stored.
    func makeFlow() throws -> PhotoStoryFlow {
        let openAI = try makeOpenAI()
        let grounding = GroundingService(overpass: OverpassClient(http: http),
                                         wikipedia: WikipediaClient(http: http),
                                         geocoder: MapKitReverseGeocoder())
        return PhotoStoryFlow(grounding: grounding, openAI: openAI, priors: Self.priorLookup(memory: memory),
                              recent: Self.recentLookup(memory: memory), pointsOfInterest: MapKitPointsOfInterest(),
                              articles: articles)
    }

    /// Throws `OpenAIError.missingAPIKey` when no key is stored. Photos are read from memory on the main actor.
    func makeDayStoryFlow() throws -> DayStoryFlow {
        let memory = memory
        return DayStoryFlow(openAI: try makeOpenAI()) { id in
            await MainActor.run { Self.photoJPEG(id: id, memory: memory) }
        }
    }

    /// The stored full-size JPEG of a diary photo (`capture:<uuid>` or `library:<uuid>`); nil when the photo is gone,
    /// the id is malformed or memory fails (logged).
    func photoJPEG(id: String) -> Data? {
        Self.photoJPEG(id: id, memory: memory)
    }

    private static func photoJPEG(id: String, memory: MemoryStore) -> Data? {
        do {
            switch DiaryPhotoID(id) {
            case .capture(let uuid):
                var descriptor = FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.id == uuid })
                descriptor.fetchLimit = 1
                return try memory.context.fetch(descriptor).first?.photoJPEG
            case .library(let uuid):
                return try memory.libraryPhoto(id: uuid)?.photoJPEG
            case nil:
                return nil
            }
        } catch {
            logMemoryFailure("diary photo load failed", error)
            return nil
        }
    }

    /// A memory failure must never block a story: it is logged and the flow is told there are no priors.
    private static func priorLookup(memory: MemoryStore) -> PriorStoryLookup {
        { placeIDs, near, excluding in
            await MainActor.run {
                do {
                    return try memory.priorStories(placeIDs: placeIDs, near: near, excludingSession: excluding)
                } catch {
                    AppServices.logMemoryFailure("priors lookup failed", error)
                    return []
                }
            }
        }
    }

    /// Likewise for the stories told lately: a memory failure is logged and the flow is told there are none.
    private static func recentLookup(memory: MemoryStore) -> RecentStoryLookup {
        { since, excluding in
            await MainActor.run {
                do {
                    return try memory.recentStories(since: since, excludingSession: excluding)
                } catch {
                    AppServices.logMemoryFailure("recent stories lookup failed", error)
                    return []
                }
            }
        }
    }

    /// Records usage entries with today's prices. A failure is logged and swallowed: counting must never
    /// block or hide a story, and it does not use the save banner.
    func recordUsage(_ entries: [UsageEntry]) {
        Self.recordUsage(entries, memory: memory)
    }

    private static func recordUsage(_ entries: [UsageEntry], memory: MemoryStore) {
        do {
            try memory.recordUsage(entries, prices: .current)
        } catch {
            logMemoryFailure("usage record failed", error)
        }
    }

    /// Deletes a history entry (its stories cascade) and, in the same save, its `PlaceRecord` when nothing else needs
    /// it (`MemoryStore.deleteCapture`: walking mode's skip and heard flags live on the place). Then removes its cached
    /// speech files. On a failed save the context is rolled back and the error rethrown; the cache is left alone.
    func deleteHistoryEntry(_ record: CaptureRecord) throws {
        let id = record.id
        do {
            try memory.deleteCapture(record)
        } catch {
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
