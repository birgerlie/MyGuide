import HealthKit
import WatchKit

/// Owns the app's models, so the system's workout callbacks reach them even before the first screen appears.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let walk = GuidedWalkModel()
    let check = WatchCheckModel()

    override init() {
        super.init()
        // HealthKit allows one session: the Check screen's test workout gives way to a guided walk.
        walk.willStartWorkout = { [check] in await check.stopWorkoutIfRunning() }
    }

    /// The phone called `startWatchApp(with:)`: begin the workout. The walk state comes from the application context.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        walk.startForWorkoutLaunch()
    }

    /// The app was killed during a workout and relaunched to pick it up again.
    func handleActiveWorkoutRecovery() {
        Task {
            guard let recovered = await WorkoutKeeper.recoverActiveSession(HKHealthStore()) else { return }
            walk.adopt(recovered.session)
        }
    }
}
