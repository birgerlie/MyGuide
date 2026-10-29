import Foundation
import MyGuideCore
import Observation
import UIKit

/// State machine for one photo's story. The photo and capture are kept so Retry never loses them.
@MainActor
@Observable
final class StoryViewModel {
    /// The steps of a first story (spec 6, 14.10). Each replaces the one before; only `showing` has a session.
    enum State {
        /// "Finner stedet …" / "Finding the place …": at once.
        case finding
        /// The likely place from the nearby list, marked "Kanskje:" / "Maybe:".
        case guess(PlaceCard)
        /// The model request runs. `text` is the story so far (display only, empty until the first words); the final
        /// decoded story replaces it, and a failure drops it.
        case writing(card: PlaceCard?, text: String)
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

    static let unexpectedCancellationText = "Something went wrong. Try again."
    /// The `@AppStorage` key of "Les opp automatisk" / "Read aloud automatically" (spec 9); on when never set.
    nonisolated static let readAloudKey = "readAloudAutomatically"

    var state: State = .finding
    var session: StorySession?
    var moreState: MoreState = .idle
    /// The next level's text so far while "Tell me more" streams it (display only); nil otherwise.
    private(set) var moreText: String?
    /// The fresh search's places, offered as "Prøv igjen med flere steder" / "Try again with more places": set only
    /// when the story is "unsure" and the fresh search found a place in view that was not sent.
    private(set) var morePlaces: Grounding?
    var thenState: ThenState = .idle
    /// The decoded "then" image, kept so the view never decodes PNG data during body evaluation.
    private(set) var thenImage: UIImage?
    /// The photo, downscaled once off the main thread, shown while the story is found and written.
    private(set) var photoPreview: UIImage?
    /// True when the last save to memory failed. The story stays visible; the view shows a small banner.
    var saveFailed = false
    /// Speech state per level index; a missing entry means idle. At most one level is not idle at a time.
    private(set) var speech: [Int: SpeechState] = [:]

    /// The language of the screen's texts: the session's once there is one, else the one the story is told in.
    var language: StoryLanguage { session?.language ?? newSessionLanguage }

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var capture: CaptureContext?
    /// The places a "Try again with more places" run used; Retry after its failure reruns with them.
    @ObservationIgnored private var givenPlaces: Grounding?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Applies the streamed progress of the request in `task`, in order.
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// Waits for `PhotoStoryOutcome.freshCandidates` after an "unsure" story.
    @ObservationIgnored private var morePlacesTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var thenTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    /// Identifies the first story whose progress may change the screen; a new run or `cancel()` replaces it.
    @ObservationIgnored private var runID = UUID()
    /// Likewise for the "Tell me more" request, so it never stops an "unsure" story's wait for more places.
    @ObservationIgnored private var moreRunID = UUID()
    /// The likely-place card, kept while the identification has not arrived.
    @ObservationIgnored private var guessed: RankedCandidate?
    /// The nearby list the run used, to place a matched candidate on the card before the story is complete.
    @ObservationIgnored private var nearbyList: NearbyList?
    @ObservationIgnored private var storyText: TextThrottle?
    @ObservationIgnored private var moreTextThrottle: TextThrottle?
    /// Keeps a first story or a continuation (through its audio fetch, when speech is on) running if the phone is
    /// locked mid-request. At most one is held; `.invalid` when none.
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Language for a first story; read when the photo is taken or picked. Stored sessions keep their own.
    @ObservationIgnored private var newSessionLanguage: StoryLanguage = .english
    @ObservationIgnored private let audio = AudioPlayer()

    init(services: AppServices, language: StoryLanguage = .english) {
        self.services = services
        self.newSessionLanguage = language
        audio.onFinish = { [weak self] _ in self?.speech = [:] }
        storyText = TextThrottle { [weak self] text in self?.showStoryText(text) }
        moreTextThrottle = TextThrottle { [weak self] text in self?.showMoreText(text) }
    }

