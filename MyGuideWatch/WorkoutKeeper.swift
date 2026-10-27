import HealthKit

/// Keeps the watch app running with the wrist down by holding a walking workout session.
/// The workout is discarded on stop: it exists only to keep the app alive.
@MainActor
final class WorkoutKeeper: NSObject {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    var isRunning: Bool { session != nil }

    func start() async throws {
        guard session == nil else { return }
        try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        self.session = session
        self.builder = builder
        let startDate = Date()
        session.startActivity(with: startDate)
        do {
            try await builder.beginCollection(at: startDate)
        } catch {
            session.end()
            self.session = nil
            self.builder = nil
            throw error
        }
    }

    func stop() async {
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        session.end()
        do {
            try await builder.endCollection(at: Date())
        } catch {
            // The workout is thrown away either way.
        }
        builder.discardWorkout()
    }
}
