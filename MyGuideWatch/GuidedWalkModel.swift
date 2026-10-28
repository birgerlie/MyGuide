import HealthKit
import MyGuideCore

/// The watch's guided walk: the phone's walk state, the commands sent to it, and the one workout that records the
/// walk. The phone holds the truth. The workout follows the watch's own commands at once and is corrected to the
/// phone's state when that arrives.
@MainActor
@Observable
final class GuidedWalkModel {
    static let notReachableText = "Phone not reachable. Open MyGuide on your phone."
    static let notSavedText = "Not saved to Health"
    static let workoutEndedText = "Workout ended"

    /// The last state applied from the phone, nil until the first one arrives.
    private(set) var state: GuidedWalkState?
    /// The command waiting for its reply.
    private(set) var pending: GuidedWalkCommand?
    /// Why the last command failed on the watch side.
    var error: String?
    /// A line about the workout: not saved, or ended from outside.
    var healthNote: String?

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

    init(link: PhoneLink = .shared) {
        self.link = link
        keeper.onEnded = { [weak self] in self?.workoutEndedOutside() }
        link.onState = { [weak self] context in
            guard let state = GuidedWalkState(message: context) else { return }
            self?.apply(state)
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
            if healthNote == Self.workoutEndedText { healthNote = nil }
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
        if newState.phase == .off { restartBlocked = false }
        syncWorkout()
    }

    /// The system launched the app to run a workout (`startWatchApp` on the phone).
    func startForWorkoutLaunch() {
        restartBlocked = false
        if healthNote == Self.workoutEndedText { healthNote = nil }
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
            _ = await keeper.finish()
        case .unchanged:
            break
        }
    }

    private func workoutEndedOutside() {
        restartBlocked = true
        healthNote = Self.workoutEndedText
    }

    private static func target(for command: GuidedWalkCommand) -> WorkoutTarget {
        switch command {
        case .start, .resume: .running
        case .pause: .paused
        case .stop: .ended
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