    /// Opens a stored session from History: shows its levels at once, with no auto-play. Speech cache keys use
    /// the stored session id, so cached audio is reused, and "Tell me more" continues from the stored levels.
    init(session: StorySession, services: AppServices) {
        self.services = services
        self.session = session
        self.newSessionLanguage = session.language
        self.state = .showing
        loadStoredThenImage(sessionID: session.id)
        audio.onFinish = { [weak self] _ in self?.speech = [:] }
        moreTextThrottle = TextThrottle { [weak self] text in self?.showMoreText(text) }
    }

    // Backstop: work for a dropped screen must not keep running (the owner normally calls cancel()).
    isolated deinit {
        task?.cancel()
        streamTask?.cancel()
        morePlacesTask?.cancel()
        previewTask?.cancel()
        thenTask?.cancel()
        speechTask?.cancel()
        storyText?.cancel()
        moreTextThrottle?.cancel()
        audio.stop()
        endBackgroundWork()
    }

    func start(photoJPEG: Data, capture: CaptureContext) {
        self.photoJPEG = photoJPEG
        self.capture = capture
        makePreview(photoJPEG)
        run(places: nil)
    }

    /// Re-runs with the same photo and capture (and the same places, after a failed "Try again with more places").
    func retry() {
        run(places: givenPlaces)
    }

    /// Replaces the capture's position (clearing its heading) and runs again, with a new place search.
    func useCurrentPosition(_ coordinate: Coordinate, accuracy: Double?) {
        guard let capture else { return }
        self.capture = capture.withCoordinate(coordinate, accuracy: accuracy)
        run(places: nil)
    }

    /// "Prøv igjen med flere steder" / "Try again with more places": tells the story again from the fresh search's
    /// places. Only ever on the owner's tap (a second model call costs money).
    func retryWithMorePlaces() {
        guard let places = morePlaces else { return }
        run(places: places)
    }

    /// Asks for the next level, streamed. Ignored while a request is already running or when no level is left.
    /// Uses the same `task` as the first story, so `cancel()` and a dropped screen stop it too.
    func tellMore() {
        guard let current = session, current.nextLevel != nil, moreState != .working else { return }
        moreState = .working
        moreText = nil
        moreTextThrottle?.cancel()
        task?.cancel()
        streamTask?.cancel()
        let moreRunID = UUID()
        self.moreRunID = moreRunID
        let (texts, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        streamTask = Task { [weak self] in
            for await text in texts {
                guard let self, self.moreRunID == moreRunID, self.moreState == .working else { return }
                self.moreTextThrottle?.push(text)
            }
        }
        let background = beginBackgroundWork()
        task = Task { [weak self, services] in
            var heldBySpeech = false
            defer {
                sink.finish()
                if !heldBySpeech { self?.endBackgroundWork(background) }
            }
            do {
                let flow = try services.makeFlow()
                let (next, usage) = try await flow.continueStoryStreaming(current, onText: Self.forwarding(to: sink))
                services.recordUsage(usage)
                guard !Task.isCancelled, let self else { return }
                self.moreTextThrottle?.cancel()
                self.moreText = nil
                self.session = next
                self.moreState = .idle
                self.persist(next)
                // The level's text is complete: speech starts now, or never when reading aloud is off.
                if Self.readsAloud {
                    heldBySpeech = true
                    self.playSpeech(level: next.levels.count - 1, backgroundWork: background)
                }
            } catch {
                // Our own cancel is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self else { return }
                // A broken stream keeps nothing of the partial level.
                self.moreTextThrottle?.cancel()
                self.moreText = nil
                let message = UserFacingMessage.message(for: error)
                self.moreState = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message)
            }
        }
    }

    /// Stops in-flight work silently; called when the story screen is dropped (navigated back).
    func cancel() {
        runID = UUID()
        moreRunID = UUID()
        task?.cancel()
        task = nil
        streamTask?.cancel()
        streamTask = nil
        morePlacesTask?.cancel()
        morePlacesTask = nil
        thenTask?.cancel()
        thenTask = nil
        storyText?.cancel()
        moreTextThrottle?.cancel()
        moreText = nil
        stopSpeech()
        endBackgroundWork()
        if moreState == .working { moreState = .idle }
        if thenState == .working { thenState = .idle }
    }

