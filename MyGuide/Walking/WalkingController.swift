import CoreLocation
import MyGuideCore
import Observation
import os
import SwiftUI
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
/// A memory failure is logged and never stops walking mode. Each run writes its walk log (spec 4), and pauses itself
/// while the walker stays still (spec 5).
@MainActor
@Observable
final class WalkingController {
    nonisolated static let buzzesPerHourKey = "buzzesPerHour"
    private static let trackFlushCount = 20
    /// Samples kept while saving keeps failing; the oldest go first.
    private static let trackLimit = 400
    private static let geocodeTimeout: Duration = .seconds(8)
    /// The pause, resume and GPS check runs every tick; auto-off and the Live Activity push every 4th (spec 5.6).
    private static let tickInterval: Duration = .seconds(15)
    private static let ticksPerAutoOff = 4

    private(set) var isOn = false
    /// Why walking mode did not start (or stopped); empty when nothing is in the way.
    private(set) var problems: [String] = []
    private(set) var buzzCount = 0
    /// The time of the last fix the buzz engine could use; nil until one arrives. Not updated while paused.
    private(set) var lastFixAt: Date?
    /// True while walking mode is paused: no buzzes, fetches, stop detection, track or route (spec 5.4).
    private(set) var isPaused = false
    /// The walking stories: prepared at buzz time, played, continued and skipped.
    let stories: WalkingStories

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let walkLog: WalkLog
    @ObservationIgnored private let makeSource: () -> WalkingPlaceSource
    @ObservationIgnored private let hasAPIKey: () -> Bool
    @ObservationIgnored private let location = WalkingLocation()
    @ObservationIgnored private let motion = WalkingMotion()
    /// One per run, made at start and never rebuilt: it holds the pause position and the walking streak.
    @ObservationIgnored private var pauseDetector: PauseDetector?
    /// When the pause in progress began; nil while active.
    @ObservationIgnored private var pausedSince: Date?
    /// The length of this run's finished pauses, which do not count toward the 4-hour limit.
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    /// The last motion reading, so a `motion` line is written only when the activity or confidence changes.
    @ObservationIgnored private var lastMotion: MotionReading?
    /// The run's stop spots (earlier runs of the trip, then each stop told), for a fresh stop detector on resume.
    @ObservationIgnored private var stopSpots: [Coordinate] = []
    @ObservationIgnored private var engine: BuzzEngine?
    @ObservationIgnored private var stopDetector: StopDetector?
    @ObservationIgnored private let activity = WalkingActivityController()
    @ObservationIgnored private var appliedPerHour = BuzzBudget.defaultPerHour
    @ObservationIgnored private var feed = PlaceFeed()
    @ObservationIgnored private var source: WalkingPlaceSource?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// The run's 15 s timer: pause and resume, GPS state, auto-off and the Live Activity, for the stretches without
    /// fixes or motion readings.
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var tripID: UUID?
    @ObservationIgnored private var track: [TrackSample] = []
    /// The last sample kept for the track (flushed or not), so `TrackSample.isWorthStoring` thins across flushes.
    @ObservationIgnored private var lastTrackSample: TrackSample?
    /// The recent walk and its street lookups, for the stories' direction, position and "came from" (spec 6.4–6.5).
    /// In memory only; reset when a stop is detected, after a stop story and when walking mode starts or stops.
    @ObservationIgnored private var route = RouteMemory()
    /// Counts route resets, so a lookup started before a reset records nothing into the fresh route.
    @ObservationIgnored private var routeGeneration = 0
    /// True while a street lookup for the current route runs: `RouteMemory.needsStreetLookup` stays true until it is
    /// recorded.
    @ObservationIgnored private var streetLookupInFlight = false
    /// The candidate of every buzz posted this run, so a skip still retires the place when its buzz was never logged.
    @ObservationIgnored private var postedCandidates: [UUID: Candidate] = [:]
    /// Identifies the start in progress; `stop()` clears it so a start that is waiting on a prompt gives up.
    @ObservationIgnored private var startToken: UUID?
    /// Identifies the current run (start to stop), so work begun in an earlier run never touches this one.
    @ObservationIgnored private var runToken: UUID?
    /// The last fix written to the walk log (logged or dropped), so the log thins like the track, on its own.
    @ObservationIgnored private var lastLoggedSample: TrackSample?
    /// The GPS state last written to the walk log. A run starts waiting for GPS, so its first `gps` line is `found`.
    /// Nil after a resume: the state is judged afresh and written.
    @ObservationIgnored private var loggedGPS: Bool? = false
    /// The app state last written to the walk log. A run starts in the foreground (the owner tapped Walk).
    @ObservationIgnored private var loggedForeground = true
    /// Failures during a start, before the run's log is open; written right after its `started` line.
    @ObservationIgnored private var startFailures: [WalkLogEvent] = []

