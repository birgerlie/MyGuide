import CoreLocation
import MyGuideCore
import Observation
import os
import UIKit
import UserNotifications

/// What the owner can do to a buzz, from its notification, the watch, the panel or the story screen.
enum WalkingCommand {
    case tellMe(buzzID: UUID)
    case more(buzzID: UUID)
    case skip(buzzID: UUID)
    /// Show the story in the app.
    case open(buzzID: UUID)
}

/// Walking mode on the phone: follows the walker in the background, keeps the nearby places fresh and
/// buzzes when one is due. Owned by `AppServices`, so it keeps running with the phone locked.
/// A memory failure is logged and never stops walking mode.
@MainActor
@Observable
final class WalkingController {
    nonisolated static let buzzesPerHourKey = "buzzesPerHour"
    private static let trackFlushCount = 20
    /// Samples kept while saving keeps failing; the oldest go first.
    private static let trackLimit = 400
    private static let geocodeTimeout: Duration = .seconds(8)
    private static let autoOffInterval: Duration = .seconds(60)

    private(set) var isOn = false
    /// Why walking mode did not start (or stopped); empty when nothing is in the way.
    private(set) var problems: [String] = []
    private(set) var buzzCount = 0
    /// The time of the last fix the buzz engine could use; nil until one arrives.
    private(set) var lastFixAt: Date?
    /// The walking stories: prepared at buzz time, played, continued and skipped.
    let stories: WalkingStories

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let makeSource: () -> WalkingPlaceSource
    @ObservationIgnored private let hasAPIKey: () -> Bool
    @ObservationIgnored private let location = WalkingLocation()
    @ObservationIgnored private var engine: BuzzEngine?
    @ObservationIgnored private var appliedPerHour = BuzzBudget.defaultPerHour
    @ObservationIgnored private var feed = PlaceFeed()
    @ObservationIgnored private var source: WalkingPlaceSource?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Checks the auto-off limits every 60 s, for the stretches without a usable fix.
    @ObservationIgnored private var autoOffTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var tripID: UUID?
    @ObservationIgnored private var track: [TrackSample] = []
    /// The candidate of every buzz posted this run, so a skip still retires the place when its buzz was never logged.
    @ObservationIgnored private var postedCandidates: [UUID: Candidate] = [:]
    /// Identifies the start in progress; `stop()` clears it so a start that is waiting on a prompt gives up.
    @ObservationIgnored private var startToken: UUID?
    /// Identifies the current run (start to stop), so work begun in an earlier run never touches this one.
    @ObservationIgnored private var runToken: UUID?

    init(memory: MemoryStore, stories: WalkingStories, makeSource: @escaping () -> WalkingPlaceSource,
         hasAPIKey: @escaping () -> Bool) {
        self.memory = memory
        self.stories = stories
        self.makeSource = makeSource
        self.hasAPIKey = hasAPIKey
        // No buzz while a story is preparing, being continued or playing.
        stories.onBusyChanged = { [weak self] busy in self?.engine?.isBusy = busy }
        stories.onHeard = { [weak self] placeID in self?.noteHeard(placeID: placeID) }
        stories.onRetire = { [weak self] id, candidate, level in self?.retire(id, candidate: candidate, deepestLevel: level) }
        stories.currentTripID = { [weak self] in self?.tripID }
        location.onLocation = { [weak self] fix in self?.handle(fix) }
        location.onDenied = { [weak self] in
            guard let self, isOn else { return }
            stop()
            problems = WalkingReadiness.problems(location: .denied, notifications: .allowed, hasAPIKey: true)
        }
        // "Always" is answered after start, so the reminder follows the real status while walking.
        location.onAuthorization = { [weak self] in
            guard let self, isOn else { return }
            Task { @MainActor in
                let found = await self.readiness()
                if self.isOn { self.problems = found.problems }
            }
        }
    }

    // MARK: - Start and stop

    func start() async {
        guard !isOn, startToken == nil else { return }
        let token = UUID()
        startToken = token
        defer { if startToken == token { startToken = nil } }

        // Ask while something is undetermined, then judge.
        if location.authorization == .notDetermined { await location.requestWhenInUse() }
        if await Self.notificationState() == .notDetermined {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                AppServices.logMemoryFailure("notification permission request failed", error)
            }
        }
        guard startToken == token else { return }

        let state = await readiness()
        problems = state.problems
        guard startToken == token,
              WalkingReadiness.canStart(location: state.location, notifications: state.notifications,
                                        hasAPIKey: state.hasAPIKey) else { return }
        // Only now: nothing blocks, so upgrading to Always is the one thing left to ask.
        location.requestAlways()