    /// Whether the first story is still being found or written (no session yet, no failure).
    var isWorking: Bool {
        switch state {
        case .finding, .guess, .writing: true
        case .showing, .failed: false
        }
    }

    /// The card the screen shows: the guess, then the identification as it streams, then the decoded one. After a
    /// failure only the nearby list's guess remains (never a card from the broken stream).
    var card: PlaceCard? {
        switch state {
        case .guess(let card): card
        case .writing(let card, _): card
        case .showing: session.map(PlaceCard.init(session:))
        case .failed: guessed.map(PlaceCard.init(guess:))
        case .finding: nil
        }
    }

    // MARK: - First story

    /// Tells the first story: from `places` when given ("Try again with more places"), else with the nearby list and a
    /// fresh place search. Progress is applied in order through `streamTask`; the final decoded story is the one kept.
    private func run(places: Grounding?) {
        guard let photoJPEG, let capture else { return }
        cancel()
        thenState = .idle
        thenImage = nil
        session = nil
        moreState = .idle
        morePlaces = nil
        guessed = nil
        nearbyList = nil
        givenPlaces = places
        saveFailed = false
        state = .finding
        let language = newSessionLanguage
        let runID = UUID()
        self.runID = runID
        let (steps, sink) = AsyncStream.makeStream(of: PhotoStoryProgress.self)
        streamTask = Task { [weak self] in
            for await step in steps {
                guard let self, self.runID == runID else { return }
                self.apply(step)
            }
        }
        let background = beginBackgroundWork()
        task = Task { [weak self, services] in
            // With reading aloud on, the level 1 audio fetch takes over the background task and ends it.
            var heldBySpeech = false
            defer {
                sink.finish()
                if !heldBySpeech { self?.endBackgroundWork(background) }
            }
            do {
                let flow = try services.makeFlow()
                let progress = Self.forwarding(to: sink)
                let outcome: PhotoStoryOutcome
                if let places {
                    outcome = try await flow.tellFirstStoryStreaming(photoJPEG: photoJPEG, capture: capture,
                                                                     language: language, grounding: places,
                                                                     progress: progress)
                } else {
                    let list = await services.nearby.current(language: language)
                    if let self, self.runID == runID { self.nearbyList = list }
                    outcome = try await flow.tellFirstStoryStreaming(photoJPEG: photoJPEG, capture: capture,
                                                                     language: language, nearby: list,
                                                                     progress: progress)
                }
                // Paid calls and timings are recorded even if the screen was dropped meanwhile. A "Try again with
                // more places" run is not a first story: its timings would skew the medians, so they are not kept.
                services.recordUsage(outcome.usage)
                let finishedAt = Date.now
                let record: @MainActor (Int?) -> Void = { speechMs in
                    guard places == nil else { return }
                    var timings = outcome.timings
                    timings.speechMs = speechMs
                    AppServices.recordPhotoTimings(timings, at: finishedAt)
                }
                guard !Task.isCancelled, let self, self.runID == runID else {
                    record(nil)
                    return
                }
                self.show(outcome, runID: runID)
                // The text is complete: speech starts now, or never when reading aloud is off. The timings wait for
                // the speech request, so they carry its time.
                if Self.readsAloud {
                    heldBySpeech = true
                    self.playSpeech(level: 0, backgroundWork: background, onAudioReady: record)
                } else {
                    record(nil)
                }
            } catch {
                // Our own cancel (or a superseding run) is silence, whatever error type the sources report it with.
                guard !Task.isCancelled, let self, self.runID == runID else { return }
                // A broken or late stream keeps nothing: no partial text, no card from it, no session.
                self.storyText?.cancel()
                self.runID = UUID()
                let message = UserFacingMessage.message(for: error)
                // A CancellationError we did not ask for must not leave the spinner up with no way out.
                self.state = .failed(message: message.isEmpty ? Self.unexpectedCancellationText : message,
                                     canUseCurrentPosition: (error as? PhotoStoryError) == .noPosition)
            }
        }
    }

