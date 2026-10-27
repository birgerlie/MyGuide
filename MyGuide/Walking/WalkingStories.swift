import Foundation
import MyGuideCore
import Observation
import UIKit

/// Walking stories on the phone (design 7.5): prepared when a buzz goes out, played on "Tell me", continued on
/// "More", retired on "Skip". Feeds `WalkingPlayback` and carries out its effects; the controller learns when it is
/// busy (no buzz meanwhile), when a place is heard and when one is skipped. It keeps working while walking mode is
/// off, so a late "Tell me" still plays.
@MainActor
@Observable
final class WalkingStories {
    /// The level in the player; `isLoading` while its speech is still being fetched.
    struct Listening: Equatable {
        var id: UUID
        var level: Int
        var isLoading: Bool
    }

    struct Failure: Equatable {
        var id: UUID
        var message: String
    }

    static let goneText = "That story is no longer available."
    /// Failures remembered for a later "Tell me" on the same buzz.
    private static let errorLimit = 10

    private(set) var prepared = PreparedWalkStories()
    private(set) var listening: Listening?
    /// The story last made ready or played; the panel shows it when nothing is playing. Cleared by a skip and by
    /// `stopAll()`.
    private(set) var featuredID: UUID?
    private(set) var preparing: Set<UUID> = []
    private(set) var fetchingMore: Set<UUID> = []
    /// The last failure reported, shown on that story's screen.
    private(set) var lastFailure: Failure?
    /// The story the owner asked to open; the capture screen shows it and clears this when it is closed.
    var openID: UUID?
    private(set) var playback = WalkingPlayback()

    /// Called after every playback event with `playback.isBusy`.
    @ObservationIgnored var onBusyChanged: ((Bool) -> Void)?
    /// A place was heard (a level of its story started playing): it never buzzes again.
    @ObservationIgnored var onHeard: ((String) -> Void)?
    /// A buzz was skipped: its id, its place when known, and the deepest level played.
    @ObservationIgnored var onRetire: ((UUID, Candidate?, Int) -> Void)?
    /// The trip new stories are saved in.
    @ObservationIgnored var currentTripID: (() -> UUID?)?

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let makeFlow: @MainActor () throws -> WalkingStoryFlow
    @ObservationIgnored private let makeSpeech: @MainActor () throws -> SpeechService
    @ObservationIgnored private let recordUsage: @MainActor ([UsageEntry]) -> Void
    @ObservationIgnored private let audio = AudioPlayer()
    @ObservationIgnored private var prepareTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var moreTasks: [UUID: Task<Void, Never>] = [:]
    /// Fetches the speech of a level that has no audio file yet, then plays it.
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// The level the story screen's "Tell me more" asked for; the notification's "More" plays the level after the
    /// deepest one heard.
    @ObservationIgnored private var moreTargets: [UUID: Int] = [:]
    @ObservationIgnored private var errors: [(id: UUID, error: Error)] = []

    init(memory: MemoryStore, makeFlow: @escaping @MainActor () throws -> WalkingStoryFlow,
         makeSpeech: @escaping @MainActor () throws -> SpeechService,
         recordUsage: @escaping @MainActor ([UsageEntry]) -> Void) {
        self.memory = memory
        self.makeFlow = makeFlow
        self.makeSpeech = makeSpeech
        self.recordUsage = recordUsage
        audio.onFinish = { [weak self] ending in self?.audioEnded(ending) }
    }

    var isBusy: Bool { playback.isBusy }

    func story(_ id: UUID) -> WalkStory? { prepared.story(id) }

    /// The story the panel shows: the one in the player, else the one last made ready or played.
    var featuredStory: WalkStory? {
        listening.flatMap { prepared.story($0.id) } ?? featuredID.flatMap(prepared.story)
    }

    func isPreparing(_ id: UUID) -> Bool { preparing.contains(id) }

    /// True when "More" would fetch or play another level now.
    func canMore(_ id: UUID) -> Bool {
        playback.hasStory(id) && !fetchingMore.contains(id) && !preparing.contains(id)
            && (playback.deepestLevel(id) ?? 1) < StoryLevel.allCases.count
    }

