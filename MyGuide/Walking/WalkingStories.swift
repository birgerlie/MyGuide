import Foundation
import MyGuideCore
import Observation
import UIKit

/// Walking stories on the phone (design 7.5): prepared when a buzz goes out, played on "Tell me", continued on
/// "More", retired on "Skip". Feeds `WalkingPlayback` and carries out its effects; the controller learns when it is
/// busy (no buzz meanwhile), when a place is heard and when one is skipped. It keeps working while walking mode is
/// off, so a late "Tell me" still plays. It is the one owner of walk-story audio (spec 12.2): a place chosen on the map
/// is told here too, and the map reads which place is playing.
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
    /// The story the owner asked to open; Home pushes it and clears this at once.
    var openID: UUID?
    private(set) var playback = WalkingPlayback()
    /// The place of each story still preparing (its text is not stored yet), so the map finds and shows it.
    private var preparingPlaces: [UUID: String] = [:]

    /// Called after every playback event with `playback.isBusy`.
    @ObservationIgnored var onBusyChanged: ((Bool) -> Void)?
    /// A place was heard (a level of its story started playing): it never buzzes again.
    @ObservationIgnored var onHeard: ((String) -> Void)?
    /// A level of a story about a place chosen on the map started playing; memory has already marked it heard.
    @ObservationIgnored var onChosenHeard: ((Candidate) -> Void)?
    /// A buzz was skipped: its id, its place when known, and the deepest level played.
    @ObservationIgnored var onRetire: ((UUID, Candidate?, Int) -> Void)?
    /// The trip new stories are saved in.
    @ObservationIgnored var currentTripID: (() -> UUID?)?
    /// The places walking mode has now, given to a continuation ("More").
    @ObservationIgnored var currentPlaces: (@MainActor () -> [WalkingPlace])?
    /// The walk log (set by `WalkingController`). It writes nothing while walking mode is off.
    @ObservationIgnored var walkLog: WalkLog?

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let makeFlow: @MainActor () throws -> WalkingStoryFlow
    @ObservationIgnored private let makeSpeech: @MainActor () throws -> SpeechService
    @ObservationIgnored private let recordUsage: @MainActor ([UsageEntry]) -> Void
    @ObservationIgnored private let audio = AudioPlayer()
    @ObservationIgnored private var prepareTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var moreTasks: [UUID: Task<Void, Never>] = [:]
    /// Stop stories being told, by a token of their own.
    @ObservationIgnored private var stopTasks: [UUID: Task<Void, Never>] = [:]
    /// Fetches the speech of a level that has no audio file yet, then plays it.
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Identifies the current `play`; `stopAudio()` clears it, so a fetch whose play was stopped or replaced
    /// (even by a play of the same level) knows it is no longer wanted.
    @ObservationIgnored private var playToken: UUID?
    /// Stories whose prepare or more task the app cancelled itself (skip, walking mode off): their failure is
    /// silent. Any other cancellation (background time ran out) is reported.
    @ObservationIgnored private var ownCancels: Set<UUID> = []
    @ObservationIgnored private var errors: [(id: UUID, error: Error)] = []
    /// When each buzz story started preparing, for the seconds of its `storyReady` or `storyFailed` line.
    @ObservationIgnored private var preparedAt: [UUID: Date] = [:]
    /// The busy flag last written and the run file it went to; a new run writes the flag afresh.
    @ObservationIgnored private var loggedBusy: (run: URL, busy: Bool)?

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

    /// The place whose story is playing or loading (its speech, or its text after a "tell me" or a choice on the map),
    /// for the map card (spec 12.2); nil when none, or for a stop story.
    var playingPlaceID: String? {
        if let listening { return placeID(of: listening.id) }
        if let id = playback.playing?.id ?? playback.waiting { return placeID(of: id) }
        return nil
    }

    /// The story about this place that is preparing or prepared on this run (newest first), e.g. one just buzzed;
    /// nil when none. A skipped story, a preparation that failed before its text and a stop story never match.
    func storyID(forPlace placeID: String) -> UUID? {
        if let id = preparingPlaces.first(where: { $0.value == placeID })?.key { return id }
        return prepared.ids.reversed().first { prepared.story($0)?.place?.id == placeID }
    }

    /// True when "More" would fetch or play another level now.
    func canMore(_ id: UUID) -> Bool {
        playback.hasStory(id) && !fetchingMore.contains(id) && !preparing.contains(id)
            && (playback.deepestLevel(id) ?? 1) < StoryLevel.allCases.count
    }

    /// False when the machine knows the story but not the level's text yet (preparing), so a speaker button would do
    /// nothing. A story the machine does not know is restored when the level is asked for.
    func canListen(_ id: UUID, level: Int) -> Bool {
        !playback.hasStory(id) || level <= playback.storedLevels(id)
    }

    /// The story as saved in memory; nil when unknown or unreadable (logged).
    func storedStory(_ id: UUID) -> WalkStory? {
        do {
            return try memory.walkStory(id: id)
        } catch {
            fail("walk story load failed", error)
            return nil
        }
    }

    // MARK: - Commands

    /// Prepares the story for a buzz that was just posted: text (the flow runs `context`, which may look up the
    /// address, alongside its other fetches), then speech for level 1, under a background task.
    /// Always ends with `storyReady` or `storyFailed`, also when cancelled.
    func prepare(_ buzz: Buzz, position: Coordinate, nearby: [WalkingPlace], language: StoryLanguage,
                 context: @escaping @MainActor @Sendable () async -> WalkContext) {
        startPreparing(buzz, kind: .buzz, event: .buzzSent(buzz.id), position: position, nearby: nearby,
                       language: language, context: context)
    }

    /// Tells a place chosen on the map (spec 12.1): the story already preparing or prepared for it when there is one
    /// (it was just buzzed), else a new `.chosen` story through the buzz pipeline, saved as a walk story; then plays
    /// level 1. Works with walking mode off. Whatever else plays stops at once, and a story waiting for its text no
    /// longer starts. Uses no buzz budget and posts no buzz. When this place is already playing or loading, nothing
    /// changes.
    func tellPlace(_ place: WalkingPlace, position: Coordinate, language: StoryLanguage,
                   context: @escaping @MainActor @Sendable () async -> WalkContext) {
        let placeID = place.candidate.id
        guard playingPlaceID != placeID else { return }
        stopListening()
        if let id = storyID(forPlace: placeID) {
            // Preparing: it plays when ready. Ready (or its text saved but its speech failed): level 1 plays now.
            dispatch(.tellMe(id), for: id)
            return
        }
        let buzz = Buzz(chosen: place, position: position)
        startPreparing(buzz, kind: .chosen, event: .chosenStarted(buzz.id), position: position,
                       nearby: currentPlaces?() ?? [], language: language, context: context)
    }

    /// Text (the flow runs `context` alongside its other fetches), then speech for level 1, under a background task.
    /// `event` puts the story into the playback machine as preparing. Always ends with `storyReady` or `storyFailed`,
    /// also when cancelled.
    private func startPreparing(_ buzz: Buzz, kind: WalkStory.Kind, event: WalkingPlayback.Event, position: Coordinate,
                                nearby: [WalkingPlace], language: StoryLanguage,
                                context: @escaping @MainActor @Sendable () async -> WalkContext) {
        let id = buzz.id
        let tripID = currentTripID?()
        preparingPlaces[id] = buzz.place.candidate.id
        feed(event)
        preparing.insert(id)
        preparedAt[id] = .now
        walkLog?.log(.storyPreparing(id: id))
        prepareTasks[id] = runInBackground("MyGuide walk story") { [weak self] in
            guard let self else { return }
            do {
                let flow = try makeFlow()
                let (story, usage) = try await flow.buzzStory(buzz, position: position, context: context,
                                                              nearby: nearby, language: language, kind: kind)
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
                remember(failure(error, for: id), for: id)
                endPreparing(id, with: .storyFailed(id))
            }
        }
    }

    /// Tells the story for the spot where the walker has stopped: gets the walk context (its address is nil on a
    /// failed or timed-out lookup), writes the text, records the usage and saves the story. `ready` is called with the
    /// saved story. When the flow finds nothing worth telling (spec 9 step 4) it ends silently: no `ready`, nothing
    /// saved, no usage (none was spent). A failure is only logged: a stop story is a lock-screen extra, nobody asked
    /// for it.
    func prepareStop(position: Coordinate, nearby: [WalkingPlace], language: StoryLanguage,
                     context: @escaping @MainActor () async -> WalkContext,
                     ready: @escaping @MainActor (WalkStory) -> Void) {
        let tripID = currentTripID?()
        let token = UUID()
        stopTasks[token] = runInBackground("MyGuide stop story") { [weak self] in
            guard let self else { return }
            defer { stopTasks[token] = nil }
            do {
                let flow = try makeFlow()
                let walk = await context()
                try Task.checkCancellation()
                guard let told = try await flow.stopStory(position: position, context: walk, nearby: nearby,
                                                          language: language) else {
                    walkLog?.log(.stopStory(outcome: .silent, title: nil, error: nil))
                    return
                }
                let (story, usage) = told
                // Paid calls are counted even when the story is no longer wanted.
                recordUsage(usage)
                try Task.checkCancellation()
                save(story, tripID: tripID)
                prepared.store(story)
                walkLog?.log(.stopStory(outcome: .told, title: story.title, error: nil))
                ready(story)
            } catch is CancellationError {
                // Walking mode went off meanwhile: silent (and the run's log has ended, so this writes nothing then).
                walkLog?.log(.stopStory(outcome: .failed, title: nil, error: "cancelled"))
            } catch {
                // Memory log, and the walk log's `stopStory` line (no `failure` line beside it).
                AppServices.logMemoryFailure("stop story failed", error)
                walkLog?.log(.stopStory(outcome: .failed, title: nil, error: WalkLogEvent.errorText(error)))
            }
        }
    }

    func tellMe(_ id: UUID) {
        dispatch(.tellMe(id), for: id)
    }

    /// The next part: the level after the deepest one heard, played from storage when its text exists.
    func more(_ id: UUID) {
        dispatch(.more(id), for: id)
    }

    /// Plays one level from the story screen or the map. Level 1 of a story still preparing plays when its text is
    /// ready, as after "tell me". A level that starts replaces whatever plays (one audio).
    func listen(_ id: UUID, level: Int) {
        if level == 1, preparing.contains(id) {
            stopListening()
            dispatch(.tellMe(id), for: id)
            return
        }
        dispatch(.listen(id, level: level), for: id)
    }

    /// Stops the audio (the panel's Stop, a speaker button), and a story waiting for its text no longer starts. The
    /// story stays ready.
    func stopListening() {
        guard listening != nil || playback.playing != nil || playback.waiting != nil else { return }
        stopAudio()
        feed(.stoppedExternally)
    }

    /// A skip on a stop story (a stale button or command) does nothing: there is no place to retire.
    func skip(_ id: UUID) {
        if let story = prepared.story(id) ?? storedStory(id), !story.canSkip { return }
        feed(.skip(id))
    }

    func open(_ id: UUID) {
        openID = id
    }

    /// Walking mode is off: cancel what is being prepared or fetched (each still ends with its failure event, which
    /// stays silent) and stop the audio.
    func stopAll() {
        for (id, task) in prepareTasks { cancelOwn(id, task) }
        for (id, task) in moreTasks { cancelOwn(id, task) }
        for task in stopTasks.values { task.cancel() }
        stopListening()
        featuredID = nil
    }

    // MARK: - Playback machine

    /// Feeds an event for a story the machine may have forgotten (relaunch, or more than 20 stories ago). When it
    /// does not know the id but the story is still prepared or in memory, the entry is restored first with its
    /// stored levels and the deepest level heard (from the buzz log), so "More" continues where the owner left off;
    /// only when neither has it does the machine report the failure. A level without an audio file has its speech
    /// fetched when it plays (from the disk cache when still there).
    private func dispatch(_ event: WalkingPlayback.Event, for id: UUID) {
        if lastFailure?.id == id { lastFailure = nil }
        guard !playback.hasStory(id), let story = prepared.story(id) ?? storedStory(id) else {
            feed(event)
            return
        }
        errors.removeAll { $0.id == id }
        prepared.store(story)
        feed(.restored(id, storedLevels: story.levels.count, deepestHeard: deepestHeard(id)))
        feed(event)
    }

    private func feed(_ event: WalkingPlayback.Event) {
        // A skip forgets the story's levels, so read the deepest one first.
        var skippedLevel = 0
        if case .skip(let id) = event { skippedLevel = playback.deepestLevel(id) ?? 0 }
        let effects = playback.handle(event)
        onBusyChanged?(playback.isBusy)
        logBusy()
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
        preparingPlaces[id] = nil
        let seconds = preparedAt.removeValue(forKey: id).map { max(0, Date.now.timeIntervalSince($0)) } ?? 0
        switch event {
        case .storyReady:
            walkLog?.log(.storyReady(id: id, seconds: seconds))
        case .storyFailed:
            let error = errors.last { $0.id == id }?.error
            let text = error.map { $0 is CancellationError ? "cancelled" : WalkLogEvent.errorText($0) } ?? "unknown"
            walkLog?.log(.storyFailed(id: id, seconds: seconds, error: text))
        default:
            break
        }
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
        let token = UUID()
        playToken = token
        listening = Listening(id: id, level: level, isLoading: true)
        playTask = runInBackground("MyGuide walk audio") { [weak self] in
            guard let self else { return }
            do {
                guard let story = prepared.story(id) ?? storedStory(id),
                      story.levels.indices.contains(level - 1) else { throw StoryGone() }
                let url = try await speechFile(for: story, level: level)
                try Task.checkCancellation()
                if prepared.story(id) == nil { prepared.store(story) }
                prepared.setAudio(url, id: id, level: level)
                guard playToken == token else { return }
                startAudio(url, id: id, level: level)
            } catch {
                // Our own stop (another level, a skip, Stop) has already cleared the token: silence. Anything else,
                // an expired background task included, must free the machine and be reported.
                guard playToken == token else { return }
                playToken = nil
                listening = nil
                let reported = unrequested(error)
                logFailure("story speech failed", reported)
                feed(.stoppedExternally)
                report(id, error: reported)
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
            logFailure("story audio failed", error)
            feed(.stoppedExternally)
            report(id, error: error)
            return
        }
        listening = Listening(id: id, level: level, isLoading: false)
        markHeard(id, level: level)
    }

    private func stopAudio() {
        playToken = nil
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
        let target = playback.fetchingLevel(id) ?? (playback.deepestLevel(id) ?? 1) + 1
        let tripID = currentTripID?()
        fetchingMore.insert(id)
        moreTasks[id] = runInBackground("MyGuide walk story more") { [weak self] in
            guard let self else { return }
            do {
                guard var story = prepared.story(id) ?? storedStory(id) else { throw StoryGone() }
                if story.levels.count < target {
                    let flow = try makeFlow()
                    let (next, usage) = try await flow.continueStory(story, nearby: currentPlaces?() ?? [])
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
                let reported = failure(error, for: id)
                // The app's own cancellation (a skip, walking mode off) is silent.
                if !(reported is CancellationError) { logFailure("story more failed", reported) }
                remember(reported, for: id)
                // The new level's text may be saved although its speech failed: it stays listenable.
                endFetchingMore(id, with: .moreFailed(id, storedLevels: prepared.story(id)?.levels.count ?? 0))
            }
        }
    }

    private func offerMore(_ id: UUID) {
        guard let title = (prepared.story(id) ?? storedStory(id))?.title else { return }
        Task {
            do {
                try await posting(.more, id: id) { try await BuzzNotifier.postMore(id: id, title: title) }
            } catch {
                // Memory log only: the walk log's `notifyFailed` line already holds the error.
                AppServices.logMemoryFailure("more post failed", error)
            }
        }
    }

    private func retire(_ id: UUID, deepestLevel: Int) {
        let story = prepared.story(id) ?? storedStory(id)
        // `skip` already refuses stop stories; never retire (or start the skip pause) for one.
        if let story, !story.canSkip { return }
        let candidate = story?.place
        // Nothing more for this place: stop its work and take its notifications away.
        if let task = prepareTasks[id] { cancelOwn(id, task) }
        if let task = moreTasks[id] { cancelOwn(id, task) }
        prepared.remove(id)
        // Its cancelled preparation may still be running: the map must not find it meanwhile.
        preparingPlaces[id] = nil
        if featuredID == id { featuredID = nil }
        BuzzNotifier.removeNotifications(for: id)
        onRetire?(id, candidate, deepestLevel)
    }

    /// Posts STORY_FAILED. Our own cancellation (a `CancellationError`) is silent; no error means the story is gone.
    private func report(_ id: UUID, error: Error?) {
        let body: String
        if let error, !(error is StoryGone) {
            body = error is UnrequestedCancellation
                ? StoryViewModel.unexpectedCancellationText : UserFacingMessage.message(for: error)
        } else {
            body = Self.goneText
        }
        guard !body.isEmpty else { return }
        lastFailure = Failure(id: id, message: body)
        Task {
            do {
                try await posting(.storyFailed, id: id) { try await BuzzNotifier.postFailure(id: id, body: body) }
            } catch {
                // Memory log only: the walk log's `notifyFailed` line already holds the error.
                AppServices.logMemoryFailure("failure post failed", error)
            }
        }
    }

    // MARK: - Helpers

    /// Logs a failure without any story text: to the memory log, and to the walk log while a run is on.
    private func fail(_ context: String, _ error: Error) {
        AppServices.logMemoryFailure(context, error)
        logFailure(context, error)
    }

    /// Writes `failure` to the walk log while a run is on (a playback failure, which is no memory failure).
    private func logFailure(_ context: String, _ error: Error) {
        walkLog?.log(.failure(context: context, error: WalkLogEvent.errorText(error)))
    }

    /// Writes the busy flag to a run's log right after its `started` line: a story from before the run may hold the
    /// engine busy, and `busy` is otherwise only written when a playback event comes.
    func logBusyState() {
        logBusy()
    }

    /// Writes `busy` when the flag differs from the last one written to this run's file.
    private func logBusy() {
        guard let walkLog, let run = walkLog.currentURL else { return }
        let busy = playback.isBusy
        if let loggedBusy, loggedBusy.run == run, loggedBusy.busy == busy { return }
        loggedBusy = (run, busy)
        walkLog.log(.busy(busy))
    }

    /// Posts through the walk log, which records `notified` or `notifyFailed`.
    private func posting(_ kind: WalkNotificationKind, id: UUID, _ post: @MainActor () async throws -> Void) async throws {
        if let walkLog {
            try await walkLog.posting(kind, id: id, post)
        } else {
            try await post()
        }
    }

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

    /// The buzz is heard from the moment a level starts playing; this retires its place. When the buzz was never
    /// logged (`recordBuzz` failed), the place is marked heard from the story, so the listen is not lost. A chosen
    /// place has no buzz record (it never counts against the buzz budget): its place is marked heard directly.
    private func markHeard(_ id: UUID, level: Int) {
        guard let story = prepared.story(id) else { return }
        let now = Date.now
        switch story.kind {
        case .stop:
            return
        case .chosen:
            guard let candidate = story.place else { return }
            do { try memory.markHeard(candidate, level: level, at: now) } catch { fail("heard failed", error) }
            onChosenHeard?(candidate)
            return
        case .buzz:
            break
        }
        do {
            try memory.setBuzzOutcome(id, .heard, deepestLevel: level, at: now)
        } catch MemoryError.corruptRecord {
            if let candidate = story.place {
                do { try memory.markHeard(candidate, level: level, at: now) } catch { fail("heard failed", error) }
            } else {
                fail("heard outcome failed", MemoryError.corruptRecord)
            }
        } catch {
            fail("heard outcome failed", error)
        }
        if let placeID = story.place?.id { onHeard?(placeID) }
    }

    /// Saves into `tripID`. Without a trip (a story continued after a relaunch, before walking mode started) the
    /// stored story keeps the trip it was first saved in; a new record would get a trip of its own.
    private func save(_ story: WalkStory, tripID: UUID?) {
        do {
            try memory.saveWalkStory(story, tripID: tripID ?? UUID())
            LatestStoryRef.record(.walk(story.id))
        } catch {
            fail("walk story save failed", error)
        }
    }

    /// The deepest level heard for a buzz, from the buzz log; 0 for none, a stop story or an unreadable log.
    private func deepestHeard(_ id: UUID) -> Int {
        do {
            return try memory.deepestLevelHeard(buzzID: id) ?? 0
        } catch {
            fail("deepest level lookup failed", error)
            return 0
        }
    }

    /// The place of a buzz or chosen story, prepared or still preparing; nil for a stop story or an unknown id.
    private func placeID(of id: UUID) -> String? {
        prepared.story(id)?.place?.id ?? preparingPlaces[id]
    }

    private func cancelOwn(_ id: UUID, _ task: Task<Void, Never>) {
        ownCancels.insert(id)
        task.cancel()
    }

    /// The error a prepare or more task ends with: silent `CancellationError` when the app cancelled it itself,
    /// otherwise a cancellation counts as an unrequested failure.
    private func failure(_ error: Error, for id: UUID) -> Error {
        if ownCancels.remove(id) != nil { return CancellationError() }
        return unrequested(error)
    }

    /// A cancellation the app did not ask for (background time ran out, the system) is a visible failure.
    private func unrequested(_ error: Error) -> Error {
        Task.isCancelled || error is CancellationError ? UnrequestedCancellation() : error
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

/// Work for a story the owner asked for was cancelled, but not by the app.
private struct UnrequestedCancellation: Error {}

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