    init(memory: MemoryStore, stories: WalkingStories, walkLog: WalkLog, makeSource: @escaping () -> WalkingPlaceSource,
         hasAPIKey: @escaping () -> Bool) {
        self.memory = memory
        self.walkLog = walkLog
        self.stories = stories
        self.makeSource = makeSource
        self.hasAPIKey = hasAPIKey
        // No buzz while a story is preparing, being continued or playing.
        stories.onBusyChanged = { [weak self] busy in self?.engine?.isBusy = busy }
        stories.onHeard = { [weak self] placeID in self?.noteHeard(placeID: placeID) }
        stories.onRetire = { [weak self] id, candidate, level in self?.retire(id, candidate: candidate, deepestLevel: level) }
        stories.currentTripID = { [weak self] in self?.tripID }
        stories.currentPlaces = { [weak self] in self?.feed.places ?? [] }
        stories.walkLog = walkLog
        activity.onFailure = { [weak self] context, error in self?.logFailure(context, error) }
        location.onLocation = { [weak self] fix in self?.handle(fix) }
        location.onDenied = { [weak self] in
            guard let self, isOn else { return }
            stop(reason: .locationDenied)
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
        startFailures = []
        defer { if startToken == token { startToken = nil } }

        // Ask while something is undetermined, then judge.
        if location.authorization == .notDetermined { await location.requestWhenInUse() }
        if await Self.notificationState() == .notDetermined {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                fail("notification permission request failed", error)
            }
        }
        guard startToken == token else { return }

        let state = await readiness()
        problems = state.problems
        guard startToken == token,
              WalkingReadiness.canStart(location: state.location, notifications: state.notifications,
                                        hasAPIKey: state.hasAPIKey) else { return }
        // Motion before the Always upgrade, waiting for the answer so the two prompts never overlap (spec 5.1).
        await motion.requestPermissionIfNeeded()
        guard startToken == token else { return }
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
        do { try memory.closePendingBuzzes() } catch { fail("closing pending buzzes failed", error) }
        let city = await Self.city(near: location.lastKnown)
        guard startToken == token else {
            if let activityID { activity.end(id: activityID) }
            return
        }
        let trip: UUID
        do {
            trip = try memory.touchTrip(now: now, city: city).id
        } catch {
            fail("trip update failed", error)
            trip = UUID()
        }
        tripID = trip
        var excluded = Set<String>()
        do { excluded.formUnion(try memory.retiredPlaceIDs()) } catch { fail("retired places failed", error) }
        do { excluded.formUnion(try memory.placeIDsBuzzed(tripID: trip)) } catch { fail("buzzed places failed", error) }

        stopSpots = []
        do { stopSpots = try memory.stopSpots(tripID: trip) } catch { fail("stop spots failed", error) }
        stopDetector = StopDetector(previousStops: stopSpots)
        pauseDetector = PauseDetector(now: now, motionAvailable: WalkingMotion.permission == .authorized)
        pausedTotal = 0
        pausedSince = nil
        isPaused = false
        lastMotion = nil

        appliedPerHour = Self.configuredPerHour()
        var engine = BuzzEngine(perHour: appliedPerHour, now: now, excluded: excluded)
        // A story from before this run may still be playing or ending.
        engine.isBusy = stories.isBusy
        self.engine = engine
        let run = UUID()
        runToken = run
        walkLog.begin(runID: run, at: now)
        feed = PlaceFeed()
        source = makeSource()
        postedCandidates = [:]
        track = []
        lastTrackSample = nil
        lastLoggedSample = nil
        loggedGPS = false
        loggedForeground = true
        resetRoute()
        buzzCount = 0
        lastFixAt = nil
        startedAt = now
        UIDevice.current.isBatteryMonitoringEnabled = true
        isOn = true
        walkLog.log(.started(startFields(state)), at: now)
        for failure in startFailures { walkLog.log(failure.kind, at: failure.at) }
        startFailures = []
        location.setPaused(false)
        location.start()
        motion.start { [weak self] reading in self?.handleMotion(reading) }
        startTimer(run: run)
    }