    /// The story as saved in memory; nil when unknown or unreadable (logged).
    func storedStory(_ id: UUID) -> WalkStory? {
        do {
            return try memory.walkStory(id: id)
        } catch {
            AppServices.logMemoryFailure("walk story load failed", error)
            return nil
        }
    }

    // MARK: - Commands

    /// Prepares the story for a buzz that was just posted: text, then speech for level 1, under a background task.
    /// Always ends with `storyReady` or `storyFailed`, also when cancelled.
    func prepare(_ buzz: Buzz, position: Coordinate, course: Double?, nearby: [WalkingPlace], language: StoryLanguage) {
        let id = buzz.id
        let tripID = currentTripID?()
        feed(.buzzSent(id))
        preparing.insert(id)
        prepareTasks[id] = runInBackground("MyGuide walk story") { [weak self] in
            guard let self else { return }
            do {
                let flow = try makeFlow()
                let (story, usage) = try await flow.buzzStory(buzz, position: position, course: course,
                                                              nearby: nearby, language: language)
                // Paid calls are counted even when the story is no longer wanted.
                recordUsage(usage)
                try Task.checkCancellation()
                // Saved before the speech, so the text survives a speech failure (the story screen shows it, and a
                // later "Tell me" only fetches the speech again). Saving never marks the place heard.
                save(story, tripID: tripID)
                prepared.store(story)
                let url = try await speechFile(for: story, level: 1)
                try Task.checkCancellation()
                prepared.setAudio(url, id: id, level: 1)
                endPreparing(id, with: .storyReady(id))
            } catch {
                remember(Task.isCancelled ? CancellationError() : error, for: id)
                endPreparing(id, with: .storyFailed(id))
            }
        }
    }

    func tellMe(_ id: UUID) {
        dispatch(.tellMe(id), for: id)
    }

    /// The next part. From the story screen, `afterLevels` is the number of levels it shows, so the level after
    /// them is fetched; otherwise (notification, panel) the level after the deepest one heard.
    func more(_ id: UUID, afterLevels: Int? = nil) {
        if let afterLevels { moreTargets[id] = afterLevels + 1 }
        dispatch(.more(id), for: id)
        // Used by `fetchMore` when the machine accepted; dropped when it refused.
        moreTargets[id] = nil
    }

    /// Plays one level from the story screen.
    func listen(_ id: UUID, level: Int) {
        dispatch(.listen(id, level: level), for: id)
    }

    /// Stops the audio (the panel's Stop, a speaker button). The story stays ready.
    func stopListening() {
        guard listening != nil || playback.playing != nil else { return }
        stopAudio()
        feed(.stoppedExternally)
    }

    func skip(_ id: UUID) {
        feed(.skip(id))
    }

    func open(_ id: UUID) {
        openID = id
    }

    /// Walking mode is off: cancel what is being prepared or fetched (each still ends with its failure event, which
    /// stays silent) and stop the audio.
    func stopAll() {
        prepareTasks.values.forEach { $0.cancel() }
        moreTasks.values.forEach { $0.cancel() }
        stopListening()
        featuredID = nil
    }

    // MARK: - Playback machine

    /// Feeds an event for a story the machine may have forgotten (relaunch, or more than 20 stories ago). When it
    /// does not know the id but the story is still prepared or in memory, the entry is rebuilt first; only when
    /// neither has it does the machine report the failure.
    private func dispatch(_ event: WalkingPlayback.Event, for id: UUID) {
        if lastFailure?.id == id { lastFailure = nil }
        guard !playback.hasStory(id), let story = prepared.story(id) ?? storedStory(id) else {
            feed(event)
            return
        }
        errors.removeAll { $0.id == id }
        prepared.store(story)
        feed(.buzzSent(id))
        guard case .tellMe = event else {
            // The text is there; levels are spoken when played.
            feed(.storyReady(id))
            feed(event)
            return
        }
        // "Tell me" waits in the machine while level 1's speech is fetched (from the disk cache when still there).
        feed(.tellMe(id))
        preparing.insert(id)
        prepareTasks[id] = runInBackground("MyGuide walk story") { [weak self] in
            guard let self else { return }
            do {
                let url = try await speechFile(for: story, level: 1)
                try Task.checkCancellation()
                prepared.setAudio(url, id: id, level: 1)
                endPreparing(id, with: .storyReady(id))
            } catch {
                remember(Task.isCancelled ? CancellationError() : error, for: id)
                endPreparing(id, with: .storyFailed(id))
            }
        }
    }