    /// One progress step, applied only while the first story is still working (the final story always wins).
    private func apply(_ step: PhotoStoryProgress) {
        guard isWorking else { return }
        switch step {
        case .finding:
            state = .finding
        case .guess(let candidate):
            guessed = candidate
            state = .guess(PlaceCard(guess: candidate))
        case .writing:
            state = .writing(card: guessed.map(PlaceCard.init(guess:)), text: "")
        case .partial(let partial):
            let card = card(for: partial)
            if case .writing(let shown, let text) = state, shown != card {
                state = .writing(card: card, text: text)
            }
            if let story = partial.story, !story.isEmpty { storyText?.push(story) }
        }
    }

    /// The card for a partial identification. Until it is complete the guess stays, marked "Kanskje:" / "Maybe:".
    /// "unsure" shows the not-sure sentence as soon as it arrives. A "certain" or "likely" counts once its
    /// `matchedCandidateID` is known (it arrived, or a later field did, so it was null): then the card shows the
    /// matched place, placed from the guess or the nearby list when it is there, else by name only; or the model's
    /// subject when nothing was matched. The flow has already dropped an id that was not sent.
    private func card(for partial: PartialFirstStory) -> PlaceCard? {
        let guessCard = guessed.map(PlaceCard.init(guess:))
        guard let confidence = partial.confidence.flatMap(SubjectConfidence.init(rawValue:)) else { return guessCard }
        if confidence == .unsure { return .unsure }
        let idSettled = partial.matchedCandidateID != nil || partial.title != nil || partial.era != nil
            || partial.story != nil
        guard idSettled else { return guessCard }
        if let id = partial.matchedCandidateID {
            if let guessed, guessed.candidate.id == id { return PlaceCard(identified: guessed) }
            if let from = capture?.coordinate, let candidate = nearbyList?.candidates.first(where: { $0.id == id }) {
                return PlaceCard(name: candidate.name, distance: GeoMath.distance(from, candidate.coordinate),
                                 bearing: GeoMath.bearing(from: from, to: candidate.coordinate), mark: .identified)
            }
        }
        guard let subject = partial.subject, !subject.isEmpty else { return guessCard }
        return PlaceCard(name: subject, distance: nil, bearing: nil, mark: .identified)
    }

    private func showStoryText(_ text: String) {
        guard case .writing(let card, _) = state else { return }
        state = .writing(card: card, text: text)
    }

    private func showMoreText(_ text: String) {
        guard moreState == .working else { return }
        moreText = text
    }

    /// The final story replaces whatever streamed. An "unsure" story then asks for the fresh search's places, which
    /// never delays the story or its speech; the button appears only if they come.
    private func show(_ outcome: PhotoStoryOutcome, runID: UUID) {
        storyText?.cancel()
        streamTask?.cancel()
        streamTask = nil
        session = outcome.session
        state = .showing
        persist(outcome.session)
        guard outcome.session.identified.confidence == .unsure else { return }
        let freshCandidates = outcome.freshCandidates
        morePlacesTask = Task { [weak self] in
            let places = await freshCandidates()
            guard !Task.isCancelled, let places, let self, self.runID == runID, case .showing = self.state else { return }
            self.morePlaces = places
        }
    }

    /// Saves after every successful level. A failure is logged (no story text) and flagged for the banner;
    /// it never touches the story on screen.
    private func persist(_ session: StorySession) {
        do {
            try services.memory.save(session)
            saveFailed = false
            LatestStoryRef.record(.photo(session.id))
        } catch {
            AppServices.logMemoryFailure("save failed", error)
            saveFailed = true
        }
        // A story about a matched place retires it from walking mode, saved or not.
        if let placeID = session.matchedCandidate?.candidate.id { services.walking.noteHeard(placeID: placeID) }
    }

    /// Decodes a screen-sized copy of the photo off the main thread.
    private func makePreview(_ photoJPEG: Data) {
        previewTask?.cancel()
        photoPreview = nil
        previewTask = Task { [weak self] in
            let preview = await Self.preview(of: photoJPEG)
            guard !Task.isCancelled, let self else { return }
            self.photoPreview = preview
        }
    }