    /// Turns walking mode off; `reason` goes into the walk log's `stopped` line.
    func stop(reason: WalkStopReason = .user) {
        stop(reason: reason, autoOffMessage: nil)
    }

    /// `autoOffMessage`, when given, is posted after the stop; its outcome is the last line of the run's log.
    private func stop(reason: WalkStopReason, autoOffMessage: String?) {
        startToken = nil
        guard isOn else { return }
        isOn = false
        runToken = nil
        timerTask?.cancel()
        timerTask = nil
        startedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        motion.stop()
        location.setPaused(false)
        location.stop()
        isPaused = false
        pausedSince = nil
        pausedTotal = 0
        pauseDetector = nil
        lastMotion = nil
        stopSpots = []
        flushTrack()
        resetRoute()
        do { try memory.closePendingBuzzes() } catch { fail("closing pending buzzes failed", error) }
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
        walkLog.log(.stopped(reason))
        if let autoOffMessage {
            walkLog.end(posting: .autoOff, id: nil, { try await BuzzNotifier.postAutoOff(autoOffMessage) },
                        // Memory log only: the run is over, and its `notifyFailed` line already holds the error.
                        onError: { AppServices.logMemoryFailure("auto-off notification failed", $0) })
        } else {
            walkLog.end()
        }
    }

