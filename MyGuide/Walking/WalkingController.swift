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
    @ObservationIgnored private var stopDetector: StopDetector?
    @ObservationIgnored private let activity = WalkingActivityController()
    @ObservationIgnored private var appliedPerHour = BuzzBudget.defaultPerHour
    @ObservationIgnored private var feed = PlaceFeed()
    @ObservationIgnored private var source: WalkingPlaceSource?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Checks the auto-off limits every 60 s, for the stretches without a usable fix.
    @ObservationIgnored private var autoOffTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var tripID: UUID?
    @ObservationIgnored private var track: [TrackSample] = []
    /// The last sample kept for the track (flushed or not), so `TrackSample.isWorthStoring` thins across flushes.
    @ObservationIgnored private var lastTrackSample: TrackSample?
    /// The recent walk and its street lookups, for the stories' direction, position and "came from" (spec 6.4–6.5).
    /// In memory only; reset after a stop story and when walking mode stops.
    @ObservationIgnored private var route = RouteMemory()
    /// True while a street lookup runs: `RouteMemory.needsStreetLookup` stays true until it is recorded.
    @ObservationIgnored private var streetLookupInFlight = false
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
        stories.currentPlaces = { [weak self] in self?.feed.places ?? [] }
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

        // First of all: a Live Activity can only be requested in the foreground, and the owner may lock the phone at
        // once. Any left over from an earlier launch end first.
        let now = Date.now
        let activityID = await activity.start(at: now, status: WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 0, now: now) ?? "Walking")
        guard startToken == token else {
            if let activityID { activity.end(id: activityID) }
            return
        }
        await BuzzNotifier.registerCategories()
        do { try memory.closePendingBuzzes() } catch { AppServices.logMemoryFailure("closing pending buzzes failed", error) }
        let city = await Self.city(near: location.lastKnown)
        guard startToken == token else {
            if let activityID { activity.end(id: activityID) }
            return
        }
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

        var stopSpots: [Coordinate] = []
        do { stopSpots = try memory.stopSpots(tripID: trip) } catch { AppServices.logMemoryFailure("stop spots failed", error) }
        stopDetector = StopDetector(previousStops: stopSpots)

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
        lastTrackSample = nil
        route.reset()
        streetLookupInFlight = false
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
        route.reset()
        streetLookupInFlight = false
        do { try memory.closePendingBuzzes() } catch { AppServices.logMemoryFailure("closing pending buzzes failed", error) }
        fetchTask?.cancel()
        fetchTask = nil
        feed.fetchCancelled()
        engine = nil
        stopDetector = nil
        source = nil
        problems = []
        activity.endCurrent()
        // Preparations and fetches still end with their (silent) failure events, so the machine never stays busy.
        stories.stopAll()
        Task { await BuzzNotifier.removeWalkNotifications() }
    }

    /// At launch: walking mode never survives a relaunch, so a walking Live Activity still on the lock screen belongs
    /// to a run whose app was ended. Ends them, unless walking mode is on or starting by now.
    func endLeftoverActivities() {
        guard !isOn, startToken == nil else { return }
        activity.endLeftovers()
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

    /// A level of a story about this place started playing: it never buzzes again this run (memory retires it for
    /// later runs).
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
                self.refreshActivity(now: .now)
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
        guard isOn, engine != nil, fix.horizontalAccuracy >= 0, WalkingFix.isFresh(fix.timestamp, now: now) else { return }
        // The status says "waiting for GPS" until a fix the engine can use arrives.
        if WalkingFix.isUsable(accuracy: fix.horizontalAccuracy) { lastFixAt = fix.timestamp }
        let position = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)

        // Every fix arrives (no distance filter); the stored track keeps one per 5 m or per minute. The route gets
        // those of them taken while walking with a good fix, so standing still makes no path, bearing or lookup.
        let sample = TrackSample(at: fix.timestamp, coordinate: position)
        if TrackSample.isWorthStoring(sample, after: lastTrackSample) {
            lastTrackSample = sample
            track.append(sample)
            if track.count >= Self.trackFlushCount { flushTrack() }
            if WalkingFix.isRouteFix(speed: fix.speed, accuracy: fix.horizontalAccuracy) {
                route.add(sample)
                if route.needsStreetLookup, !streetLookupInFlight { lookUpStreet(at: position) }
            }
        }

        if feed.shouldFetch(at: position, now: now) { fetch(around: position, now: now) }

        // The raw speed: -1 means unknown, which the detector does not count as moving.
        if let spot = stopDetector?.update(position: position, accuracy: fix.horizontalAccuracy, speed: fix.speed, now: now) {
            tellStop(at: spot)
        }

        // The engine is mutated in place, never copied and written back, so a change made by a synchronous callback
        // meanwhile (busy, exclude) is not overwritten.
        let perHour = Self.configuredPerHour()
        if perHour != appliedPerHour {
            appliedPerHour = perHour
            engine?.setPerHour(perHour, at: now)
        }
        let course = fix.course >= 0 ? fix.course : nil
        let buzz = engine?.evaluate(places: feed.places, position: position, accuracy: fix.horizontalAccuracy,
                                    course: course, now: now)
        if let buzz { deliver(buzz, position: position, course: course, at: now) }
        refreshActivity(now: now)
    }

    /// Shows the status on the Live Activity; it only changes with the buzz count or the GPS state, and is pushed
    /// again now and then to move its stale date on.
    private func refreshActivity(now: Date) {
        guard isOn, let startedAt,
              let text = WalkingStatus.text(isOn: true, lastFixAt: lastFixAt, buzzCount: buzzCount, now: now) else { return }
        activity.updateStatus(text, buzzCount: buzzCount,
                              staleDate: WalkingStatus.activityStaleDate(lastFixAt: lastFixAt, startedAt: startedAt))
    }

    // MARK: - Route

    /// Looks up the street at the newest route sample (8 s limit) and records it, a failure as nil (skipped, not
    /// retried). A lookup that returns in a later run records nothing and leaves that run's flag alone.
    private func lookUpStreet(at position: Coordinate) {
        let run = runToken
        streetLookupInFlight = true
        Task { [weak self] in
            let address = await Self.address(at: position)
            guard let self, self.runToken == run else { return }
            self.streetLookupInFlight = false
            self.route.recordLookup(address, at: .now)
        }
    }

    /// The walk context for a story at `position`: the remembered address when one is within 50 m, else a fresh
    /// lookup (nil after a failure or 8 s), with the route's direction (else `course`) and where the walker came from.
    private func walkContext(at position: Coordinate, course: Double?) async -> WalkContext {
        let address: Address?
        if let remembered = route.recentAddress(near: position) {
            address = remembered
        } else {
            address = await Self.address(at: position)
        }
        return route.context(address: address, course: course, now: .now)
    }

    // MARK: - Stops

    /// The owner has stayed put: tell a short story about the spot (design 7.6). No GPS course while standing still:
    /// the direction is the one walked in, from the route.
    private func tellStop(at spot: Coordinate) {
        let run = runToken
        stories.prepareStop(position: spot, nearby: feed.places, language: Self.storyLanguage(),
                            context: { [weak self] in
                                await self?.walkContext(at: spot, course: nil)
                                    ?? WalkContext(address: nil, bearing: nil, street: nil, cameFrom: nil)
                            },
                            ready: { [weak self] story in self?.deliverStop(story, run: run) })
    }

    /// Live Activity first (it can be updated from the background); a notification only when that fails. The route
    /// starts afresh: after a stop story, "came from" is left out until the walker has walked on (spec 6.5).
    private func deliverStop(_ story: WalkStory, run: UUID?) {
        guard isOn, runToken == run else { return }
        route.reset()
        // No sound over a story that is playing.
        let quiet = stories.listening != nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await activity.showStop(story, quiet: quiet)
            } catch {
                guard isOn, runToken == run else { return }
                do { try await BuzzNotifier.postStop(story, quiet: quiet) } catch { AppServices.logMemoryFailure("stop post failed", error) }
            }
        }
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
        stories.prepare(buzz, position: position, nearby: feed.places, language: Self.storyLanguage(),
                        context: { [weak self] in
                            await self?.walkContext(at: position, course: course)
                                ?? WalkContext(address: nil, bearing: course, street: nil, cameFrom: nil)
                        })
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
            // Never `.timeSensitiveOff` on this build: the free developer account cannot sign the Time Sensitive
            // Notifications entitlement, so the setting is always off and would block walking mode for good.
            // Restore `settings.timeSensitiveSetting == .disabled ? .timeSensitiveOff : .allowed` when the paid
            // account exists.
            return .allowed
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
        return await address(at: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))?.city
    }

    /// The address at `coordinate`, or nil when the lookup fails or it takes longer than 8 s.
    private static func address(at coordinate: Coordinate) async -> Address? {
        let once = OnceBox<Address?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Address?, Never>) in
                once.install(continuation)
                // MapKit's request ignores cancellation, so neither task is awaited: whichever finishes first resumes.
                Task {
                    let address = try? await MapKitReverseGeocoder().address(for: coordinate)
                    once.resume(address)
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