    private func feed(_ event: WalkingPlayback.Event) {
        // A skip forgets the story's levels, so read the deepest one first.
        var skippedLevel = 0
        if case .skip(let id) = event { skippedLevel = playback.deepestLevel(id) ?? 0 }
        let effects = playback.handle(event)
        onBusyChanged?(playback.isBusy)
        for effect in effects {
            switch effect {
            case .play(let id, let level): play(id, level: level)
            case .stopAudio: stopAudio()
            case .fetchMore(let id): fetchMore(id)
            case .offerMore(let id): offerMore(id)
            case .retire(let id): retire(id, deepestLevel: skippedLevel)
            case .reportFailure(let id): report(id, error: errors.last { $0.id == id }?.error)
            }
        }
    }

    private func endPreparing(_ id: UUID, with event: WalkingPlayback.Event) {
        prepareTasks[id] = nil
        preparing.remove(id)
        if case .storyReady = event, prepared.story(id) != nil { featuredID = id }
        feed(event)
    }

    private func endFetchingMore(_ id: UUID, with event: WalkingPlayback.Event) {
        moreTasks[id] = nil
        fetchingMore.remove(id)
        feed(event)
    }

    // MARK: - Effects

    /// Plays a level, replacing whatever is playing (also another level of the same story). A level without an
    /// audio file (or whose cached file the system purged) is fetched first.
    private func play(_ id: UUID, level: Int) {
        stopAudio()
        featuredID = id
        if let url = prepared.audio(id, level: level), FileManager.default.fileExists(atPath: url.path) {
            startAudio(url, id: id, level: level)
            return
        }
        let wanted = Listening(id: id, level: level, isLoading: true)
        listening = wanted
        playTask = runInBackground("MyGuide walk audio") { [weak self] in
            guard let self else { return }
            do {
                guard let story = prepared.story(id) ?? storedStory(id),
                      story.levels.indices.contains(level - 1) else { throw StoryGone() }
                let url = try await speechFile(for: story, level: level)
                try Task.checkCancellation()
                if prepared.story(id) == nil { prepared.store(story) }
                prepared.setAudio(url, id: id, level: level)
                guard listening == wanted else { return }
                startAudio(url, id: id, level: level)
            } catch {
                // Our own stop (another level, a skip) is silence.
                guard !Task.isCancelled, listening == wanted else { return }
                listening = nil
                feed(.stoppedExternally)
                report(id, error: error)
            }
        }
    }

    private func startAudio(_ url: URL, id: UUID, level: Int) {
        do {
            try audio.play(url)
        } catch {
            // An unplayable cached file would fail every retry; drop it so the next try refetches.
            try? FileManager.default.removeItem(at: url)
            listening = nil
            feed(.stoppedExternally)
            report(id, error: error)
            return
        }
        listening = Listening(id: id, level: level, isLoading: false)
        markHeard(id, level: level)
    }

    private func stopAudio() {
        playTask?.cancel()
        playTask = nil
        audio.stop()
        listening = nil
    }

    private func audioEnded(_ ending: AudioPlayer.Ending) {
        guard let current = listening, !current.isLoading else { return }
        listening = nil
        switch ending {
        case .completed: feed(.finished(current.id, level: current.level))
        case .failed, .interrupted: feed(.stoppedExternally)
        }
    }

    /// Fetches the next level (or reuses one already in the story, after a relaunch) and its speech.
    /// Always ends with `moreReady` or `moreFailed`, also when cancelled.
    private func fetchMore(_ id: UUID) {
        let target = moreTargets.removeValue(forKey: id) ?? (playback.deepestLevel(id) ?? 1) + 1
        let tripID = currentTripID?()
        fetchingMore.insert(id)
        moreTasks[id] = runInBackground("MyGuide walk story more") { [weak self] in
            guard let self else { return }
            do {
                guard var story = prepared.story(id) ?? storedStory(id) else { throw StoryGone() }
                if story.levels.count < target {
                    let flow = try makeFlow()
                    let (next, usage) = try await flow.continueStory(story)
                    recordUsage(usage)
                    try Task.checkCancellation()
                    story = next
                    save(story, tripID: tripID)
                }
                guard story.levels.count >= target else { throw PhotoStoryError.noFurtherLevel }
                prepared.store(story)
                let url = try await speechFile(for: story, level: target)
                try Task.checkCancellation()
                prepared.setAudio(url, id: id, level: target)
                endFetchingMore(id, with: .moreReady(id, level: target))
            } catch {
                remember(Task.isCancelled ? CancellationError() : error, for: id)
                endFetchingMore(id, with: .moreFailed(id))
            }
        }
    }