        await BuzzNotifier.registerCategories()
        let now = Date.now
        do { try memory.closePendingBuzzes() } catch { AppServices.logMemoryFailure("closing pending buzzes failed", error) }
        let city = await Self.city(near: location.lastKnown)
        guard startToken == token else { return }
        let trip: UUID
        do {
            trip = try memory.touchTrip(now: now, city: city).id
        } catch {
            AppServices.logMemoryFailure("trip update failed", error)
            trip = UUID()
        }
        tripID = trip
        var excluded = Set<String>()
        do { excluded.formUnion(try memory.retiredPlaceIDs()) } catch { AppServices.logMemoryFailure("retired places failed", error) }
        do { excluded.formUnion(try memory.placeIDsBuzzed(tripID: trip)) } catch { AppServices.logMemoryFailure("buzzed places failed", error) }

        appliedPerHour = Self.configuredPerHour()
        var engine = BuzzEngine(perHour: appliedPerHour, now: now, excluded: excluded)
        // A story from before this run may still be playing or ending.
        engine.isBusy = stories.isBusy
        self.engine = engine
        runToken = UUID()
        feed = PlaceFeed()
        source = makeSource()
        postedCandidates = [:]
        track = []
        buzzCount = 0
        lastFixAt = nil
        startedAt = now
        UIDevice.current.isBatteryMonitoringEnabled = true
        isOn = true
        location.start()
        startAutoOffTimer(run: runToken)
    }

    func stop() {
        startToken = nil
        guard isOn else { return }
        isOn = false
        runToken = nil
        autoOffTask?.cancel()
        autoOffTask = nil
        startedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        location.stop()
        flushTrack()
        do { try memory.closePendingBuzzes() } catch { AppServices.logMemoryFailure("closing pending buzzes failed", error) }
        fetchTask?.cancel()
        fetchTask = nil
        feed.fetchCancelled()
        engine = nil
        source = nil
        problems = []
        // Preparations and fetches still end with their (silent) failure events, so the machine never stays busy.
        stories.stopAll()
        Task { await BuzzNotifier.removeWalkNotifications() }
    }

    // MARK: - Commands

    /// Every command goes through the playback machine (Skip too), so there is one path per command.
    func handle(_ command: WalkingCommand) {
        switch command {
        case .tellMe(let buzzID): stories.tellMe(buzzID)
        case .more(let buzzID): stories.more(buzzID)
        case .skip(let buzzID): stories.skip(buzzID)
        case .open(let buzzID): stories.open(buzzID)
        }
    }

    /// Routes a response to a BUZZ, MORE or STORY_FAILED notification.
    func handle(_ response: UNNotificationResponse) {
        if let command = BuzzNotifier.command(for: response) { handle(command) }
    }

    /// A story about this place was saved: it never buzzes again.
    func noteHeard(placeID: String) {
        engine?.exclude(placeID)
    }

    /// The playback machine's `retire` effect for a skipped buzz. `candidate` is the story's place, when known.
    private func retire(_ buzzID: UUID, candidate: Candidate?, deepestLevel: Int) {
        let now = Date.now
        let candidate = postedCandidates[buzzID] ?? candidate
        // The place is retired in the same save as the outcome. When the buzz was never logged, store the place
        // from the candidate so the skip is not lost.
        do {
            try memory.setBuzzOutcome(buzzID, .skipped, deepestLevel: deepestLevel, at: now)
        } catch {
            if let candidate {
                do { try memory.markSkipped(candidate, at: now) } catch { AppServices.logMemoryFailure("skip failed", error) }
            } else {
                AppServices.logMemoryFailure("skip failed", error)
            }
        }
        if let candidate { engine?.exclude(candidate.id) }
        engine?.noteSkip(at: now)
    }

    // MARK: - Auto-off

    private func startAutoOffTimer(run: UUID?) {
        autoOffTask?.cancel()
        autoOffTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoOffInterval)
                guard !Task.isCancelled, let self, self.isOn, self.runToken == run else { return }
                self.checkAutoOff(now: .now)
            }
        }
    }

    /// Turns walking mode off after 4 hours or when the battery runs low, and says why in a notification.
    private func checkAutoOff(now: Date) {
        guard isOn, let startedAt,
              let reason = AutoOff.reason(startedAt: startedAt, now: now, batteryLevel: UIDevice.current.batteryLevel)
        else { return }
        stop()
        let message = AutoOff.message(reason)
        Task {
            do { try await BuzzNotifier.postAutoOff(message) } catch { AppServices.logMemoryFailure("auto-off notification failed", error) }
        }
    }

    // MARK: - Fixes

    private func handle(_ fix: CLLocation) {
        let now = Date.now
        checkAutoOff(now: now)
        // CoreLocation's first fix can be its cached position from minutes ago: not where the walker is.
        guard isOn, var engine, fix.horizontalAccuracy >= 0, WalkingFix.isFresh(fix.timestamp, now: now) else { return }
        // The status says "waiting for GPS" until a fix the engine can use arrives.
        if WalkingFix.isUsable(accuracy: fix.horizontalAccuracy) { lastFixAt = fix.timestamp }
        let position = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)

        track.append(TrackSample(at: fix.timestamp, coordinate: position))
        if track.count >= Self.trackFlushCount { flushTrack() }

        if feed.shouldFetch(at: position, now: now) { fetch(around: position, now: now) }

        let perHour = Self.configuredPerHour()
        if perHour != appliedPerHour {
            appliedPerHour = perHour
            engine.setPerHour(perHour, at: now)
        }
        let course = fix.course >= 0 ? fix.course : nil
        let buzz = engine.evaluate(places: feed.places, position: position, accuracy: fix.horizontalAccuracy,
                                   course: course, now: now)
        self.engine = engine
        if let buzz { deliver(buzz, position: position, course: course, at: now) }
    }

    private func deliver(_ buzz: Buzz, position: Coordinate, course: Double?, at now: Date) {
        postedCandidates[buzz.id] = buzz.place.candidate
        if let tripID {
            do { try memory.recordBuzz(buzz, tripID: tripID, at: now) } catch { AppServices.logMemoryFailure("buzz record failed", error) }
        }
        buzzCount += 1
        let run = runToken
        Task { [weak self] in
            guard let self, self.isOn, self.runToken == run else { return }
            do { try await BuzzNotifier.post(buzz) } catch { AppServices.logMemoryFailure("buzz post failed", error); return }
            // stop() may have cleared the notifications while this one was being added: take it back.
            if !self.isOn || self.runToken != run { BuzzNotifier.removeNotifications(for: buzz.id) }
        }
        // Prepared at once, so a tap plays within a second or two (design 7.5). This makes the engine busy.
        stories.prepare(buzz, position: position, course: course, nearby: feed.places, language: Self.storyLanguage())
    }

    private func fetch(around position: Coordinate, now: Date) {
        guard let source else { return }
        feed.fetchStarted(now: now)
        let language = Self.storyLanguage()
        let run = runToken
        fetchTask = Task { [weak self] in
            let result: Result<[WalkingPlace], Error>
            do {
                result = .success(try await source.places(around: position, language: language))
            } catch {
                result = .failure(error)
            }
            // A fetch from an earlier run never touches this run's feed (stop() already settled that one).
            guard let self, self.runToken == run else { return }
            switch result {
            case .success(let places) where !Task.isCancelled:
                self.feed.fetchSucceeded(places, at: position, now: .now)
            case .failure(let error) where !(error is CancellationError) && !Task.isCancelled:
                // A real failure waits 60 s before the next try.
                self.feed.fetchFailed(now: .now)
            default:
                // The app's own cancellation is silent and sets no retry delay.
                self.feed.fetchCancelled()
            }
        }
    }

    private func flushTrack() {
        guard !track.isEmpty, let tripID else { track = []; return }
        do {
            try memory.appendTrack(track, tripID: tripID)
            track = []
        } catch {
            AppServices.logMemoryFailure("track save failed", error)
            // A failed save rolls back, so the samples can be retried with the next flush.
            if track.count > Self.trackLimit { track.removeFirst(track.count - Self.trackLimit) }
        }
    }

    // MARK: - Readiness

    private struct Readiness {
        var location: WalkingReadiness.Location
        var notifications: WalkingReadiness.Notifications
        var hasAPIKey: Bool

        var problems: [String] {
            WalkingReadiness.problems(location: location, notifications: notifications, hasAPIKey: hasAPIKey)
        }
    }

    private func readiness() async -> Readiness {
        let location: WalkingReadiness.Location = switch self.location.authorization {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
        return Readiness(location: location, notifications: await Self.notificationState(), hasAPIKey: hasAPIKey())
    }

    private static func notificationState() async -> WalkingReadiness.Notifications {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral:
            return settings.timeSensitiveSetting == .disabled ? .timeSensitiveOff : .allowed
        @unknown default: return .denied
        }
    }

    // MARK: - Settings and city

    private static func configuredPerHour() -> Int {
        UserDefaults.standard.object(forKey: buzzesPerHourKey) as? Int ?? BuzzBudget.defaultPerHour
    }

    private static func storyLanguage() -> StoryLanguage {
        UserDefaults.standard.string(forKey: AppServices.storyLanguageKey).flatMap(StoryLanguage.init(rawValue:)) ?? .english
    }

    /// The city at `location`, or nil when there is no position, the lookup fails or it takes longer than 8 s.
    private static func city(near location: CLLocation?) async -> String? {
        guard let location else { return nil }
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let once = OnceBox<String?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                once.install(continuation)
                // MapKit's request ignores cancellation, so neither task is awaited: whichever finishes first resumes.
                Task {
                    let city = try? await MapKitReverseGeocoder().address(for: coordinate).city
                    once.resume(city)
                }
                Task {
                    try? await Task.sleep(for: geocodeTimeout)
                    once.resume(nil)
                }
            }
        } onCancel: {
            once.resume(nil)
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class OnceBox<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        var early: T?
        var done = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let early = state.withLock { state -> T? in
            if state.done { return state.early }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: T) {
        let continuation = state.withLock { state -> CheckedContinuation<T, Never>? in
            guard !state.done else { return nil }
            state.done = true
            state.early = value
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: value)
    }
}
