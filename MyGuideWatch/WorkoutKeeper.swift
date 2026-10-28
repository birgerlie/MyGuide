import HealthKit

enum WorkoutKeeperError: LocalizedError {
    case notAuthorized
    case endedWhileStarting

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Not allowed to save workouts"
        case .endedWhileStarting: "The workout ended while starting"
        }
    }
}

/// Owns one outdoor walking workout session. It keeps the watch app running with the wrist down, and for a guided
/// walk it records the walk in Health.
///
/// Every operation is idempotent: `ensureRunning()` joins a start in progress, `pause()` and `resume()` act only in
/// the matching session state, and `finish()` takes the session out before it suspends, so a second call finds
/// nothing to finish.
@MainActor
@Observable
final class WorkoutKeeper: NSObject {
    enum Purpose {
        /// Saves workouts of at least `minimumSavedDuration`, and picks up a session left by a killed app.
        case guidedWalk
        /// The Check screen's haptic test: always discarded, never recovers a session.
        case test
    }

    /// Shorter workouts are discarded: a mis-tap leaves no entry in Fitness. Compared with `builder.elapsedTime`,
    /// which excludes pauses.
    static let minimumSavedDuration: TimeInterval = 60

    /// The session ended or failed from outside: the system, or another app's workout. Not called for `finish()`.
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let purpose: Purpose
    @ObservationIgnored private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    private var startTask: Task<Void, Error>?

    /// A session exists or is being started.
    var isActive: Bool { session != nil || startTask != nil }

    init(purpose: Purpose) {
        self.purpose = purpose
        super.init()
    }

    /// Starts a session unless one exists. A call made while a start is in progress awaits that same start and
    /// gets its outcome, so near-simultaneous calls give one session.
    func ensureRunning() async throws {
        if session != nil { return }
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task { try await self.start() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Takes over a session from outside: one recovered after the app was killed. The current session wins if it is
    /// still alive, since HealthKit allows only one.
    func adopt(_ newSession: HKWorkoutSession) {
        guard newSession.state != .ended else { return }
        if let session, session.state != .ended { return }
        let builder = newSession.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                     workoutConfiguration: newSession.workoutConfiguration)
        newSession.delegate = self
        self.session = newSession
        self.builder = builder
    }

    func pause() {
        guard let session, session.state == .running else { return }
        session.pause()
    }

    func resume() {
        guard let session, session.state == .paused else { return }
        session.resume()
    }

    /// Ends the session. Saves the workout when the purpose saves and `builder.elapsedTime` is at least
    /// `minimumSavedDuration`; otherwise discards it. Returns whether it was saved. A start in progress is awaited
    /// first, so a stop during the permission prompt still ends the session it produces.
    func finish() async -> Bool {
        if let startTask { _ = try? await startTask.value }
        // Taken out before the first suspension: a concurrent call, or the delegate's ended callback, finds nothing.
        guard let session, let builder else { return false }
        self.session = nil
        self.builder = nil
        session.end()
        do {
            try await builder.endCollection(at: Date())
        } catch {
            builder.discardWorkout()
            return false
        }
        guard purpose == .guidedWalk, builder.elapsedTime >= Self.minimumSavedDuration else {
            builder.discardWorkout()
            return false
        }
        do {
            try await Self.save(BuilderBox(builder: builder))
            return true
        } catch {
            return false
        }
    }

    private func start() async throws {
        if purpose == .guidedWalk, let recovered = await Self.recoverActiveSession(store) {
            adopt(recovered.session)
            if session != nil { return }
        }
        let workoutType = HKObjectType.workoutType()
        try await store.requestAuthorization(
            toShare: [workoutType],
            read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
                   HKQuantityType(.distanceWalkingRunning)])
        guard store.authorizationStatus(for: workoutType) == .sharingAuthorized else {
            throw WorkoutKeeperError.notAuthorized
        }
        // A recovered session may have been adopted while the permission request was suspended.
        if session != nil { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        let newSession = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = newSession.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        newSession.delegate = self
        let startDate = Date()
        newSession.startActivity(with: startDate)
        do {
            try await builder.beginCollection(at: startDate)
        } catch {
            newSession.end()
            builder.discardWorkout()
            throw error
        }
        // Published only now: until here the session is not ours to pause or finish. One that ended while
        // collection began (its delegate callback was ignored, since it was not yet ours) is a failed start.
        guard newSession.state != .ended else {
            builder.discardWorkout()
            throw WorkoutKeeperError.endedWhileStarting
        }
        self.session = newSession
        self.builder = builder
    }

    /// The session in the delegate callback ended or failed: finish it the normal way and tell the owner.
    private func sessionEndedOutside(_ id: ObjectIdentifier) async {
        guard let session, ObjectIdentifier(session) == id else { return }
        _ = await finish()
        onEnded?()
    }

    /// HealthKit calls the completion on its own queue. A closure written inside this main-actor class would inherit
    /// its isolation and trap there (a7da837), so it is made here, off the actor.
    nonisolated static func recoverActiveSession(_ store: HKHealthStore) async -> SessionBox? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SessionBox?, Never>) in
            store.recoverActiveWorkoutSession(completion: { @Sendable session, _ in
                continuation.resume(returning: session.map(SessionBox.init))
            })
        }
    }

    private nonisolated static func save(_ box: BuilderBox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.builder.finishWorkout(completion: { @Sendable _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// HealthKit session objects are not `Sendable`. The box only carries one from a HealthKit callback queue to the
/// main actor, where every use happens.
struct SessionBox: @unchecked Sendable {
    let session: HKWorkoutSession
}

private struct BuilderBox: @unchecked Sendable {
    let builder: HKLiveWorkoutBuilder
}

extension WorkoutKeeper: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in await self.sessionEndedOutside(id) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in await self.sessionEndedOutside(id) }
    }
}
