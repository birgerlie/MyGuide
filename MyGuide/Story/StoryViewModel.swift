import Foundation
import MyGuideCore
import Observation
import UIKit

/// State machine for one photo's story. The photo and capture are kept so Retry never loses them.
@MainActor
@Observable
final class StoryViewModel {
    enum State {
        case working(String)
        case showing
        case failed(message: String, canUseCurrentPosition: Bool)
    }

    /// Progress of the "Tell me more" request; the earlier levels stay visible in every case.
    enum MoreState: Equatable {
        case idle
        case working
        case failed(message: String)
    }

    /// Progress of the "Show me how it looked" image; the story text stays visible in every case.
    enum ThenState: Equatable {
        case idle
        case working
        case showing
        case failed(message: String)
    }

    /// Progress of the spoken version of one level.
    enum SpeechState: Equatable {
        case idle
        case loading
        case playing
        /// `message` is set only for errors where Retry cannot help (bad key, no credit, retired model).
        case failed(message: String?)
    }

    static let workingText = "Looking around…"
    static let unexpectedCancellationText = "Something went wrong. Try again."

    var state: State = .working(StoryViewModel.workingText)
    var session: StorySession?
    var moreState: MoreState = .idle
    var thenState: ThenState = .idle
    /// The decoded "then" image, kept so the view never decodes PNG data during body evaluation.
    private(set) var thenImage: UIImage?
    /// True when the last save to memory failed. The story stays visible; the view shows a small banner.
    var saveFailed = false
    /// Speech state per level index; a missing entry means idle. At most one level is not idle at a time.
    private(set) var speech: [Int: SpeechState] = [:]

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var capture: CaptureContext?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var thenTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    /// Keeps a first story (through its level 1 audio fetch) or a continuation running if the phone is locked
    /// mid-request. At most one is held; `.invalid` when none.
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Language for a first story; read when the photo is taken or picked. Stored sessions keep their own.
    @ObservationIgnored private var newSessionLanguage: StoryLanguage = .english
    @ObservationIgnored private let audio = AudioPlayer()

    init(services: AppServices, language: StoryLanguage = .english) {
        self.services = services
        self.newSessionLanguage = language
        audio.onFinish = { [weak self] _ in self?.speech = [:] }
    }

    /// Opens a stored session from History: shows its levels at once, with no auto-play. Speech cache keys use
    /// the stored session id, so cached audio is reused, and "Tell me more" continues from the stored levels.
    init(session: StorySession, services: AppServices) {
        self.services = services
        self.session = session
        self.state = .showing
        loadStoredThenImage(sessionID: session.id)
        audio.onFinish = { [weak self] _ in self?.speech = [:] }
    }

    // Backstop: work for a dropped screen must not keep running (the owner normally calls cancel()).
    isolated deinit {
        task?.cancel()
        thenTask?.cancel()
        speechTask?.cancel()
        audio.stop()
        endBackgroundWork()
    }

    func start(photoJPEG: Data, capture: CaptureContext) {
        self.photoJPEG = photoJPEG
        self.capture = capture
        run()
    }

    /// Re-runs with the same photo and capture.
    func retry() {
        run()
    }

    /// Replaces the capture's position (clearing its heading) and runs again.
    func useCurrentPosition(_ coordinate: Coordinate, accuracy: Double?) {
        guard let capture else { return }
        self.capture = capture.withCoordinate(coordinate, accuracy: accuracy)
        run()
    }

    /// Asks for the next level. Ignored while a request is already running or when no level is left.
    /// Uses the same `task` as the first story, so `cancel()` and a dropped screen stop it too.
    func tellMore() {
        guard let current = session, current.nextLevel != nil, moreState != .working else { return }
        moreState = .working
        task?.cancel()
        let background = beginBackgroundWork()
        task = Task { [weak self, services] in
            defer { self?.endBackgroundWork(background) }
            do {
                let flow = try services.makeFlow()
                let (next, usage) = try await flow.continueStory(current)
                services.recordUsage(usage)
                guard !Task.isCancelled, let self else { return }
                self.session = next
                self.moreState = .idle
                self.persist(next)
                self.playSpeech(level: next.levels.count - 1)
            } catch {
                // Our own cancel is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                self.moreState = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message)
            }
        }
    }

    /// Stops in-flight work silently; called when the story screen is dropped (navigated back).
    func cancel() {
        task?.cancel()
        task = nil
        thenTask?.cancel()
        thenTask = nil
        stopSpeech()
        endBackgroundWork()
        if moreState == .working { moreState = .idle }
        if thenState == .working { thenState = .idle }
    }

