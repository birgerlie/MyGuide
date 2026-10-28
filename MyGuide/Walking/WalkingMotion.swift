import CoreMotion
import Foundation
import MyGuideCore

/// Walking mode's motion source (spec 5.1): the motion coprocessor's activity classification, which reports changes
/// only. Updates go to the main queue. A refusal, a restriction or no motion hardware means no readings (the pause
/// rules then use GPS only); it never blocks walking mode.
@MainActor
final class WalkingMotion {
    /// The longest wait for the motion prompt's answer.
    private static let permissionTimeout: Duration = .seconds(10)

    private let manager = CMMotionActivityManager()
    /// Counts starts and stops, so a reading already queued on the main queue for an earlier run is dropped.
    private var generation = 0

    /// The motion permission, or `unavailable` when the phone cannot classify activity.
    static var permission: MotionPermission {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        return switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Shows the motion prompt when access is undetermined, with a one-off activity query over the last minute, and
    /// waits for the answer (the query's callback), so the next system prompt never overlaps it. Waits at most 10 s:
    /// a callback that never comes must not hold the start up; walking mode then goes on with whatever
    /// `permission` says (GPS only unless authorized).
    func requestPermissionIfNeeded() async {
        guard Self.permission == .notDetermined else { return }
        let now = Date.now
        let once = OnceBox<Void>()
        let timeout = Task {
            try? await Task.sleep(for: Self.permissionTimeout)
            once.resume(())
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.install(continuation)
            manager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
                once.resume(())
            }
        }
        timeout.cancel()
    }

    /// Starts the activity updates when access is granted; each reading is timed at its delivery (`Date.now`), not
    /// at the activity's own start date. A second start replaces the first.
    func start(_ onReading: @escaping (MotionReading) -> Void) {
        stop()
        guard Self.permission == .authorized else { return }
        let mine = generation
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, let activity else { return }
                onReading(MotionReading(activity: Self.activity(of: activity), confidence: Self.confidence(of: activity),
                                        at: .now))
            }
        }
    }

    func stop() {
        generation += 1
        manager.stopActivityUpdates()
    }

    /// One activity by priority: automotive, cycling, running, walking, stationary, else unknown. (A car stopped at
    /// a light reports automotive and stationary together.)
    private static func activity(of activity: CMMotionActivity) -> MotionActivity {
        if activity.automotive { return .automotive }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private static func confidence(of activity: CMMotionActivity) -> MotionConfidence {
        switch activity.confidence {
        case .low: .low
        case .medium: .medium
        case .high: .high
        @unknown default: .low
        }
    }
}