    nonisolated private static func preview(of photoJPEG: Data) async -> UIImage? {
        guard let image = UIImage(data: photoJPEG), image.size.width > 0, image.size.height > 0 else { return nil }
        let longSide: CGFloat = 1200
        let scale = min(1, longSide / max(image.size.width, image.size.height))
        return await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * scale,
                                                               height: image.size.height * scale))
    }

    /// The flow reports from its own context; the stream keeps the order and the main actor applies it.
    nonisolated private static func forwarding<Element: Sendable>(to sink: AsyncStream<Element>.Continuation)
        -> @Sendable (Element) -> Void {
        { sink.yield($0) }
    }

    /// "Les opp automatisk" / "Read aloud automatically", read when a level's text is complete.
    private static var readsAloud: Bool {
        UserDefaults.standard.object(forKey: readAloudKey) as? Bool ?? true
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

    /// Lytt/Stop toggle for one level: stops it when loading or playing, otherwise starts it.
    func toggleSpeech(level: Int) {
        switch speechState(for: level) {
        case .idle, .failed: playSpeech(level: level)
        case .loading, .playing: stopSpeech()
        }
    }

    /// Starts speaking one level, stopping whatever else is loading or playing. A replay hits the cache.
    /// Failure only marks that level as failed; the text is never affected.
    /// `backgroundWork`, if given, is ended once the audio fetch finishes, however it finishes. `onAudioReady`, if
    /// given, is called exactly once when the fetch finishes, however it finishes: with the milliseconds from the
    /// request's start to the audio file being ready, or nil when it failed, was stopped or never started.
    func playSpeech(level: Int, backgroundWork: UIBackgroundTaskIdentifier = .invalid,
                    onAudioReady: (@MainActor (Int?) -> Void)? = nil) {
        guard let session, session.levels.indices.contains(level) else {
            endBackgroundWork(backgroundWork)
            onAudioReady?(nil)
            return
        }
        stopSpeech()
        speech[level] = .loading
        let text = session.levels[level]
        let language = session.language
        let key = "\(session.id.uuidString)-\(level + 1)"
        speechTask = Task { [weak self, services] in
            var speechMs: Int?
            defer {
                self?.endBackgroundWork(backgroundWork)
                onAudioReady?(speechMs)
            }
            do {
                let service = try services.makeSpeech()
                let requested = ContinuousClock.now
                let (url, usage) = try await service.audioFile(text: text, language: language, cacheKey: key)
                speechMs = Int(((ContinuousClock.now - requested) / .milliseconds(1)).rounded())
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
        let id = UIApplication.shared.beginBackgroundTask(withName: "MyGuide story",
                                                          expirationHandler: Self.expirationHandler(for: self))
        backgroundTask = id
        return id
    }

    /// Built outside the main actor so UIKit gets a nonisolated `@Sendable` handler. UIKit calls it on the main
    /// thread, where the work is stopped and the task ended before it returns; from anywhere else it hops there.
    nonisolated private static func expirationHandler(for model: StoryViewModel) -> @Sendable () -> Void {
        { [weak model] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { model?.backgroundTimeExpired() }
            } else {
                Task { @MainActor in model?.backgroundTimeExpired() }
            }
        }
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
    /// shows the error with Retry instead of steps that would never finish.
    private func backgroundTimeExpired() {
        let wasWorking = isWorking
        cancel()
        if wasWorking {
            state = .failed(message: Self.unexpectedCancellationText, canUseCurrentPosition: false)
        }
    }
}

// MARK: - Place card

/// The place card above the story: name, distance and direction (spec 6). The view words it in the story language.
struct PlaceCard: Equatable {
    enum Mark: Equatable {
        /// From the nearby list before the model has answered: "Kanskje:" / "Maybe:".
        case guess
        /// The model's identification ("certain" or "likely").
        case identified
        /// The model is not sure: the card shows the not-sure sentence instead of a place.
        case unsure
    }

    var name: String
    /// Metres from the photo; nil when the place is known by name only.
    var distance: Double?
    /// Degrees clockwise from north; nil when the place is known by name only.
    var bearing: Double?
    var mark: Mark

    static let unsure = PlaceCard(name: "", distance: nil, bearing: nil, mark: .unsure)

    init(name: String, distance: Double?, bearing: Double?, mark: Mark) {
        self.name = name
        self.distance = distance
        self.bearing = bearing
        self.mark = mark
    }

    init(guess: RankedCandidate) {
        self.init(name: guess.candidate.name, distance: guess.distance, bearing: guess.bearing, mark: .guess)
    }

    init(identified: RankedCandidate) {
        self.init(name: identified.candidate.name, distance: identified.distance, bearing: identified.bearing,
                  mark: .identified)
    }

    /// The decoded story's card: the not-sure sentence, the matched place, or the model's subject by name.
    init(session: StorySession) {
        if session.identified.confidence == .unsure {
            self = .unsure
        } else if let matched = session.matchedCandidate {
            self.init(identified: matched)
        } else {
            self.init(name: session.identified.subject, distance: nil, bearing: nil, mark: .identified)
        }
    }
}

// MARK: - Screen texts

/// The camera and story screens' texts in the story language (spec 5, 6, 9; the app has no localisation, so only these
/// new texts come in both languages).
enum ScreenText {
    static func lookingAt(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hva ser du på?" : "What are you looking at?"
    }

    static func findPlace(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finn stedet" : "Find the place"
    }

    static func finding(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner stedet …" : "Finding the place …"
    }

    static func writing(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriver fortellingen …" : "Writing the story …"
    }

    static func notSure(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Jeg er ikke sikker på hvilket sted dette er." : "I'm not sure which place this is."
    }

    static func morePlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Prøv igjen med flere steder" : "Try again with more places"
    }

    static func listen(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lytt" : "Listen"
    }

    static func stop(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stopp" : "Stop"
    }

    static func readAloud(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Les opp automatisk" : "Read aloud automatically"
    }

    /// "Kanskje: Pantheon · 120 m mot nordøst" / "Maybe: Pantheon · 120 m north-east"; without a position, the name.
    static func maybe(_ card: PlaceCard, _ language: StoryLanguage) -> String {
        let prefix = language == .norwegian ? "Kanskje" : "Maybe"
        guard let where_ = distanceAndDirection(card, language) else { return "\(prefix): \(card.name)" }
        return "\(prefix): \(card.name) · \(where_)"
    }

    /// "120 m mot nordøst" / "120 m north-east" (distance rounded as walking mode does); nil without a position.
    static func distanceAndDirection(_ card: PlaceCard, _ language: StoryLanguage) -> String? {
        guard let distance = card.distance, let bearing = card.bearing else { return nil }
        return "\(BuzzText.roundedDistance(distance)) m \(direction(bearing, language))"
    }

    /// `GuideText`'s compass word for the bearing (a guess is always ahead, so the side would say nothing), in
    /// Norwegian as "mot …".
    static func direction(_ bearing: Double, _ language: StoryLanguage) -> String {
        let word = GuideText.side(bearing: bearing, direction: nil)
        guard language == .norwegian else { return word }
        return norwegianCompass[word].map { "mot \($0)" } ?? word
    }

    private static let norwegianCompass = [
        "north": "nord", "north-east": "nordøst", "east": "øst", "south-east": "sørøst",
        "south": "sør", "south-west": "sørvest", "west": "vest", "north-west": "nordvest",
    ]
}

// MARK: - Throttle

/// Shows a growing text at most once per `interval` (spec 8: streamed text at most every 100 ms). The first text shows
/// at once; texts arriving within the interval wait, and only the newest of them is shown when it ends.
@MainActor
final class TextThrottle {
    static let interval: Duration = .milliseconds(100)

    private let show: (String) -> Void
    private var pending: String?
    private var lastShown: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    init(show: @escaping (String) -> Void) {
        self.show = show
    }

    isolated deinit {
        timer?.cancel()
    }

    func push(_ text: String) {
        pending = text
        guard timer == nil else { return }
        let now = ContinuousClock.now
        if let lastShown, now - lastShown < Self.interval {
            let due = lastShown + Self.interval
            timer = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        } else {
            flush()
        }
    }

    /// Drops the waiting text and forgets the last showing, for the next stream.
    func cancel() {
        timer?.cancel()
        timer = nil
        pending = nil
        lastShown = nil
    }

    private func flush() {
        timer = nil
        guard let pending else { return }
        self.pending = nil
        lastShown = .now
        show(pending)
    }
}