    /// Writes the app's foreground and background changes while walking mode is on; `.inactive` is ignored.
    func noteScenePhase(_ phase: ScenePhase) {
        guard isOn else { return }
        let foreground: Bool
        switch phase {
        case .active: foreground = true
        case .background: foreground = false
        default: return
        }
        guard foreground != loggedForeground else { return }
        loggedForeground = foreground
        walkLog.log(.app(foreground: foreground))
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
                do { try memory.markSkipped(candidate, at: now) } catch { fail("skip failed", error) }
            } else {
                fail("skip failed", error)
            }
        }
        if let candidate { engine?.exclude(candidate.id) }
        engine?.noteSkip(at: now)
    }

    // MARK: - Timer and auto-off

    /// One 15 s loop per run. A tick from an earlier run (or after stop) returns.
    private func startTimer(run: UUID) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self, self.isOn, self.runToken == run else { return }
                ticks += 1
                self.tick(ticks, now: .now)
            }
        }
    }

    /// Every tick: the pause and resume check, then the GPS state. Every 4th tick: auto-off and the Live Activity
    /// (which moves its stale date on, also while paused).
    private func tick(_ count: Int, now: Date) {
        applyPause(pauseDetector?.tick(now: now), now: now)
        noteGPS(now: now)
        guard count % Self.ticksPerAutoOff == 0 else { return }
        checkAutoOff(now: now)
        refreshActivity(now: now)
    }

    /// Turns walking mode off after 4 hours of active time (pauses do not count), after an hour paused, or when the
    /// battery runs low, and says why in a notification.
    private func checkAutoOff(now: Date) {
        guard isOn, let startedAt,
              let reason = AutoOff.reason(activeTime: AutoOff.activeTime(startedAt: startedAt, now: now, pausedTotal: pausedTotal,
                                                                         pausedSince: pausedSince),
                                          pausedFor: pausedSince.map { now.timeIntervalSince($0) },
                                          batteryLevel: UIDevice.current.batteryLevel)
        else { return }
        let stopReason: WalkStopReason = switch reason {
        case .timeLimit: .timeLimit
        case .lowBattery: .lowBattery
        case .pausedTooLong: .pausedTooLong
        }
        stop(reason: stopReason, autoOffMessage: AutoOff.message(reason))
    }

    // MARK: - Pause

    /// A motion reading: logged when the activity or confidence changed, then fed to the pause rules.
    private func handleMotion(_ reading: MotionReading) {
        guard isOn, pauseDetector != nil else { return }
        if reading.activity != lastMotion?.activity || reading.confidence != lastMotion?.confidence {
            walkLog.log(.motion(reading.activity, confidence: reading.confidence), at: reading.at)
        }
        lastMotion = reading
        applyPause(pauseDetector?.motion(isWalking: reading.isWalking, at: reading.at), now: reading.at)
    }

    private func applyPause(_ change: PauseChange?, now: Date) {
        guard isOn else { return }
        switch change {
        case .pause(let trigger, let anchor): enterPause(trigger: trigger, anchor: anchor, now: now)
        case .resume(let trigger): leavePause(trigger: trigger, now: now)
        case nil: break
        }
    }

    /// The one way into a pause: coarse location, the `paused` line, and "Paused" on the Live Activity with a stale
    /// date the 60 s push keeps moving on. A story playing or preparing goes on.
    private func enterPause(trigger: PauseTrigger, anchor: Coordinate?, now: Date) {
        guard !isPaused else { return }
        isPaused = true
        pausedSince = now
        location.setPaused(true)
        walkLog.log(.paused(trigger, at: anchor), at: now)
        walkLog.resetQuiet()
        refreshActivity(now: now)
    }

    /// The one way out of a pause: best location again, and the route, stop detector (with the run's stop spots),
    /// track thinning and GPS state start afresh, so the next fix is judged as usual (spec 5.4).
    private func leavePause(trigger: PauseTrigger, now: Date) {
        guard isPaused else { return }
        let paused = pausedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        pausedTotal += paused
        pausedSince = nil
        isPaused = false
        location.setPaused(false)
        resetRoute()
        stopDetector = StopDetector(previousStops: stopSpots)
        lastTrackSample = nil
        loggedGPS = nil
        walkLog.log(.resumed(trigger, pausedSeconds: paused), at: now)
        walkLog.resetQuiet()
        refreshActivity(now: now)
    }

    // MARK: - Fixes

    private func handle(_ fix: CLLocation) {
        let now = Date.now
        checkAutoOff(now: now)
        guard isOn, engine != nil else { return }
        // CoreLocation's first fix can be its cached position from minutes ago: not where the walker is.
        guard fix.horizontalAccuracy >= 0, WalkingFix.isFresh(fix.timestamp, now: now) else {
            logFix(fix, dropped: fix.horizontalAccuracy < 0 ? .invalid : .stale, at: now)
            noteGPS(now: now)
            return
        }
        let position = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        // While paused a fix only goes to the resume rule and the log: no engine, feed, stop detector, track, route
        // or `lastFixAt` (spec 9.3).
        if isPaused {
            let change = pauseDetector?.fix(position: position, accuracy: fix.horizontalAccuracy, at: now)
            logFix(fix, dropped: nil, at: now)
            applyPause(change, now: now)
            return
        }
        // The status says "waiting for GPS" until a fix the engine can use arrives.
        if WalkingFix.isUsable(accuracy: fix.horizontalAccuracy) { lastFixAt = fix.timestamp }
        logFix(fix, dropped: nil, at: now)
        noteGPS(now: now)

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
            walkLog.log(.stopDetected(spot), at: now)
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
        // The buzz's side ("50 m left") and its story use the same direction: the route's, else the GPS course
        // (spec 6.4). The route was fed above, so it has this fix when it counts as a route fix.
        let direction = route.walkingBearing ?? course
        switch engine?.decide(places: feed.places, position: position, accuracy: fix.horizontalAccuracy,
                              course: direction, now: now) {
        case .buzz(let buzz):
            walkLog.log(.buzz(WalkLogBuzz(buzz)), at: now)
            walkLog.resetQuiet()
            deliver(buzz, position: position, direction: direction, at: now)
        case .quiet(let reason, let due):
            walkLog.logQuiet(reason, due: due, at: now)
        case nil:
            break
        }
        refreshActivity(now: now)
        applyPause(pauseDetector?.fix(position: position, accuracy: fix.horizontalAccuracy, at: now), now: now)
    }

    /// Writes a fix to the walk log, thinned like the stored track (one per 5 m or per minute) but on its own state.
    /// `dropped` marks a fix the controller does not use; `paused` one taken while paused. Unknown speed and course
    /// (negative) are written as null.
    private func logFix(_ fix: CLLocation, dropped: FixDrop?, at now: Date) {
        let position = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        let sample = TrackSample(at: fix.timestamp, coordinate: position)
        guard TrackSample.isWorthStoring(sample, after: lastLoggedSample) else { return }
        lastLoggedSample = sample
        walkLog.log(.fix(WalkLogFix(coordinate: position, accuracy: fix.horizontalAccuracy,
                                    speed: fix.speed >= 0 ? fix.speed : nil, course: fix.course >= 0 ? fix.course : nil,
                                    paused: isPaused, dropped: dropped)), at: now)
    }

    /// Writes `gps` when the status changes between waiting for GPS and having GPS. Nothing while paused.
    private func noteGPS(now: Date) {
        guard isOn, !isPaused else { return }
        let found = WalkingStatus.text(isOn: true, lastFixAt: lastFixAt, buzzCount: buzzCount, now: now, paused: false)
            != WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: buzzCount, now: now, paused: false)
        guard found != loggedGPS else { return }
        loggedGPS = found
        walkLog.log(.gps(found: found), at: now)
    }

    /// Shows the status on the Live Activity; it only changes with the buzz count, the GPS state or a pause, and is
    /// pushed again now and then to move its stale date on. While paused the stale date is now + 120 s.
    private func refreshActivity(now: Date) {
        guard isOn, let startedAt,
              let text = WalkingStatus.text(isOn: true, lastFixAt: lastFixAt, buzzCount: buzzCount, now: now, paused: isPaused)
        else { return }
        let stale = isPaused ? WalkingStatus.pausedStaleDate(now: now)
                             : WalkingStatus.activityStaleDate(lastFixAt: lastFixAt, startedAt: startedAt)
        activity.updateStatus(text, buzzCount: buzzCount, staleDate: stale)
    }

    // MARK: - Route

    /// Looks up the street at the newest route sample (8 s limit) and records it, a failure as nil (skipped, not
    /// retried). A lookup that returns in a later run or after a route reset records nothing and leaves the flag of
    /// the newer route alone.
    private func lookUpStreet(at position: Coordinate) {
        let run = runToken, generation = routeGeneration
        streetLookupInFlight = true
        Task { [weak self] in
            let address = await Self.address(at: position)
            guard let self, self.runToken == run, self.routeGeneration == generation else { return }
            self.streetLookupInFlight = false
            self.route.recordLookup(address, at: .now)
        }
    }

    /// Starts the route afresh. A street lookup still running belongs to the old route: it records nothing, and the
    /// new route may start its own.
    private func resetRoute() {
        route.reset()
        routeGeneration += 1
        streetLookupInFlight = false
    }

    /// The walk context for a story at `position`, from `snapshot` (the route when the story was triggered, at `now`):
    /// its remembered address when one is within 50 m, else a fresh lookup (nil after a failure or 8 s), with its
    /// direction (else `course`) and where the walker came from. A fresh address is recorded in the live route when it
    /// is still run `run` and route `generation` and no street lookup is running, so the street is not looked up again.
    private func walkContext(at position: Coordinate, course: Double?, snapshot: RouteMemory, generation: Int,
                             run: UUID?, now: Date) async -> WalkContext {
        let address: Address?
        if let remembered = snapshot.recentAddress(near: position) {
            address = remembered
        } else {
            address = await Self.address(at: position)
            if let address, runToken == run, routeGeneration == generation, !streetLookupInFlight {
                route.recordLookup(address, at: .now, near: position)
            }
        }
        return snapshot.context(address: address, course: course, now: now)
    }

    // MARK: - Stops

    /// The owner has stayed put: tell a short story about the spot (design 7.6). No GPS course while standing still:
    /// the direction is the one walked in, from the route as it was at the stop. The route then starts afresh: after
    /// a stop, "came from" is left out until the walker has walked on (spec 6.5).
    private func tellStop(at spot: Coordinate) {
        stopSpots.append(spot)
        let run = runToken, now = Date.now
        let snapshot = route
        resetRoute()
        let generation = routeGeneration
        stories.prepareStop(position: spot, nearby: feed.places, language: Self.storyLanguage(),
                            context: { [weak self] in
                                await self?.walkContext(at: spot, course: nil, snapshot: snapshot,
                                                        generation: generation, run: run, now: now)
                                    ?? WalkContext(address: nil, bearing: nil, street: nil, cameFrom: nil)
                            },
                            ready: { [weak self] story in self?.deliverStop(story, run: run) })
    }

    /// Live Activity first (it can be updated from the background); a notification only when that fails. The route
    /// starts afresh again: "came from" stays out until the walker walks on after the story.
    private func deliverStop(_ story: WalkStory, run: UUID?) {
        guard isOn, runToken == run else { return }
        resetRoute()
        // No sound over a story that is playing.
        let quiet = stories.listening != nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await activity.showStop(story, quiet: quiet)
                if isOn, runToken == run { walkLog.log(.stopShown(via: .liveActivity)) }
            } catch {
                guard isOn, runToken == run else { return }
                do {
                    try await walkLog.posting(.stop, id: story.id) { try await BuzzNotifier.postStop(story, quiet: quiet) }
                    if isOn, runToken == run { walkLog.log(.stopShown(via: .notification)) }
                } catch {
                    fail("stop post failed", error)
                }
            }
        }
    }

    private func deliver(_ buzz: Buzz, position: Coordinate, direction: Double?, at now: Date) {
        postedCandidates[buzz.id] = buzz.place.candidate
        if let tripID {
            do { try memory.recordBuzz(buzz, tripID: tripID, at: now) } catch { fail("buzz record failed", error) }
        }
        buzzCount += 1
        let run = runToken
        Task { [weak self] in
            guard let self, self.isOn, self.runToken == run else { return }
            do {
                try await self.walkLog.posting(.buzz, id: buzz.id) { try await BuzzNotifier.post(buzz) }
            } catch {
                self.fail("buzz post failed", error)
                return
            }
            // stop() may have cleared the notifications while this one was being added: take it back.
            if !self.isOn || self.runToken != run { BuzzNotifier.removeNotifications(for: buzz.id) }
        }
        // Prepared at once, so a tap plays within a second or two (design 7.5). This makes the engine busy. The context
        // comes from the route as it is now, so its direction is `direction`, the one the buzz was worded with.
        let snapshot = route, generation = routeGeneration
        stories.prepare(buzz, position: position, nearby: feed.places, language: Self.storyLanguage(),
                        context: { [weak self] in
                            await self?.walkContext(at: position, course: direction, snapshot: snapshot,
                                                    generation: generation, run: run, now: now)
                                ?? WalkContext(address: nil, bearing: direction, street: nil, cameFrom: nil)
                        })
    }

    private func fetch(around position: Coordinate, now: Date) {
        guard let source else { return }
        feed.fetchStarted(now: now)
        walkLog.log(.fetchStarted(position), at: now)
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
                self.walkLog.log(WalkLogEvent.fetched(places, around: position))
            case .failure(let error) where !(error is CancellationError) && !Task.isCancelled:
                // A real failure waits 60 s before the next try.
                self.feed.fetchFailed(now: .now)
                self.walkLog.log(.fetchFailed(error: WalkLogEvent.errorText(error)))
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
            fail("track save failed", error)
            // A failed save rolls back, so the samples can be retried with the next flush.
            if track.count > Self.trackLimit { track.removeFirst(track.count - Self.trackLimit) }
        }
    }

    // MARK: - Failures

    /// Logs a failure without any story text: to the memory log, and to the walk log.
    private func fail(_ context: String, _ error: Error) {
        AppServices.logMemoryFailure(context, error)
        logFailure(context, error)
    }

    /// Writes `failure` to the walk log. During a start, before the run's log is open, it is kept for the run.
    private func logFailure(_ context: String, _ error: Error) {
        let kind = WalkLogEvent.Kind.failure(context: context, error: WalkLogEvent.errorText(error))
        if !isOn, startToken != nil {
            startFailures.append(WalkLogEvent(at: .now, kind: kind))
        } else {
            walkLog.log(kind)
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

    /// The `started` line: app version and build, the permissions as judged for this start, and the settings.
    private func startFields(_ state: Readiness) -> WalkLogStart {
        let info = Bundle.main.infoDictionary
        let location: LocationPermission = switch state.location {
        case .always: .always
        case .whenInUse: .whenInUse
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
        let notifications: NotificationPermission = switch state.notifications {
        case .allowed, .timeSensitiveOff: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
        // -1 means unknown (the simulator, or monitoring not ready yet). Two decimals: the level comes in 1 % steps.
        let level = UIDevice.current.batteryLevel
        let battery = level < 0 ? nil : (Double(level) * 100).rounded() / 100
        return WalkLogStart(appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
                            build: info?["CFBundleVersion"] as? String ?? "",
                            location: location, notifications: notifications,
                            liveActivities: WalkingActivityController.areActivitiesEnabled,
                            motion: WalkingMotion.permission, perHour: appliedPerHour, battery: battery)
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
