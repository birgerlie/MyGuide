import CoreLocation
import MyGuideCore
import Observation
import os
import UserNotifications

/// What the owner can do to a buzz. Later tasks add more cases.
enum WalkingCommand {
    case skip(buzzID: UUID)
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

    private(set) var isOn = false
    /// Why walking mode did not start (or stopped); empty when nothing is in the way.
    private(set) var problems: [String] = []
    private(set) var buzzCount = 0
    private(set) var lastFixAt: Date?

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let makeSource: () -> WalkingPlaceSource
    @ObservationIgnored private let hasAPIKey: () -> Bool
    @ObservationIgnored private let location = WalkingLocation()
    @ObservationIgnored private var engine: BuzzEngine?
    @ObservationIgnored private var appliedPerHour = BuzzBudget.defaultPerHour
    @ObservationIgnored private var feed = PlaceFeed()
    @ObservationIgnored private var source: WalkingPlaceSource?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var tripID: UUID?
    @ObservationIgnored private var track: [TrackSample] = []
    /// The candidate of every buzz posted this run, so a skip still retires the place when its buzz was never logged.
    @ObservationIgnored private var postedCandidates: [UUID: Candidate] = [:]
    /// Identifies the start in progress; `stop()` clears it so a start that is waiting on a prompt gives up.
    @ObservationIgnored private var startToken: UUID?

    init(memory: MemoryStore, makeSource: @escaping () -> WalkingPlaceSource, hasAPIKey: @escaping () -> Bool) {
        self.memory = memory
        self.makeSource = makeSource
        self.hasAPIKey = hasAPIKey
        location.onLocation = { [weak self] fix in self?.handle(fix) }
        location.onDenied = { [weak self] in
            guard let self, isOn else { return }
            stop()
            problems = WalkingReadiness.problems(location: .denied, notifications: .allowed, hasAPIKey: true)
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
        location.requestAlways()

        let found = await readiness()
        problems = found
        // Only "Always" may be missing: walking still works while the app is open or recently used.
        let blocking = found.filter { $0 != Self.alwaysMissingMessage }
        guard blocking.isEmpty, startToken == token else { return }

        await BuzzNotifier.registerCategory()
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
        engine = BuzzEngine(perHour: appliedPerHour, now: now, excluded: excluded)
        feed = PlaceFeed()
        source = makeSource()
        postedCandidates = [:]
        track = []
        buzzCount = 0
        lastFixAt = nil
        isOn = true
        location.start()
    }

    func stop() {
        startToken = nil
        guard isOn else { return }
        isOn = false
        location.stop()
        flushTrack()
        do { try memory.closePendingBuzzes() } catch { AppServices.logMemoryFailure("closing pending buzzes failed", error) }
        fetchTask?.cancel()
        fetchTask = nil
        feed.fetchCancelled()
        engine = nil
        source = nil
        problems = []
        Task { await BuzzNotifier.removeDelivered() }
    }

    // MARK: - Commands

    func handle(_ command: WalkingCommand) {
        switch command {
        case .skip(let buzzID):
            skip(buzzID)
        }
    }

    /// Routes a response to a BUZZ notification.
    func handle(_ response: UNNotificationResponse) {
        if let command = BuzzNotifier.command(for: response) { handle(command) }
    }

    /// A story about this place was saved: it never buzzes again.
    func noteHeard(placeID: String) {
        engine?.exclude(placeID)
    }

    private func skip(_ buzzID: UUID) {
        let now = Date.now
        // The place is retired in the same save as the outcome. When the buzz was never logged, store the place
        // from the candidate kept in memory so the skip is not lost.
        do {
            try memory.setBuzzOutcome(buzzID, .skipped, deepestLevel: 0, at: now)
        } catch {
            if let candidate = postedCandidates[buzzID] {
                do { try memory.markSkipped(candidate, at: now) } catch { AppServices.logMemoryFailure("skip failed", error) }
            } else {
                AppServices.logMemoryFailure("skip failed", error)
            }
        }
        if let candidate = postedCandidates[buzzID] { engine?.exclude(candidate.id) }
        engine?.noteSkip(at: now)
    }

    // MARK: - Fixes

    private func handle(_ fix: CLLocation) {
        guard isOn, var engine, fix.horizontalAccuracy >= 0 else { return }
        let now = Date.now
        lastFixAt = fix.timestamp
        let position = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)

        track.append(TrackSample(at: fix.timestamp, coordinate: position))
        if track.count >= Self.trackFlushCount { flushTrack() }

        if feed.shouldFetch(at: position, now: now) { fetch(around: position, now: now) }

        let perHour = Self.configuredPerHour()
        if perHour != appliedPerHour {
            appliedPerHour = perHour
            engine.setPerHour(perHour, at: now)
        }
        let buzz = engine.evaluate(places: feed.places, position: position, accuracy: fix.horizontalAccuracy,
                                   course: fix.course >= 0 ? fix.course : nil, now: now)
        self.engine = engine
        if let buzz { deliver(buzz, at: now) }
    }

    private func deliver(_ buzz: Buzz, at now: Date) {
        postedCandidates[buzz.id] = buzz.place.candidate
        if let tripID {
            do { try memory.recordBuzz(buzz, tripID: tripID, at: now) } catch { AppServices.logMemoryFailure("buzz record failed", error) }
        }
        buzzCount += 1
        Task {
            do { try await BuzzNotifier.post(buzz) } catch { AppServices.logMemoryFailure("buzz post failed", error) }
        }
    }

    private func fetch(around position: Coordinate, now: Date) {
        guard let source else { return }
        feed.fetchStarted(now: now)
        let language = Self.storyLanguage()
        fetchTask = Task { [weak self] in
            do {
                let places = try await source.places(around: position, language: language)
                guard !Task.isCancelled else { self?.feed.fetchCancelled(); return }
                self?.feed.fetchSucceeded(places, at: position, now: .now)
            } catch {
                // The app's own cancellation is silent and sets no retry delay; a real failure waits 60 s.
                if error is CancellationError || Task.isCancelled {
                    self?.feed.fetchCancelled()
                } else {
                    self?.feed.fetchFailed(now: .now)
                }
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

    private static let alwaysMissingMessage = WalkingReadiness.problems(location: .whenInUse, notifications: .allowed,
                                                                         hasAPIKey: true)[0]

    private func readiness() async -> [String] {
        let location: WalkingReadiness.Location = switch self.location.authorization {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
        return WalkingReadiness.problems(location: location, notifications: await Self.notificationState(),
                                         hasAPIKey: hasAPIKey())
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
