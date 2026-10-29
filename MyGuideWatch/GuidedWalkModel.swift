import HealthKit
import MyGuideCore
import WatchKit

/// The watch's guided walk: the phone's walk state, the commands sent to it, and the one workout that records the
/// walk. The phone holds the truth. The workout follows the watch's own commands at once and is corrected to the
/// phone's state when that arrives.
@MainActor
@Observable
final class GuidedWalkModel {
    // In the watch's language (`WatchTexts`); fixed for the life of the process, so the notes compare equal.
    static var notReachableText: String { WatchTexts.notReachable }
    static var notSavedText: String { WatchTexts.notSaved }
    static var workoutEndedText: String { WatchTexts.workoutEnded }
    static var workoutEndedNotSavedText: String { "\(workoutEndedText) · \(notSavedText)" }

    /// The last state applied from the phone, nil until the first one arrives.
    private(set) var state: GuidedWalkState?
    /// The command waiting for its reply.
    private(set) var pending: GuidedWalkCommand?
    /// Why the last command failed on the watch side.
    var error: String?
    /// A line about the workout: not saved, or ended from outside.
    var healthNote: String?
    /// The last buzz the phone sent straight to the watch (spec 18), shown with «Lytt» until the next one or the end
    /// of the walk.
    private(set) var buzz: GuidedWalkBuzz?
    /// True while «Lytt» waits for the phone's reply.
    private(set) var sendingListen = false
    /// After «Lytt»: sent, or why it failed. Cleared by the next buzz.
    var buzzNote: String?

    /// A guided walk workout exists or is starting. The Check screen's own test workout must not run then.
    var hasWorkout: Bool { keeper.isActive }

    /// Called before a workout starts, so the Check screen's test workout can stop first: HealthKit allows one.
    @ObservationIgnored var willStartWorkout: (@MainActor () async -> Void)?

    private enum WorkoutTarget {
        case running, paused, ended
        /// Leave the workout as it is (the phone is still starting).
        case unchanged
    }

    @ObservationIgnored private let keeper = WorkoutKeeper(purpose: .guidedWalk)
    @ObservationIgnored private let link: PhoneLink
    /// What the workout should be doing; `reconcile()` drives the keeper there.
    @ObservationIgnored private var target: WorkoutTarget = .unchanged
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    /// Set when the workout ended from outside: no new workout until the next Start, or until the walk is off.
    @ObservationIgnored private var restartBlocked = false
    /// The buzzes shown in the last 10 minutes: each is felt once, also when its notification arrives.
    @ObservationIgnored private var recentBuzzes = RecentBuzzIDs()

    init(link: PhoneLink = .shared) {
        self.link = link
        keeper.onEnded = { [weak self] result in self?.workoutEndedOutside(result) }
        link.onState = { [weak self] context in
            guard let state = GuidedWalkState(message: context) else { return }
            self?.apply(state)
        }
        link.onMessage = { [weak self] message in
            // A buzz queued while out of reach can arrive long after; by then the place is behind.
            guard let buzz = GuidedWalkBuzz(message: message), buzz.isFresh(now: .now) else { return }
            self?.showBuzz(id: buzz.id, name: buzz.name, line: buzz.line)
        }
    }

    // MARK: - Buzzes

    /// Plays the notification haptic and shows the place with «Lytt», once per buzz id within 10 minutes. The workout
    /// keeps the app running through the walk, so the haptic plays with the wrist down too.
    func showBuzz(id: UUID, name: String, line: String) {
        let now = Date.now
        guard recentBuzzes.remember(id, now: now) else { return }
        buzz = GuidedWalkBuzz(id: id, name: name, line: line, sentAt: now)
        buzzNote = nil
        WKInterfaceDevice.current().play(.notification)
    }

    /// True when the buzz `id` was shown here in the last 10 minutes; its notification is then not presented again.
    func hasShownBuzz(_ id: UUID) -> Bool {
        recentBuzzes.contains(id, now: .now)
    }

    /// «Lytt» on the shown buzz: the phone tells its story, as with the notification's Listen.
    func listenToBuzz() async {
        guard let buzz, !sendingListen else { return }
        sendingListen = true
        defer { sendingListen = false }
        buzzNote = nil
        do {
            try await link.tell(GuidedWalkBuzz.tellMessage(id: buzz.id))
            // A newer buzz that arrived meanwhile keeps its own clean card.
            if self.buzz?.id == buzz.id { buzzNote = WatchTexts.listenSent }
        } catch PhoneLinkError.notReachable {
            if self.buzz?.id == buzz.id { buzzNote = Self.notReachableText }
        } catch {
            if self.buzz?.id == buzz.id { buzzNote = error.localizedDescription }
        }
    }