    private func run() {
        guard let photoJPEG, let capture else { return }
        task?.cancel()
        stopSpeech()
        thenTask?.cancel()
        thenTask = nil
        thenState = .idle
        thenImage = nil
        session = nil
        moreState = .idle
        saveFailed = false
        state = .working(Self.workingText)
        let language = newSessionLanguage
        let background = beginBackgroundWork()
        task = Task { [weak self, services] in
            // On success the level 1 audio fetch takes over the background task and ends it.
            var handedToSpeech = false
            defer { if !handedToSpeech { self?.endBackgroundWork(background) } }
            do {
                let flow = try services.makeFlow()
                let (session, usage) = try await flow.tellFirstStory(photoJPEG: photoJPEG, capture: capture,
                                                                     language: language)
                // Paid calls are counted even if the screen was dropped meanwhile.
                services.recordUsage(usage)
                guard !Task.isCancelled, let self else { return }
                self.session = session
                self.state = .showing
                self.persist(session)
                // The text is already on screen; audio follows and never delays it.
                handedToSpeech = true
                self.playSpeech(level: 0, backgroundWork: background)
            } catch {
                // Our own cancel (or a superseding run) is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                // A CancellationError we did not ask for must not leave the spinner up with no way out.
                self.state = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message,
                                     canUseCurrentPosition: (error as? PhotoStoryError) == .noPosition)
            }
        }
    }

    /// Saves after every successful level. A failure is logged (no story text) and flagged for the banner;
    /// it never touches the story on screen.
    private func persist(_ session: StorySession) {
        do {
            try services.memory.save(session)
            saveFailed = false
        } catch {
            AppServices.logMemoryFailure("save failed", error)
            saveFailed = true
        }
        // A story about a matched place retires it from walking mode, saved or not.
        if let placeID = session.matchedCandidate?.candidate.id { services.walking.noteHeard(placeID: placeID) }
    }

    // MARK: - "Then" image

    /// Generates the labelled AI reconstruction. Ignored while a request runs or once the image is shown.
    /// Runs on its own task so "Tell me more" and the image never cancel each other; `cancel()` stops it silently.
    func showThen() {
        guard let current = session, thenState != .working, thenState != .showing else { return }
        thenState = .working
        thenTask?.cancel()
        thenTask = Task { [weak self, services] in
            do {
                let flow = try services.makeFlow()
                let (png, usage) = try await flow.thenImage(for: current)
                services.recordUsage([usage])
                guard !Task.isCancelled, let self else { return }
                guard let image = UIImage(data: png) else { throw OpenAIError.malformedResponse }
                self.thenImage = image
                self.thenState = .showing
                do {
                    try self.services.memory.saveThenImage(png, sessionID: current.id)
                } catch {
                    AppServices.logMemoryFailure("then image save failed", error)
                    self.saveFailed = true
                }
            } catch {
                // Our own cancel is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                let message = UserFacingMessage.message(for: error)
                self.thenState = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message)
            }
        }
    }

    /// Shows the image saved with a session opened from History, without regenerating it.
    private func loadStoredThenImage(sessionID: UUID) {
        do {
            guard let png = try services.memory.thenImage(sessionID: sessionID),
                  let image = UIImage(data: png) else { return }
            thenImage = image
            thenState = .showing
        } catch {
            AppServices.logMemoryFailure("then image load failed", error)
        }
    }

    // MARK: - Speech

    func speechState(for level: Int) -> SpeechState { speech[level] ?? .idle }

    /// Play/Stop toggle for one level: stops it when loading or playing, otherwise starts it.
    func toggleSpeech(level: Int) {
        switch speechState(for: level) {
        case .idle, .failed: playSpeech(level: level)
        case .loading, .playing: stopSpeech()
        }
    }

    /// Starts speaking one level, stopping whatever else is loading or playing. A replay hits the cache.
    /// Failure only marks that level as failed; the text is never affected.
    /// `backgroundWork`, if given, is ended once the audio fetch finishes, however it finishes.
    func playSpeech(level: Int, backgroundWork: UIBackgroundTaskIdentifier = .invalid) {
        guard let session, session.levels.indices.contains(level) else {
            endBackgroundWork(backgroundWork)
            return
        }
        stopSpeech()
        speech[level] = .loading
        let text = session.levels[level]
        let language = session.language
        let key = "\(session.id.uuidString)-\(level + 1)"
        speechTask = Task { [weak self, services] in
            defer { self?.endBackgroundWork(backgroundWork) }
            do {
                let service = try services.makeSpeech()
                let (url, usage) = try await service.audioFile(text: text, language: language, cacheKey: key)
                // nil is a cache hit: nothing was paid for.
                if let usage { services.recordUsage([usage]) }
                guard !Task.isCancelled, let self else { return }
                do {
                    try self.audio.play(url)
                } catch {
                    // An unplayable cached file would fail every Retry; drop it so Retry refetches.
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                self.speech[level] = .playing
            } catch {
                // Our own stop is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                var message: String?
                if let e = error as? OpenAIError,
                   e == .invalidAPIKey || e == .quotaExceeded || e == .missingAPIKey || e == .modelRetired {
                    message = UserFacingMessage.message(for: e)
                }
                self.speech[level] = .failed(message: message)
            }
        }
    }

    /// Cancels a speech request in flight and stops playback.
    func stopSpeech() {
        speechTask?.cancel()
        speechTask = nil
        audio.stop()
        speech = [:]
    }

    // MARK: - Background time

    /// Starts a background task for the work about to run, ending any previous one first so none leaks.
    private func beginBackgroundWork() -> UIBackgroundTaskIdentifier {
        endBackgroundWork()
        let id = UIApplication.shared.beginBackgroundTask(withName: "MyGuide story") { [weak self] in
            self?.backgroundTimeExpired()
        }
        backgroundTask = id
        return id
    }

    /// Ends `id` if it is still the one held. A stale id (already ended, or replaced by newer work) is ignored,
    /// so no identifier is ever ended twice.
    private func endBackgroundWork(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid, id == backgroundTask else { return }
        endBackgroundWork()
    }

    /// Ends the held background task, if any.
    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        let id = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    /// iOS is about to suspend the app: stop the work and end the task. A first story that was still working
    /// shows the error with Retry instead of a spinner that would never finish.
    private func backgroundTimeExpired() {
        let wasWorking = if case .working = state { true } else { false }
        cancel()
        if wasWorking {
            state = .failed(message: Self.unexpectedCancellationText, canUseCurrentPosition: false)
        }
    }
}