    private func offerMore(_ id: UUID) {
        guard let title = (prepared.story(id) ?? storedStory(id))?.title else { return }
        Task {
            do { try await BuzzNotifier.postMore(id: id, title: title) } catch { AppServices.logMemoryFailure("more post failed", error) }
        }
    }

    private func retire(_ id: UUID, deepestLevel: Int) {
        let candidate = (prepared.story(id) ?? storedStory(id))?.place
        // Nothing more for this place: stop its work and take its notifications away.
        prepareTasks[id]?.cancel()
        moreTasks[id]?.cancel()
        prepared.remove(id)
        if featuredID == id { featuredID = nil }
        BuzzNotifier.removeNotifications(for: id)
        onRetire?(id, candidate, deepestLevel)
    }

    /// Posts STORY_FAILED. Our own cancellation is silent; no error means the story is gone.
    private func report(_ id: UUID, error: Error?) {
        let body = error.map { $0 is StoryGone ? Self.goneText : UserFacingMessage.message(for: $0) } ?? Self.goneText
        guard !body.isEmpty else { return }
        lastFailure = Failure(id: id, message: body)
        Task {
            do { try await BuzzNotifier.postFailure(id: id, body: body) } catch { AppServices.logMemoryFailure("failure post failed", error) }
        }
    }

    // MARK: - Helpers

    /// Cached speech is named `<story id>-<level>-<language>.mp3`: `SpeechService` appends the language.
    private func speechFile(for story: WalkStory, level: Int) async throws -> URL {
        guard story.levels.indices.contains(level - 1) else { throw PhotoStoryError.noFurtherLevel }
        let speech = try makeSpeech()
        let (url, usage) = try await speech.audioFile(text: story.levels[level - 1], language: story.language,
                                                      cacheKey: "\(story.id.uuidString)-\(level)")
        // nil is a cache hit: nothing was paid for.
        if let usage { recordUsage([usage]) }
        return url
    }

    /// The buzz is heard from the moment a level starts playing; this retires its place.
    private func markHeard(_ id: UUID, level: Int) {
        guard let story = prepared.story(id), story.kind == .buzz else { return }
        do {
            try memory.setBuzzOutcome(id, .heard, deepestLevel: level, at: .now)
        } catch {
            AppServices.logMemoryFailure("heard outcome failed", error)
        }
        if let placeID = story.place?.id { onHeard?(placeID) }
    }

    /// Saves into `tripID`. Without a trip (a story continued after a relaunch, before walking mode started) the
    /// stored story keeps the trip it was first saved in; a new record would get a trip of its own.
    private func save(_ story: WalkStory, tripID: UUID?) {
        do {
            try memory.saveWalkStory(story, tripID: tripID ?? UUID())
        } catch {
            AppServices.logMemoryFailure("walk story save failed", error)
        }
    }

    private func remember(_ error: Error, for id: UUID) {
        errors.removeAll { $0.id == id }
        errors.append((id, error))
        if errors.count > Self.errorLimit { errors.removeFirst(errors.count - Self.errorLimit) }
    }

    /// Runs `operation` under a UIApplication background task so it finishes with the phone locked. When iOS ends
    /// the background time first, the task is cancelled, which still ends `operation` through its own catch.
    private func runInBackground(_ name: String,
                                 _ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let work = BackgroundWork(name: name)
        let task = Task { @MainActor in
            await operation()
            work.end()
        }
        work.task = task
        return task
    }
}

/// The story is neither prepared nor in memory.
private struct StoryGone: Error {}

/// One UIApplication background task, ended exactly once: by the work or by expiry, whichever comes first.
@MainActor
private final class BackgroundWork {
    var task: Task<Void, Never>?
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.task?.cancel()
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        let ended = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(ended)
    }
}