    /// Applies the workout effect of `command` at once, then sends it. The reply is applied like any state; on
    /// failure the workout goes back to the last applied state.
    func send(_ command: GuidedWalkCommand) async {
        guard pending == nil else { return }
        pending = command
        defer { pending = nil }
        error = nil
        if command == .start {
            restartBlocked = false
            clearWorkoutEndedNote()
        }
        setTarget(Self.target(for: command))
        do {
            let reply = try await link.send(["type": command.rawValue])
            guard let replyState = GuidedWalkState(message: reply) else { throw PhoneLinkError.unexpectedReply }
            apply(replyState)
        } catch PhoneLinkError.notReachable {
            error = Self.notReachableText
        } catch {
            self.error = error.localizedDescription
        }
        // On success this repeats what `apply` did, unless the reply was older than a state already applied. On
        // failure it rolls the workout back.
        syncWorkout()
    }

    /// Applies a state from the phone (reply or context) only when it is newer than the last one applied.
    func apply(_ newState: GuidedWalkState) {
        guard newState.isNewer(than: state) else { return }
        state = newState
        if newState.phase == .off {
            restartBlocked = false
            // The walk is over: its last place no longer belongs on screen.
            buzz = nil
            buzzNote = nil
        }
        syncWorkout()
    }

    /// The system launched the app to run a workout (`startWatchApp` on the phone).
    func startForWorkoutLaunch() {
        restartBlocked = false
        clearWorkoutEndedNote()
        setTarget(.running)
    }

    /// A session recovered after the app was killed. The phone's state then decides what it does.
    func adopt(_ session: HKWorkoutSession) {
        keeper.adopt(session)
        reconcile()
    }

    /// Points the workout at the last applied state; with no state yet, the walk counts as off.
    private func syncWorkout() {
        setTarget(state.map { Self.target(for: $0.phase) } ?? .ended)
    }

    private func setTarget(_ newTarget: WorkoutTarget) {
        target = newTarget
        reconcile()
    }

    /// Drives the keeper to `target`, one step at a time. A target set while a step is suspended (the permission
    /// prompt, say) is driven after it, so the workout always ends at the newest target.
    private func reconcile() {
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task {
            repeat {
                reconcileAgain = false
                await drive(target)
            } while reconcileAgain
            reconciling = false
        }
    }

    private func drive(_ target: WorkoutTarget) async {
        switch target {
        case .running:
            guard !restartBlocked else { return }
            if !keeper.isActive { await willStartWorkout?() }
            do {
                try await keeper.ensureRunning()
            } catch {
                healthNote = Self.notSavedText
                return
            }
            if healthNote == Self.notSavedText { healthNote = nil }
            keeper.resume()
        case .paused:
            keeper.pause()
        case .ended:
            // Drives are serialized, so a repeated `.ended` target finds no workout and does not call `finish()`.
            guard keeper.isActive else { return }
            if await keeper.finish() == .failed { healthNote = Self.notSavedText }
        case .unchanged:
            break
        }
    }

    /// The workout ended from outside. A failed finish means the walk so far is not in Health, which the note says.
    private func workoutEndedOutside(_ result: WorkoutKeeper.FinishResult?) {
        restartBlocked = true
        healthNote = result == .failed ? Self.workoutEndedNotSavedText : Self.workoutEndedText
    }

    /// A new workout is starting: the note about the last one ending from outside no longer applies.
    private func clearWorkoutEndedNote() {
        if healthNote == Self.workoutEndedText || healthNote == Self.workoutEndedNotSavedText { healthNote = nil }
    }

    private static func target(for command: GuidedWalkCommand) -> WorkoutTarget {
        switch command {
        case .start, .resume: .running
        // Stop must stay reversible until the phone confirms it: the workout pauses now and is finished only when
        // an `off` state is applied. An unreachable Stop rolls back to running.
        case .pause, .stop: .paused
        }
    }

    private static func target(for phase: GuidedWalkPhase) -> WorkoutTarget {
        switch phase {
        case .walking: .running
        case .pausedAuto, .pausedManual: .paused
        case .off: .ended
        case .starting: .unchanged
        }
    }
}
