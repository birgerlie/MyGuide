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
    /// The pause, resume and GPS check runs every tick; auto-off and the Live Activity push every 4th (spec 5.6).
    private static let tickInterval: Duration = .seconds(15)
    private static let ticksPerAutoOff = 4

    private(set) var isOn = false
    /// Why walking mode did not start (or stopped); empty when nothing is in the way.
    private(set) var problems: [WalkingProblem] = []
    private(set) var buzzCount = 0
    /// The time of the last fix the buzz engine could use; nil until one arrives. Not updated while paused.
    private(set) var lastFixAt: Date?
    /// Set on every delivered buzz; the map selects this place explicitly when the app is active (spec 12.2).
    private(set) var lastBuzz: (placeID: String, at: Date)?
    /// Why the engine stayed quiet at the last fix; nil after a buzz, before the first decision and while off.
    private(set) var lastQuietReason: QuietReason?
    /// True while walking mode is on, not paused, and the engine is quiet because every due place is used (spec 13.7).
    var heardEverythingNearby: Bool { isOn && !isPaused && lastQuietReason == .allExcluded }
    /// The run's pause bookkeeping: the pause in progress, since when, and the finished pauses' length.
    private var pauseState = WalkPauseState()
    /// The pause in progress: `auto` from the pause detector, `manual` from the owner's Pause (phone or watch), which
    /// holds until Resume. Nil while active. While paused: no buzzes, fetches, stop detection, track or route (spec 5.4).
    var pauseKind: WalkingPauseKind? { pauseState.kind }
    /// True while walking mode is paused, by either kind.
    var isPaused: Bool { pauseState.isPaused }
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
    /// The tour being walked (tours spec 6, 7), restored at launch; nil without one. It outlives a run: walking mode
    /// stopped by the app (time limit, battery, a long pause, location) or ended with the app keeps it, and «Fortsett
    /// turen» starts walking mode on it again. The owner's Stop ends it (`stop(reason: .user)`, `endTour()`).
    private(set) var tour: ActiveTour?
    /// True while a tour runs: one is set and its end has not been reached.
    var isTouring: Bool { tour.map { !$0.isFinished } ?? false }

    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let walkLog: WalkLog
    @ObservationIgnored private let tourStore: ActiveTourStore
    /// False until the stored tour has been read (or found missing or unreadable, or the reads given up).
    @ObservationIgnored private var tourLoaded = false
    /// Reads of the stored tour that failed for a reason other than decoding (the file is protected while the phone
    /// is locked after a restart, as in a background launch); at most `maxTourReads` per launch.
    @ObservationIgnored private var tourReads = 0
    private static let maxTourReads = 2
    /// While a tour runs, places other than its stops buzz at most once per 3 minutes. Fresh for each run and tour.
    @ObservationIgnored private var tourCadence = TourBuzzCadence()
    /// Stops arrived at whose buzz waits for a free story engine and 30 s after the previous stop's.
    @ObservationIgnored private var stopDelivery = TourStopDelivery()
    /// The last usable position of this run while a tour runs, for the distance on the watch and held stops' buzzes.
    @ObservationIgnored private var lastTourPosition: Coordinate?
    /// The watch's distance step to the next stop, steadied, and the stop it belongs to.
    @ObservationIgnored private var nextStopSteps = TourDistanceSteps()
    @ObservationIgnored private var nextStopStepsID: String?
    /// The shared nearby list; walking mode refreshes it at 250 m and walks with its tiered places.
    @ObservationIgnored private let nearby: NearbyPlaces
    @ObservationIgnored private let hasAPIKey: () -> Bool
    @ObservationIgnored private let location = WalkingLocation()
    @ObservationIgnored private let motion = WalkingMotion()
    /// One per run, made at start and never rebuilt: it holds the pause position and the walking streak.
    @ObservationIgnored private var pauseDetector: PauseDetector?
    /// Why the last start without prompts did not start; on the walk state until the next start (spec 5.3).
    @ObservationIgnored private var startProblem: WalkingProblem?
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
    /// When this run started; nil while walking mode is off. Read by the walking line, which refreshes every second.
    @ObservationIgnored private(set) var startedAt: Date?
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
    /// Which of the map's selections this run writes as `shown` (spec 19.7); fresh for each run, fed only while on.
    @ObservationIgnored private var shownGate = ShownLogGate()
    /// Looks up a stale list's facts before it stands in (spec 19.6); cancelled with the run.
    @ObservationIgnored private var staleTask: Task<Void, Never>?

    init(memory: MemoryStore, stories: WalkingStories, walkLog: WalkLog, nearby: NearbyPlaces,
         tourStore: ActiveTourStore = WalkingController.tourStore, hasAPIKey: @escaping () -> Bool) {
        self.memory = memory
        self.walkLog = walkLog
        self.tourStore = tourStore
        self.stories = stories
        self.nearby = nearby
        self.hasAPIKey = hasAPIKey
        // No buzz while a story is preparing, being continued or playing.
        stories.onBusyChanged = { [weak self] busy in
            // Dated, so a famous place passed during the story can still buzz «behind you» (spec 20.3.3).
            self?.engine?.setBusy(busy, at: .now)
            // A stop waiting for the engine goes out once it is free; after this event is handled, never inside it.
            if !busy { Task { @MainActor [weak self] in self?.deliverHeldStop(now: .now) } }
        }
        stories.onHeard = { [weak self] candidate in self?.noteHeard(candidate) }
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
        restoreTourIfNeeded()
    }

    // MARK: - Start and stop

    nonisolated private static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "walking")

    /// The problem of a start without prompts that cannot start (spec 5.3). It goes to the watch as its English
    /// sentence (the rawValue) and is shown there in the watch's language (`WalkingProblem.text(received:language:)`).
    static let setupProblem = WalkingProblem.setUpOnPhone

    /// Starts walking mode. Returns why it did not start, or nil when it started, was already on or starting, or was
    /// cancelled by `stop()`.
    ///
    /// `interactive: false` (a start from the watch, maybe with the app in the background) never shows a prompt: it
    /// needs location Always, notifications allowed and the key, else it returns `setupProblem` at once, which the
    /// walk state carries until the next start. Motion stays as granted (spec 10.2).
    @discardableResult
    func start(source: WalkSource = .phone, interactive: Bool = true) async -> WalkingProblem? {
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
                    start without prompts refused: \(Self.setupProblem.rawValue, privacy: .public) \
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
        // A tour's stops buzz only through the tour (tours spec 6).
        excluded.formUnion(tour?.stops.map(\.id) ?? [])

        stopSpots = []
        do { stopSpots = try memory.stopSpots(tripID: trip) } catch { fail("stop spots failed", error) }
        stopDetector = StopDetector(previousStops: stopSpots)
        pauseDetector = PauseDetector(now: now, motionAvailable: WalkingMotion.permission == .authorized)
        pauseState = WalkPauseState()
        lastMotion = nil

        appliedPerHour = Self.configuredPerHour()
        var engine = BuzzEngine(perHour: appliedPerHour, now: now, excluded: excluded)
        // A story from before this run may still be playing or ending.
        engine.setBusy(stories.isBusy, at: now)
        self.engine = engine
        let run = UUID()
        runToken = run
        walkLog.begin(runID: run, at: now)
        feed = PlaceFeed()
        shownGate = ShownLogGate()
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
        // The tour's break (walking mode off) ends with the start.
        noteTourBreak(paused: false, now: now)
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
        tourCadence = TourBuzzCadence()
        let unsent = stopDelivery.removeAll()
        stopDelivery = TourStopDelivery()
        lastTourPosition = nil
        nextStopSteps = TourDistanceSteps()
        nextStopStepsID = nil
        // The owner's Stop ends the tour; walking mode stopped by the app keeps it, to be continued, on a break. Stops
        // arrived at whose buzz never went out are undone again, so they are heard when reached after «Fortsett turen».
        if reason == .user {
            if tour != nil { setTour(nil) }
        } else {
            reopenStops(unsent, context: "tour stop not sent before the stop", now: .now)
            noteTourBreak(paused: true, now: .now)
        }
        timerTask?.cancel()
        timerTask = nil
        startedAt = nil
        resumedAt = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        motion.stop()
        location.setPaused(false)
        location.stop()
        pauseState = WalkPauseState()
        pauseDetector = nil
        lastMotion = nil
        stopSpots = []
        flushTrack()
        resetRoute()
        do { try memory.closePendingBuzzes() } catch { fail("closing pending buzzes failed", error) }
        fetchTask?.cancel()
        fetchTask = nil
        staleTask?.cancel()
        staleTask = nil
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
        if phase == .active { restoreTourIfNeeded() }
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

    // MARK: - Tour

    /// Application Support/ActiveTour.json.
    nonisolated static let tourStore = ActiveTourStore(
        url: URL.applicationSupportDirectory.appending(path: "ActiveTour.json"))

    /// «Start turen» (tours spec 6): the tour replaces any other and walking mode starts on it (an interactive start,
    /// so the owner may be asked for permissions), or goes on with it when already on, resumed if paused. Returns why
    /// walking mode did not start; the tour stays, so «Fortsett turen» can try again.
    @discardableResult
    func startTour(_ routed: RoutedTour) async -> WalkingProblem? {
        tourLoaded = true
        tourCadence = TourBuzzCadence()
        stopDelivery = TourStopDelivery()
        lastTourPosition = nil
        var new = ActiveTour(routed: routed, startedAt: .now)
        // Walking mode off: the tour waits on a break until the start below (or «Fortsett turen») ends it.
        if !isOn { new.pause(at: new.startedAt) }
        setTour(new)
        excludeTourStops()
        if isOn {
            resume(source: .phone)
            return nil
        }
        return await start()
    }

    /// «Hopp over stopp»: the next stop is skipped and the one after it is next. Nothing without a next stop.
    func skipStop() {
        guard var current = tour, !current.isFinished, current.next != nil else { return }
        current.skipNext()
        // The watch shows the new next stop with its distance at once, not its name alone until the next fix.
        updateWatchDistance(now: .now, tour: current)
        setTour(current)
    }

    /// «Lukk» on the finished tour's panel: the tour is cleared and walking mode goes on without it. Nothing unless the
    /// tour has finished.
    func closeFinishedTour() {
        guard tour?.isFinished == true else { return }
        setTour(nil)
        // No next stop any more: the watch distance starts afresh (the state just sent has no next stop).
        updateWatchDistance(now: .now)
    }

    /// «Avslutt turen» on the tour panel: the tour ends, and walking mode with it (the owner's Stop).
    func endTour() {
        if isOn || isStarting { stop(reason: .user, source: .phone) }
        setTour(nil)
    }

    /// Reads the stored tour once: a tour older than `ActiveTour.maxAge` is removed instead. A file that cannot be
    /// decoded is removed too, so it never fails again. A read that failed otherwise (the file is protected while the
    /// phone is locked after a restart) is tried again on the next activation.
    private func restoreTourIfNeeded() {
        guard !tourLoaded else { return }
        let stored: ActiveTour?
        do {
            stored = try tourStore.load()
        } catch let error as DecodingError {
            AppServices.logMemoryFailure("tour restore failed, file removed", error)
            tourLoaded = true
            clearStoredTour()
            return
        } catch {
            tourReads += 1
            // Given up after the last try: the file is kept for the next launch.
            if tourReads >= Self.maxTourReads { tourLoaded = true }
            AppServices.logMemoryFailure("tour restore failed (read \(tourReads) of \(Self.maxTourReads))", error)
            return
        }
        tourLoaded = true
        guard var stored else { return }
        let now = Date.now
        guard !stored.isStale(now: now) else {
            clearStoredTour()
            return
        }
        // Walking mode never survives a relaunch: the tour is on a break from now until walking mode starts. When the
        // app ended is unknown, so the time until now counts as walking. Walking mode already on and walking (started
        // before this read) closes the stored break instead; on and paused keeps one open.
        let before = stored
        // A finished tour's walking time is fixed (an open break counts up to the finish), so it is left as stored.
        if !stored.isFinished {
            if !isOn || isPaused { stored.pause(at: now) } else { stored.resume(at: now) }
        }
        tour = stored
        if stored != before { saveTour(stored) }
        excludeTourStops()
        tourChanged()
    }

    /// A running engine never buzzes a stop of the tour: those buzz through the tour alone (tours spec 6).
    private func excludeTourStops() {
        guard let tour else { return }
        for stop in tour.stops { engine?.exclude(stop.id) }
    }

    /// A break in the tour's walking time starts (walking mode paused or off) or ends. Nothing without a running tour.
    private func noteTourBreak(paused: Bool, now: Date) {
        guard var current = tour, !current.isFinished else { return }
        if paused { current.pause(at: now) } else { current.resume(at: now) }
        setTour(current)
    }

    /// Sets the tour, saves it (or removes the file without one) and tells the watch and the Live Activity.
    private func setTour(_ new: ActiveTour?) {
        guard new != tour else { return }
        tour = new
        if let new {
            saveTour(new)
        } else {
            clearStoredTour()
        }
        tourChanged()
    }

    private func saveTour(_ tour: ActiveTour) {
        do { try tourStore.save(tour) } catch { fail("tour save failed", error) }
    }

    private func clearStoredTour() {
        do { try tourStore.clear() } catch { fail("tour file removal failed", error) }
    }

    /// The watch's state and the Live Activity's «Neste: X» follow the tour.
    private func tourChanged() {
        activity.setNextStop(isTouring ? tour?.next.map { TourFormat.nextStop($0.name, metres: nil,
                                                                                language: UILanguage.current) } : nil)
        publishState()
    }

    /// The tour at a fix the engine could use (tours spec 6): within 60 m of an undone stop (the first in plan order,
    /// not necessarily the next) that stop is visited and its buzz queued (`deliverHeldStop` sends it, whatever its
    /// tier); with every stop done, within 60 m of the end the tour finishes. Nothing without a running tour or with a
    /// poor fix.
    private func advanceTour(position: Coordinate, accuracy: Double, now: Date) {
        guard var current = tour, !current.isFinished, WalkingFix.isUsable(accuracy: accuracy) else { return }
        lastTourPosition = position
        if let stop = current.arrive(at: position, now: now) {
            stopDelivery.arrive(stop, at: now)
        } else {
            _ = current.reachEnd(at: position, now: now)
        }
        // The distance on the watch follows the fix, steadied (`TourDistanceSteps`), and is fed before the tour is set,
        // so one state goes out with the new next stop and its distance; sent only when something changed.
        updateWatchDistance(now: now, tour: current)
        setTour(current)
        publishState()
    }

    /// Feeds the steadied distance step to `tour`'s next stop (the current tour by default); starts afresh for a new
    /// next stop, without a running tour or without a position.
    private func updateWatchDistance(now: Date) {
        updateWatchDistance(now: now, tour: tour)
    }

    private func updateWatchDistance(now: Date, tour: ActiveTour?) {
        guard let tour, !tour.isFinished, let next = tour.next, let lastTourPosition else {
            nextStopSteps = TourDistanceSteps()
            nextStopStepsID = nil
            return
        }
        if nextStopStepsID != next.id {
            nextStopSteps = TourDistanceSteps()
            nextStopStepsID = next.id
        }
        _ = nextStopSteps.update(TourFormat.approachStep(GeoMath.distance(lastTourPosition, next.coordinate)), now: now)
    }

    /// Buzzes the oldest stop arrived at when `TourStopDelivery` lets it go (the story engine free, 30 s since the
    /// last stop's buzz), from `position` (a usable fix's, else the last usable one) and `direction`. Without either
    /// position the stop waits as if the engine were busy. A stop held free more than 3 minutes is dropped, logged and
    /// undone again in a running tour, so it buzzes when reached again. Nothing while off or paused (no buzz then,
    /// spec 5.4). True when a stop buzzed.
    @discardableResult
    private func deliverHeldStop(now: Date, position: Coordinate? = nil, direction: Double? = nil) -> Bool {
        guard isOn, !isPaused, !stopDelivery.isEmpty else { return false }
        let from = position ?? lastTourPosition
        let taken = stopDelivery.take(now: now, busy: stories.isBusy || from == nil)
        reopenStops(taken.dropped, context: "tour stop dropped", now: now)
        guard let stop = taken.deliver, let from else { return false }
        deliverTourStop(stop, position: from, direction: direction ?? route.walkingBearing, now: now)
        return true
    }

    /// Logs each stop whose buzz never went out, with how long it was held, and makes them undone again in the tour
    /// (`ActiveTour.reopen`; nothing for a finished tour or without one), so the watch and the panel show them again.
    private func reopenStops(_ unsent: [TourStopDelivery.Held], context: String, now: Date) {
        guard !unsent.isEmpty else { return }
        let reopens = tour.map { !$0.isFinished } ?? false
        for held in unsent {
            walkLog.log(.failure(context: context,
                                 error: "\(held.stop.id) held \(Int(now.timeIntervalSince(held.since))) s"
                                     + (reopens ? ", undone again" : "")),
                        at: now)
        }
        guard var current = tour, reopens else { return }
        current.reopen(unsent.map(\.stop.id))
        updateWatchDistance(now: now, tour: current)
        setTour(current)
    }

    /// Buzzes a stop as a place chosen on the map is told (`Buzz(chosen:position:)`): the feed's place when the stop
    /// is in it, else the candidate the planner kept with the stop, else (a tour stored before that) a bare one.
    /// Delivered like any buzz, so it is recorded (marked as a tour stop in the walk log), notified, sent to the watch
    /// and its story prepared. The engine never buzzes it, nor any place at its spot (within 25 m) or with its Wikidata
    /// id, this run, and the cadence counts it.
    private func deliverTourStop(_ stop: TourStop, position: Coordinate, direction: Double?, now: Date) {
        let place = feed.places.first { $0.candidate.id == stop.id }
            ?? WalkingPlace(candidate: stop.candidate
                                ?? Candidate(id: stop.id, name: stop.name, coordinate: stop.coordinate, kind: ""),
                            tier: stop.tier)
        let buzz = Buzz(chosen: place, position: position)
        engine?.exclude(stop.id)
        engine?.excludeSpot(of: place.candidate)
        tourCadence.noteBuzz(at: now)
        walkLog.log(.buzz(WalkLogBuzz(buzz, tourStop: true)), at: now)
        walkLog.resetQuiet()
        if lastQuietReason != nil { lastQuietReason = nil }
        deliver(buzz, position: position, direction: direction, at: now)
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
    /// (memory rests it for 30 days), nor does any place within 25 m of it or with its Wikidata id (spec 19.4).
    func noteHeard(_ place: Candidate) {
        engine?.excludeSpot(of: place)
    }

    /// The reset button (spec 13.5), after memory's `resetPlaceNotifications()`: the running engine forgets every
    /// exclusion, so every place nearby may buzz again in this run too. Nothing while walking mode is off.
    func resetExclusions() {
        engine?.clearExclusions()
        excludeTourStops()
        if lastQuietReason == .allExcluded { lastQuietReason = nil }
    }

    // MARK: - The map's selection (spec 19.7)

    /// A selection update from «Rundt deg» while the map is visible (`ShownLogGate.note` explains the arguments):
    /// the gate's `shown` line, if any, goes to the walk log. Nothing while walking mode is off; the gate starts
    /// fresh with each run, so the map's selection is written within a second of the start.
    func noteMapSelection(placeID: String?, name: String?, cause: ShownReason, holding: Bool, now: Date) {
        guard isOn else { return }
        if let kind = shownGate.note(placeID: placeID, name: name, cause: cause, holding: holding, now: now) {
            walkLog.log(kind, at: now)
        }
    }

    /// The map screen is gone: a `cleared` waiting for its confirmation is dropped. Not a `shown` line.
    func noteMapHidden() {
        guard isOn else { return }
        shownGate.mapHidden()
    }

    /// Called by `WalkingStories` when a level of a `.chosen` story starts playing: the place does not buzz this run,
    /// nor does any place within 25 m of it or with its Wikidata id (spec 19.4). `WalkingStories` has already marked
    /// it heard in memory, which rests it for 30 days (spec 12.1, 13.1).
    func noteChosenHeard(_ place: Candidate) {
        engine?.excludeSpot(of: place)
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
        // A held stop also goes out (or is dropped) between fixes.
        deliverHeldStop(now: now)
        noteGPS(now: now)
        guard count % Self.ticksPerAutoOff == 0 else { return }
        checkAutoOff(now: now)
        refreshActivity(now: now)
    }

    /// Turns walking mode off after 4 hours of active time (pauses do not count), after an hour paused, or when the
    /// battery runs low, and says why in a notification.
    private func checkAutoOff(now: Date) {
        guard isOn, let startedAt,
              let reason = AutoOff.reason(activeTime: AutoOff.activeTime(startedAt: startedAt, now: now,
                                                                         pausedTotal: pauseState.pausedTotal,
                                                                         pausedSince: pauseState.pausedSince),
                                          pausedFor: pauseState.pausedSince.map { now.timeIntervalSince($0) },
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

    /// The pause detector's output, to the pause rules (`WalkPauseState.apply`). Nothing while off.
    private func applyPause(_ change: PauseChange?, now: Date) {
        guard isOn else { return }
        apply(pauseState.apply(change, now: now), now: now)
    }

    /// The owner's Pause, from the phone or the watch (spec 4, 10.4). From walking it enters a manual pause; from an
    /// auto-pause the same pause turns manual: `pausedSince` is kept and one `paused` line with reason `manual` is
    /// written. Either way the detector is held, so walking or moving never ends it. Already manual or off: nothing.
    func pause(source: WalkSource) {
        guard isOn, pauseKind != .manual else { return }
        let now = Date.now
        apply(pauseState.pause(source: source, anchor: currentAnchor(now: now), now: now), now: now)
    }

    /// The owner's Resume, from the phone or the watch: ends either kind of pause as if the walker had moved. The
    /// detector is released and starts a fresh still stretch from now. The `resumed` reason is `manual` after a manual
    /// pause, else the trigger of the auto-pause. Not paused or off: nothing.
    func resume(source: WalkSource) {
        guard isOn, isPaused else { return }
        let now = Date.now
        apply(pauseState.resume(source: source, now: now), now: now)
    }

    /// Where the walker is for a manual `paused` line: the last position CoreLocation knows, when it is fresh and
    /// accurate enough to anchor a pause (the detector's own rule, 50 m); else nil.
    private func currentAnchor(now: Date) -> Coordinate? {
        guard let fix = location.lastKnown, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= PauseDetector.maxStillAccuracy, WalkingFix.isFresh(fix.timestamp, now: now)
        else { return nil }
        return Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
    }

    /// Carries out a pause change's effects, in order. Into a pause the track is saved and the Live Activity shows the
    /// pause text (also over a stop story) with a stale date the 60 s push keeps moving on; a story playing or
    /// preparing goes on. Out of a pause the next fix is judged as usual (spec 5.4) and the Live Activity shows the
    /// walking status again, with a stale date counted from now.
    private func apply(_ effects: [WalkPauseEffect], now: Date) {
        for effect in effects {
            switch effect {
            case .suspendTracking:
                noteTourBreak(paused: true, now: now)
                location.setPaused(true)
                flushTrack()
            case .resetRoute:
                noteTourBreak(paused: false, now: now)
                location.setPaused(false)
                resetRoute()
                stopDetector = StopDetector(previousStops: stopSpots)
                lastTrackSample = nil
                loggedGPS = nil
                resumedAt = now
            case .holdDetector:
                pauseDetector?.hold()
            case .releaseDetector:
                pauseDetector?.release(now: now)
            case .log(let kind):
                walkLog.log(kind, at: now)
            case .refreshActivity(let clearStop):
                walkLog.resetQuiet()
                if clearStop { activity.clearStop() }
                refreshActivity(now: now)
                publishState()
            }
        }
    }

    // MARK: - Walk state

    /// The walk state as the watch sees it (spec 4), stamped now.
    var guidedWalkState: GuidedWalkState {
        let now = Date.now
        guard isOn else {
            if isStarting {
                return GuidedWalkState(phase: .starting, buzzCount: 0, startedAt: nil, problem: startProblem?.rawValue,
                                       sentAt: now)
            }
            return .off(sentAt: now, problem: startProblem?.rawValue)
        }
        let phase: GuidedWalkPhase = switch pauseKind {
        case nil: .walking
        case .auto: .pausedAuto
        case .manual: .pausedManual
        }
        return GuidedWalkState(phase: phase, buzzCount: buzzCount, startedAt: startedAt,
                               pausedTotal: pauseState.pausedTotal, pausedSince: pauseState.pausedSince, problem: startProblem?.rawValue, sentAt: now,
                               nextStop: guidedNextStop)
    }

    /// «Neste: Pantheon · 300 m» for the watch while a tour runs, at the steadied 50 m step (the name alone before a
    /// usable fix).
    private var guidedNextStop: GuidedWalkNextStop? {
        guard isTouring, let next = tour?.next else { return nil }
        let step = nextStopStepsID == next.id ? nextStopSteps.shown : nil
        let metres = step.map { Double($0 * 50) }
        return GuidedWalkNextStop(name: next.name,
                                  line: TourFormat.nextStop(next.name, metres: metres, language: UILanguage.current))
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
        // A tour's stop comes first and alone; between stops the engine is asked at most once per 3 minutes after a
        // buzz (tours spec 6). Not asking leaves its budget and exclusions untouched for when it may buzz again.
        advanceTour(position: position, accuracy: fix.horizontalAccuracy, now: now)
        // A held stop's buzz is placed from this fix only when the engine could use it, else from the last usable one.
        let stopBuzzed = deliverHeldStop(now: now,
                                         position: WalkingFix.isUsable(accuracy: fix.horizontalAccuracy) ? position : nil,
                                         direction: direction)
        let decision: BuzzDecision?
        if stopBuzzed {
            // A stop buzzed: it goes alone.
            decision = nil
        } else if isTouring && !stopDelivery.isEmpty {
            // A stop waits: it goes first. After the finish a held stop no longer holds the engine back.
            decision = nil
            walkLog.logQuiet(.tourStopHeld, due: [], at: now)
            if lastQuietReason != .tourStopHeld { lastQuietReason = .tourStopHeld }
        } else if isTouring && !tourCadence.allows(at: now) {
            decision = nil
            walkLog.logQuiet(.tourCadence, due: [], at: now)
            if lastQuietReason != .tourCadence { lastQuietReason = .tourCadence }
        } else {
            decision = engine?.decide(places: feed.places, position: position, accuracy: fix.horizontalAccuracy,
                                      course: direction, now: now)
        }
        switch decision {
        case .buzz(let buzz):
            if isTouring { tourCadence.noteBuzz(at: now) }
            walkLog.log(.buzz(WalkLogBuzz(buzz)), at: now)
            walkLog.resetQuiet()
            if lastQuietReason != nil { lastQuietReason = nil }
            deliver(buzz, position: position, direction: direction, at: now)
        case .quiet(let reason, let due):
            // A `held` line names the place that holds (spec 20.6.6); the engine keeps it for its last decision.
            walkLog.logQuiet(reason, due: due, heldBy: engine?.heldBy, at: now)
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
        let found = WalkingStatus.hasFreshFix(lastFixAt: lastFixAt, now: now)
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
    /// this runs (250 m, 60 s after a failure, or 15, 30 then 60 s while the walk has no places, and 60, 120 then 300 s
    /// after lists whose OpenStreetMap part keeps failing, spec 20.8); the list then decides between:
    /// - a network refresh: walk log `fetchStarted`, then `fetched` or `fetchFailed`, as before;
    /// - its current list, when that is near and recent enough that it would not refresh (for example one the camera
    ///   just fetched here): the feed takes it, logged as `fetched` around the list's centre with no `fetchStarted`,
    ///   since nothing was fetched. A list without facts (`NearbyList.needsFacts`) is re-tiered through the facts
    ///   lookup first (cache-first, at most `staleFactsTimeout`), as a stale list is;
    /// - neither (it would not refresh, within the attempt spacing of another fetch (60 s, or the feed's shorter
    ///   failure retry while the walk is empty), and has no usable list): nothing now, and the next fix asks again.
    ///
    /// At the run's first fetch, while the feed has no places, a stored list that does not serve but is at most 7 days
    /// old and centred within 250 m stands in as soon as its facts are applied (`startStaleList`, spec 19.6); the
    /// refresh runs meanwhile and replaces it.
    private func fetch(around position: Coordinate, now: Date) {
        guard engine != nil else { return }
        feed.fetchStarted(now: now)
        let language = Self.storyLanguage()
        let run = runToken
        let nearby = nearby
        // While the walk has no places (or stale ones) the nearby list may retry a failed fetch as soon as the feed
        // does (15, 30, then 60 s), instead of holding off for 60 s (spec 19.6).
        let failureRetry = feed.failureRetryInterval
        fetchTask = Task { [weak self] in
            let refreshes = await nearby.shouldRefresh(at: position, trigger: .walking, language: language,
                                                       failureRetry: failureRetry)
            guard let self, self.runToken == run else { return }
            guard !Task.isCancelled else {
                self.feed.fetchCancelled()
                return
            }
            guard refreshes else {
                let current = await nearby.current(language: language)
                guard self.runToken == run else { return }
                if let current, current.serves(walkerAt: position, now: .now), !Task.isCancelled {
                    // A list without facts (stored by a build before them, or every lookup failed) is re-tiered
                    // first, cache-first, as a stale list is (spec 19.6).
                    let list = current.needsFacts
                        ? await current.withFacts(from: AppServices.sharedPlaceFacts, within: Self.staleFactsTimeout)
                        : current
                    guard self.runToken == run else { return }
                    guard !Task.isCancelled else {
                        self.feed.fetchCancelled()
                        return
                    }
                    let places = list.walkingPlaces
                    self.feed.fetchSucceeded(places, at: list.centre, now: .now, osmFailed: list.osmFailed,
                                             fetchedAt: list.fetchedAt, osmRetryAge: list.osmRetryAge)
                    self.walkLog.log(WalkLogEvent.fetched(places, around: list.centre, osmFailed: list.osmFailed,
                                                          osmErrors: list.osmErrors, facts: list.factsCount,
                                                          dropped: list.dropped, factsFailed: list.factsFailed,
                                                          factsSeconds: list.factsSeconds, factsCut: list.factsCut))
                } else {
                    // Within the attempt spacing of another fetch and no list that serves: a stale one may stand in.
                    if !Task.isCancelled { self.startStaleList(current, around: position, language: language) }
                    self.feed.fetchCancelled()
                }
                return
            }
            if self.feed.wantsStaleList {
                let stored = await nearby.current(language: language)
                guard self.runToken == run else { return }
                if !Task.isCancelled { self.startStaleList(stored, around: position, language: language) }
            }
            self.walkLog.log(.fetchStarted(position), at: .now)
            let result: Result<NearbyList, Error>
            do {
                result = .success(try await nearby.refresh(at: position, language: language, failureRetry: failureRetry))
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
                self.feed.fetchSucceeded(places, at: list.centre, now: .now, osmFailed: list.osmFailed,
                                         fetchedAt: list.fetchedAt, osmRetryAge: list.osmRetryAge)
                self.walkLog.log(WalkLogEvent.fetched(places, around: list.centre, osmFailed: list.osmFailed,
                                                      osmErrors: list.osmErrors, facts: list.factsCount,
                                                      dropped: list.dropped, factsFailed: list.factsFailed,
                                                      factsSeconds: list.factsSeconds, factsCut: list.factsCut))
            case .failure(let error) where !(error is CancellationError) && !Task.isCancelled:
                // A real failure waits 60 s before the next try; 15, 30, then 60 s while the walk has no places (or
                // stale ones).
                self.feed.fetchFailed(now: .now)
                self.walkLog.log(WalkLogEvent.fetchFailed(error))
            default:
                // The app's own cancellation is silent and sets no retry delay.
                self.feed.fetchCancelled()
            }
        }
    }

    /// The facts lookup of a stale list, or of a serving list without facts, waits at most this long; the list is
    /// then used as stored.
    private static let staleFactsTimeout: Duration = .seconds(8)

    /// Spec 19.6: once per run, while the feed has no places, `stored` (the nearby list's current list) stands in
    /// when it is in `language`, at most 7 days old and centred within 250 m of `position`
    /// (`NearbyList.staleCandidate`). The feed's one stale claim is used up here, list or not. Its candidates' facts
    /// are looked up first (cache hits at once; a failure or `staleFactsTimeout` leaves them as stored) and it is
    /// tiered afresh, so a list stored before facts does not buzz organisations. It then goes to the feed, logged as
    /// `fetched` with `stale: true`, unless a fetch came back meanwhile. It sets no centre in the feed, so the fresh
    /// list is still fetched and replaces it; it is not a refresh, so `onListRefreshed` is not told. A list with no
    /// walking places is not taken.
    private func startStaleList(_ stored: NearbyList?, around position: Coordinate, language: StoryLanguage) {
        guard feed.claimStaleList(),
              let stale = NearbyList.staleCandidate(stored: stored, position: position, language: language, now: .now)
        else { return }
        let run = runToken
        let facts = AppServices.sharedPlaceFacts
        staleTask = Task { [weak self] in
            let list = await stale.withFacts(from: facts, within: Self.staleFactsTimeout)
            guard let self, self.runToken == run, !Task.isCancelled else { return }
            let places = list.walkingPlaces
            guard self.feed.takeStaleList(places) else { return }
            self.walkLog.log(WalkLogEvent.fetched(places, around: list.centre, osmFailed: list.osmFailed,
                                                  osmErrors: list.osmErrors, facts: list.factsCount,
                                                  dropped: list.dropped, factsFailed: list.factsFailed, stale: true,
                                                  factsSeconds: list.factsSeconds, factsCut: list.factsCut))
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

        var problems: [WalkingProblem] {
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

    /// The address at `coordinate`, or nil when the lookup fails or it takes longer than 8 s
    /// (`GroundingService.defaultGeocoderTimeout`). MapKit's request ignores cancellation; the wait does not.
    private static func address(at coordinate: Coordinate) async -> Address? {
        await Deadline.value(within: GroundingService.defaultGeocoderTimeout) {
            try? await MapKitReverseGeocoder().address(for: coordinate)
        }
    }
}
