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
    /// Set on every delivered buzz; the map selects this place explicitly when the app is active (spec 12.2).
    private(set) var lastBuzz: (placeID: String, at: Date)?
    /// Why the engine stayed quiet at the last fix; nil after a buzz, before the first decision and while off.
    private(set) var lastQuietReason: QuietReason?
    /// True while walking mode is on, not paused, and the engine is quiet because every due place is used (spec 13.7).
    var heardEverythingNearby: Bool { isOn && !isPaused && lastQuietReason == .allExcluded }
    /// The pause in progress: `auto` from the pause detector, `manual` from the owner's Pause (phone or watch), which
    /// holds until Resume. Nil while active. While paused: no buzzes, fetches, stop detection, track or route (spec 5.4).
    private(set) var pauseKind: WalkingPauseKind?
    /// True while walking mode is paused, by either kind.
    var isPaused: Bool { pauseKind != nil }
    /// True from a start's first line until it returns (or `stop()` cancels it).
    var isStarting: Bool { startToken != nil }
    /// Called with the walk state after every change to it other than `sentAt` (spec 5.1); the watch link sends it on.
    @ObservationIgnored var onStateChange: ((GuidedWalkState) -> Void)?
    /// Called with the start's source once a start has succeeded (walking mode is on); not for a refused or cancelled
    /// start. A phone start launches the watch app through it (spec 5.3).
    @ObservationIgnored var onStarted: ((WalkSource) -> Void)?
    /// Called with each list this run's own network refresh returned (not with a list taken over unchanged); the app
    /// fetches its pictures ahead (spec 12.6).
    @ObservationIgnored var onListRefreshed: ((NearbyList) -> Void)?
    /// Called with each delivered buzz, after it is recorded and its notification is on its way (never before or in
    /// place of it); the watch link sends it straight to a guided walk on the watch (spec 18). The line is in the
    /// iPhone's screen language, as on the notification.
    @ObservationIgnored var onBuzzDelivered: ((GuidedWalkBuzz) -> Void)?
    /// The walking stories: their text prepared at buzz time, played, continued and skipped.
    let stories: WalkingStories

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let walkLog: WalkLog
    /// The shared nearby list; walking mode refreshes it at 250 m and walks with its tiered places.
    @ObservationIgnored private let nearby: NearbyPlaces
    @ObservationIgnored private let hasAPIKey: () -> Bool
    @ObservationIgnored private let location = WalkingLocation()
    @ObservationIgnored private let motion = WalkingMotion()
    /// One per run, made at start and never rebuilt: it holds the pause position and the walking streak.
    @ObservationIgnored private var pauseDetector: PauseDetector?
    /// When the pause in progress began; nil while active.
    @ObservationIgnored private var pausedSince: Date?
    /// The length of this run's finished pauses, which do not count toward the 4-hour limit.
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    /// What started the auto-pause in progress, for the `resumed` line of a resume by command; nil otherwise.
    @ObservationIgnored private var autoPauseTrigger: PauseTrigger?
    /// Why the last start without prompts did not start; on the walk state until the next start (spec 5.3).
    @ObservationIgnored private var startProblem: String?
    /// The last walk state handed to `onStateChange`, with `sentAt` blanked, so only real changes are sent.
    @ObservationIgnored private var lastSentState: GuidedWalkState?
    /// The last motion reading, so a `motion` line is written only when the activity or confidence changes.
    @ObservationIgnored private var lastMotion: MotionReading?
    /// The run's stop spots (earlier runs of the trip, then each stop told), for a fresh stop detector on resume.
    @ObservationIgnored private var stopSpots: [Coordinate] = []
    @ObservationIgnored private var engine: BuzzEngine?
    @ObservationIgnored private var stopDetector: StopDetector?
    @ObservationIgnored private let activity = WalkingActivityController()
    @ObservationIgnored private var appliedPerHour = BuzzBudget.defaultPerHour
    @ObservationIgnored private var feed = PlaceFeed()
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// The run's 15 s timer: pause and resume, GPS state, auto-off and the Live Activity, for the stretches without
    /// fixes or motion readings.
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    /// When the last pause ended; nil until one has. With `startedAt` the floor of the Live Activity's stale date, as
    /// `lastFixAt` stood still through the pause.
    @ObservationIgnored private var resumedAt: Date?
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
    /// Observed: `isStarting` reads it.
    private var startToken: UUID?
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

    init(memory: MemoryStore, stories: WalkingStories, walkLog: WalkLog, nearby: NearbyPlaces,
         hasAPIKey: @escaping () -> Bool) {
        self.memory = memory
        self.walkLog = walkLog
        self.stories = stories
        self.nearby = nearby
        self.hasAPIKey = hasAPIKey
        // No buzz while a story is preparing, being continued or playing.
        stories.onBusyChanged = { [weak self] busy in self?.engine?.isBusy = busy }
        stories.onHeard = { [weak self] placeID in self?.noteHeard(placeID: placeID) }
        stories.onChosenHeard = { [weak self] candidate in self?.noteChosenHeard(candidate) }
        stories.onRetire = { [weak self] id, candidate, level in self?.retire(id, candidate: candidate, deepestLevel: level) }
        stories.currentTripID = { [weak self] in self?.tripID }
        stories.currentPlaces = { [weak self] in self?.feed.places ?? [] }
        stories.walkLog = walkLog
        activity.onFailure = { [weak self] context, error in self?.logFailure(context, error) }
        // The Live Activity shows the place whose story is playing (spec 7.5); it has none while walking mode is off.
        stories.onPlaybackStarted = { [weak self] candidate in self?.activity.showPlace(candidate) }
        location.onLocation = { [weak self] fix in self?.handle(fix) }
        location.onDenied = { [weak self] in
            guard let self, isOn else { return }
            stop(reason: .locationDenied, source: nil)
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

    nonisolated private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "walking")

    /// The problem text of a start without prompts that cannot start (spec 5.3). It goes to the watch in English and
    /// is shown there in the watch's language (`WalkingReadiness.localized`).
    static let setupProblem = WalkingReadiness.setupProblem

    /// Starts walking mode. Returns why it did not start, or nil when it started, was already on or starting, or was
    /// cancelled by `stop()`.
    ///
    /// `interactive: false` (a start from the watch, maybe with the app in the background) never shows a prompt: it
    /// needs location Always, notifications allowed and the key, else it returns `setupProblem` at once, which the
    /// walk state carries until the next start. Motion stays as granted (spec 10.2).
    @discardableResult
    func start(source: WalkSource = .phone, interactive: Bool = true) async -> String? {
        guard !isOn, startToken == nil else { return nil }
        let token = UUID()
        startToken = token
        startFailures = []
        startProblem = nil
        publishState()
        // Every way out (started, refused, cancelled) ends the start and sends the state.
        defer {
            if startToken == token { startToken = nil }
            publishState()
        }

        if interactive {
            // Ask while something is undetermined, then judge.
            if location.authorization == .notDetermined { await location.requestWhenInUse() }
            if await Self.notificationState() == .notDetermined {
                do {
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                } catch {
                    fail("notification permission request failed", error)
                }
            }
            guard startToken == token else { return nil }
        }

        let state = await readiness()
        guard startToken == token else { return nil }
        if !interactive {
            // Background location updates cannot start with When In Use, so Always is needed (spec 10.2).
            let notificationsReady = state.notifications == .allowed || state.notifications == .timeSensitiveOff
            guard state.location == .always, notificationsReady, state.hasAPIKey else {
                // Only the walk state carries it: nobody asked on the phone, so its `problems` stay as they were.
                // No run (and no walk log) exists yet, so the refusal goes to the system log; no personal data.
                Self.log.notice("""
                    start without prompts refused: \(Self.setupProblem, privacy: .public) \
                    location \(String(describing: state.location), privacy: .public), \
                    notifications \(String(describing: state.notifications), privacy: .public), \
                    key \(state.hasAPIKey, privacy: .public)
                    """)
                startProblem = Self.setupProblem
                return Self.setupProblem
            }
        }
        problems = state.problems
        guard WalkingReadiness.canStart(location: state.location, notifications: state.notifications,
                                        hasAPIKey: state.hasAPIKey) else {
            return state.problems.first ?? Self.setupProblem
        }
        if interactive {
            // Motion before the Always upgrade, waiting for the answer so the two prompts never overlap (spec 5.1).
            await motion.requestPermissionIfNeeded()
            guard startToken == token else { return nil }
            // Only now: nothing blocks, so upgrading to Always is the one thing left to ask.
            location.requestAlways()
        }

        // First of all: a Live Activity can only be requested in the foreground, and the owner may lock the phone at
        // once. Any left over from an earlier launch end first. From the background (a watch start) it fails, which is
        // logged; the walk goes on without one (spec 5.3).
        let now = Date.now
        let activityID = await activity.start(at: now)
        guard startToken == token else {
            if let activityID { activity.end(id: activityID) }
            return nil
        }
        await BuzzNotifier.registerCategories()
        do { try memory.closePendingBuzzes() } catch { fail("closing pending buzzes failed", error) }
        let city = await Self.city(near: location.lastKnown)
        guard startToken == token else {
            if let activityID { activity.end(id: activityID) }
            return nil
        }
        let trip: UUID
        do {
            trip = try memory.touchTrip(now: now, city: city).id
        } catch {
            fail("trip update failed", error)
            trip = UUID()
        }
        tripID = trip
        // Only places heard, read or skipped in the last 30 days (spec 13.1). A buzz earlier in the trip that was
        // never read may come again (spec 13.3); within this run the engine excludes every place it buzzes.
        var excluded = Set<String>()
        do { excluded = try memory.retiredPlaceIDs(now: now) } catch { fail("retired places failed", error) }

        stopSpots = []
        do { stopSpots = try memory.stopSpots(tripID: trip) } catch { fail("stop spots failed", error) }
        stopDetector = StopDetector(previousStops: stopSpots)
        pauseDetector = PauseDetector(now: now, motionAvailable: WalkingMotion.permission == .authorized)
        pausedTotal = 0
        pausedSince = nil
        pauseKind = nil
        autoPauseTrigger = nil
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
        postedCandidates = [:]
        track = []
        lastTrackSample = nil
        lastLoggedSample = nil
        loggedGPS = false
        loggedForeground = true
        resetRoute()
        buzzCount = 0
        lastFixAt = nil
        lastQuietReason = nil
        startedAt = now
        resumedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = true
        isOn = true
        walkLog.log(.started(startFields(state, source: source)), at: now)
        for failure in startFailures { walkLog.log(failure.kind, at: failure.at) }
        startFailures = []
        // A story from before this run may hold the engine busy: the log says so from the start.
        stories.logBusyState()
        location.setPaused(false)
        location.start()
        motion.start { [weak self] reading in self?.handleMotion(reading) }
        startTimer(run: run)
        onStarted?(source)
        return nil
    }

    /// Turns walking mode off, or cancels a start in progress; `reason` and `source` (nil when automatic) go into the
    /// walk log's `stopped` line.
    func stop(reason: WalkStopReason = .user, source: WalkSource? = .phone) {
        stop(reason: reason, source: source, autoOffMessage: nil)
    }

    /// `autoOffMessage`, when given, is posted after the stop; its outcome is the last line of the run's log.
    private func stop(reason: WalkStopReason, source: WalkSource?, autoOffMessage: String?) {
        startToken = nil
        defer { publishState() }
        guard isOn else { return }
        isOn = false
        runToken = nil
        timerTask?.cancel()
        timerTask = nil
        startedAt = nil
        resumedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        motion.stop()
        location.setPaused(false)
        location.stop()
        pauseKind = nil
        autoPauseTrigger = nil
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
        lastQuietReason = nil
        stopDetector = nil
        problems = []
        activity.endCurrent()
        // Preparations and fetches still end with their (silent) failure events, so the machine never stays busy.
        stories.stopAll()
        Task { await BuzzNotifier.removeWalkNotifications() }
        walkLog.log(.stopped(reason, source: source))
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

    /// A level of a story about this place started playing, or its story was opened: it does not buzz again this run
    /// (memory rests it for 30 days).
    func noteHeard(placeID: String) {
        engine?.exclude(placeID)
    }

    /// The reset button (spec 13.5), after memory's `resetPlaceNotifications()`: the running engine forgets every
    /// exclusion, so every place nearby may buzz again in this run too. Nothing while walking mode is off.
    func resetExclusions() {
        engine?.clearExclusions()
        if lastQuietReason == .allExcluded { lastQuietReason = nil }
    }

    /// Called by `WalkingStories` when a level of a `.chosen` story starts playing: the place does not buzz this run.
    /// `WalkingStories` has already marked it heard in memory, which rests it for 30 days (spec 12.1, 13.1).
    func noteChosenHeard(_ place: Candidate) {
        engine?.exclude(place.id)
    }

    /// Tells a place chosen on the map (spec 12.1), with walking mode on or off; see `WalkingStories.tellPlace`.
    /// While walking mode is on, the walk context comes from the route, as for a buzz (no course: the place was not
    /// passed). While it is off there is no route: the context holds only the address at `position` (nil after a
    /// failed lookup or 8 s).
    func tellPlace(_ place: WalkingPlace, position: Coordinate, language: StoryLanguage) {
        let context: @MainActor @Sendable () async -> WalkContext
        if isOn, runToken != nil {
            let run = runToken, now = Date.now
            let snapshot = route, generation = routeGeneration
            context = { [weak self] in
                if let walk = await self?.walkContext(at: position, course: nil, snapshot: snapshot,
                                                      generation: generation, run: run, now: now) {
                    return walk
                }
                // The controller is gone: the address alone, as with walking mode off.
                return WalkContext(address: await Self.address(at: position), bearing: nil, street: nil, cameFrom: nil)
            }
        } else {
            context = {
                WalkContext(address: await Self.address(at: position), bearing: nil, street: nil, cameFrom: nil)
            }
        }
        stories.tellPlace(place, position: position, language: language, context: context)
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
        stop(reason: stopReason, source: nil, autoOffMessage: AutoOff.message(reason, language: UILanguage.current))
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

    /// The pause detector's output. Ignored during a manual pause (the held detector gives none anyway): only Resume
    /// ends it. A detector pause applies only while active, a detector resume only to an auto-pause.
    private func applyPause(_ change: PauseChange?, now: Date) {
        guard isOn, pauseKind != .manual else { return }
        switch change {
        case .pause(let trigger, let anchor):
            guard pauseKind == nil else { return }
            autoPauseTrigger = trigger
            enterPause(.auto, reason: WalkPauseReason(trigger), anchor: anchor, source: nil, now: now)
        case .resume(let trigger):
            guard pauseKind == .auto else { return }
            leavePause(reason: WalkPauseReason(trigger), source: nil, now: now)
        case nil: break
        }
    }

    /// The owner's Pause, from the phone or the watch (spec 4, 10.4). From walking it enters a manual pause; from an
    /// auto-pause the same pause turns manual: `pausedSince` is kept and one `paused` line with reason `manual` is
    /// written. Either way the detector is held, so walking or moving never ends it. Already manual or off: nothing.
    func pause(source: WalkSource) {
        guard isOn, pauseKind != .manual else { return }
        let now = Date.now
        if pauseKind == .auto {
            pauseKind = .manual
            autoPauseTrigger = nil
            pauseDetector?.hold()
            walkLog.log(.paused(.manual, at: currentAnchor(now: now), source: source), at: now)
            walkLog.resetQuiet()
            refreshActivity(now: now)
            publishState()
        } else {
            enterPause(.manual, reason: .manual, anchor: currentAnchor(now: now), source: source, now: now)
            pauseDetector?.hold()
        }
    }

    /// The owner's Resume, from the phone or the watch: ends either kind of pause as if the walker had moved. The
    /// detector is released and starts a fresh still stretch from now. The `resumed` reason is `manual` after a manual
    /// pause, else the trigger of the auto-pause. Not paused or off: nothing.
    func resume(source: WalkSource) {
        guard isOn, let kind = pauseKind else { return }
        let now = Date.now
        let reason: WalkPauseReason = kind == .manual ? .manual : autoPauseTrigger.map(WalkPauseReason.init) ?? .motion
        leavePause(reason: reason, source: source, now: now)
        pauseDetector?.release(now: now)
    }

    /// Where the walker is for a manual `paused` line: the last position CoreLocation knows, when it is fresh and
    /// accurate enough to anchor a pause (the detector's own rule, 50 m); else nil.
    private func currentAnchor(now: Date) -> Coordinate? {
        guard let fix = location.lastKnown, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= PauseDetector.maxStillAccuracy, WalkingFix.isFresh(fix.timestamp, now: now)
        else { return nil }
        return Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
    }

    /// The one way into a pause: coarse location, the track saved (nothing is held through a pause of up to an
    /// hour), the `paused` line, and the pause text on the Live Activity (also over a stop story) with a stale date the
    /// 60 s push keeps moving on. A story playing or preparing goes on.
    private func enterPause(_ kind: WalkingPauseKind, reason: WalkPauseReason, anchor: Coordinate?, source: WalkSource?,
                            now: Date) {
        guard pauseKind == nil else { return }
        pauseKind = kind
        pausedSince = now
        location.setPaused(true)
        flushTrack()
        walkLog.log(.paused(reason, at: anchor, source: source), at: now)
        walkLog.resetQuiet()
        activity.clearStop()
        refreshActivity(now: now)
        publishState()
    }

    /// The one way out of a pause: best location again, and the route, stop detector (with the run's stop spots),
    /// track thinning and GPS state start afresh, so the next fix is judged as usual (spec 5.4). The Live Activity
    /// shows the walking status again, with a stale date counted from now.
    private func leavePause(reason: WalkPauseReason, source: WalkSource?, now: Date) {
        guard pauseKind != nil else { return }
        let paused = pausedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        pausedTotal += paused
        pausedSince = nil
        pauseKind = nil
        autoPauseTrigger = nil
        location.setPaused(false)
        resetRoute()
        stopDetector = StopDetector(previousStops: stopSpots)
        lastTrackSample = nil
        loggedGPS = nil
        resumedAt = now
        walkLog.log(.resumed(reason, pausedSeconds: paused, source: source), at: now)
        walkLog.resetQuiet()
        activity.clearStop()
        refreshActivity(now: now)
        publishState()
    }

    // MARK: - Walk state

    /// The walk state as the watch sees it (spec 4), stamped now.
    var guidedWalkState: GuidedWalkState {
        let now = Date.now
        guard isOn else {
            if isStarting { return GuidedWalkState(phase: .starting, buzzCount: 0, startedAt: nil, problem: startProblem, sentAt: now) }
            return .off(sentAt: now, problem: startProblem)
        }
        let phase: GuidedWalkPhase = switch pauseKind {
        case nil: .walking
        case .auto: .pausedAuto
        case .manual: .pausedManual
        }
        return GuidedWalkState(phase: phase, buzzCount: buzzCount, startedAt: startedAt, pausedTotal: pausedTotal,
                               pausedSince: pausedSince, problem: startProblem, sentAt: now)
    }

    /// Hands the walk state to `onStateChange` when it differs from the last one handed over, `sentAt` aside. Called
    /// after every change to its inputs: start and its end, stop, pause, resume and the buzz count.
    private func publishState() {
        guard let onStateChange else { return }
        let state = guidedWalkState
        var unstamped = state
        unstamped.sentAt = .distantPast
        guard unstamped != lastSentState else { return }
        lastSentState = unstamped
        onStateChange(state)
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
        // or `lastFixAt` (spec 9.3). A fix that resumes is used at once: it goes on through the active path below.
        if isPaused {
            let change = pauseDetector?.fix(position: position, accuracy: fix.horizontalAccuracy, at: now)
            guard case .resume = change else {
                logFix(fix, dropped: nil, at: now)
                applyPause(change, now: now)
                return
            }
            applyPause(change, now: now)
            guard isOn, !isPaused, engine != nil else { return }
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
            if lastQuietReason != nil { lastQuietReason = nil }
            deliver(buzz, position: position, direction: direction, at: now)
        case .quiet(let reason, let due):
            walkLog.logQuiet(reason, due: due, at: now)
            // Set only on a change: every fix decides, and the panel redraws on each write.
            if lastQuietReason != reason { lastQuietReason = reason }
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
        let found = WalkingStatus.text(isOn: true, lastFixAt: lastFixAt, buzzCount: buzzCount, now: now)
            != WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: buzzCount, now: now)
        guard found != loggedGPS else { return }
        loggedGPS = found
        walkLog.log(.gps(found: found), at: now)
    }

    /// Shows the status on the Live Activity; it only changes with a pause or a resume (the buzz count clears a stop
    /// story), and is pushed again now and then to move its stale date on. While paused the stale date is now + 120 s;
    /// after a resume it counts from the resume at the earliest, as `lastFixAt` stood still through the pause.
    private func refreshActivity(now: Date) {
        guard isOn, let startedAt else { return }
        let floor = max(startedAt, resumedAt ?? startedAt)
        let stale = isPaused ? WalkingStatus.pausedStaleDate(now: now)
                             : WalkingStatus.activityStaleDate(lastFixAt: lastFixAt, startedAt: floor)
        activity.updateStatus(paused: isPaused, buzzCount: buzzCount, staleDate: stale)
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
                    try await walkLog.posting(.stop, id: story.id) {
                        try await BuzzNotifier.postStop(story, quiet: quiet, language: Self.storyLanguage())
                    }
                    if isOn, runToken == run { walkLog.log(.stopShown(via: .notification)) }
                } catch {
                    // Memory log only: the walk log's `notifyFailed` line already holds the error.
                    AppServices.logMemoryFailure("stop post failed", error)
                }
            }
        }
    }

    private func deliver(_ buzz: Buzz, position: Coordinate, direction: Double?, at now: Date) {
        postedCandidates[buzz.id] = buzz.place.candidate
        lastBuzz = (buzz.place.candidate.id, now)
        if let tripID {
            do { try memory.recordBuzz(buzz, tripID: tripID, at: now) } catch { fail("buzz record failed", error) }
        }
        buzzCount += 1
        publishState()
        // No alert on the Live Activity: the notification below alerts (spec 7.5).
        activity.showPlace(buzz.place.candidate)
        let run = runToken
        let language = Self.storyLanguage()
        Task { [weak self] in
            guard let self, self.isOn, self.runToken == run else { return }
            do {
                // The picture wait (at most 1.5 s) is part of the posting, so the walk log's timing includes it.
                try await self.walkLog.posting(.buzz, id: buzz.id) {
                    let picture = await BuzzNotifier.picture(for: buzz.place.candidate, from: AppServices.sharedPlaceImages)
                    try await BuzzNotifier.post(buzz, course: direction, language: language, picture: picture)
                }
            } catch {
                // Memory log only: the walk log's `notifyFailed` line already holds the error.
                AppServices.logMemoryFailure("buzz post failed", error)
                return
            }
            // stop() may have cleared the notifications while this one was being added: take it back.
            if !self.isOn || self.runToken != run { BuzzNotifier.removeNotifications(for: buzz.id) }
        }
        // After the posting task is made, so the watch never holds up the notification. Worded from the same course as
        // the notification's subtitle.
        if let onBuzzDelivered {
            let line = BuzzText.localizedDetail(distance: buzz.distance, bearing: buzz.bearing, course: direction,
                                                language: UILanguage.current)
            onBuzzDelivered(GuidedWalkBuzz(id: buzz.id, name: buzz.title, line: line, sentAt: .now))
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

    /// Brings the feed up to date through the shared nearby list (trigger `.walking`). `PlaceFeed` still gates when
    /// this runs (250 m, and 60 s after a failure); the list then decides between:
    /// - a network refresh: walk log `fetchStarted`, then `fetched` or `fetchFailed`, as before;
    /// - its current list, when that is near and recent enough that it would not refresh (for example one the camera
    ///   just fetched here): the feed takes it, logged as `fetched` around the list's centre with no `fetchStarted`,
    ///   since nothing was fetched;
    /// - neither (it would not refresh, within a minute of another fetch, and has no usable list): nothing now, and the
    ///   next fix asks again.
    private func fetch(around position: Coordinate, now: Date) {
        guard engine != nil else { return }
        feed.fetchStarted(now: now)
        let language = Self.storyLanguage()
        let run = runToken
        let nearby = nearby
        fetchTask = Task { [weak self] in
            let refreshes = await nearby.shouldRefresh(at: position, trigger: .walking, language: language)
            guard let self, self.runToken == run else { return }
            guard !Task.isCancelled else {
                self.feed.fetchCancelled()
                return
            }
            guard refreshes else {
                if let list = await nearby.current(language: language), list.serves(walkerAt: position, now: .now),
                   self.runToken == run, !Task.isCancelled {
                    let places = list.walkingPlaces
                    self.feed.fetchSucceeded(places, at: list.centre, now: .now)
                    self.walkLog.log(WalkLogEvent.fetched(places, around: list.centre, osmFailed: list.osmFailed))
                } else if self.runToken == run {
                    self.feed.fetchCancelled()
                }
                return
            }
            self.walkLog.log(.fetchStarted(position), at: .now)
            let result: Result<NearbyList, Error>
            do {
                result = .success(try await nearby.refresh(at: position, language: language))
            } catch {
                result = .failure(error)
            }
            // A fetch from an earlier run never touches this run's feed (stop() already settled that one).
            guard self.runToken == run else { return }
            switch result {
            case .success(let list) where !Task.isCancelled:
                // A refresh already under way (the camera's) is joined; its list is centred where that one started.
                self.onListRefreshed?(list)
                let places = list.walkingPlaces
                self.feed.fetchSucceeded(places, at: list.centre, now: .now)
                self.walkLog.log(WalkLogEvent.fetched(places, around: list.centre, osmFailed: list.osmFailed))
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
    private func startFields(_ state: Readiness, source: WalkSource) -> WalkLogStart {
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
                            motion: WalkingMotion.permission, perHour: appliedPerHour, battery: battery, source: source)
    }

    private static func notificationState() async -> WalkingReadiness.Notifications {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral:
            // Time Sensitive switched off lets a Focus hold buzzes back: a reminder, never a block (`canStart`).
            return settings.timeSensitiveSetting == .disabled ? .timeSensitiveOff : .allowed
        @unknown default: return .denied
        }
    }

    // MARK: - Settings and city

    private static func configuredPerHour() -> Int {
        UserDefaults.standard.object(forKey: buzzesPerHourKey) as? Int ?? BuzzBudget.defaultPerHour
    }

    private static func storyLanguage() -> StoryLanguage {
        AppServices.currentStoryLanguage()
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
final class OnceBox<T: Sendable>: Sendable {
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
