import SwiftUI
import WatchKit

/// State behind the watch check screen: a throwaway test workout with the double-tap haptic, and the phone round
/// trip. The test workout is always discarded, and it must never run beside a guided walk workout.
@MainActor
@Observable
final class WatchCheckModel {
    private static let buzzInterval: Duration = .seconds(30)
    private static let buzzCount = 5  // at 0, 30, 60, 90 and 120 s

    private(set) var workoutRunning = false
    private(set) var workoutStarting = false
    private(set) var status = "Not started"
    private(set) var pingStatus = "Not tried"

    @ObservationIgnored private let workout = WorkoutKeeper(purpose: .test)
    @ObservationIgnored private var buzzTask: Task<Void, Never>?

    func startWorkout() async {
        // Set synchronously: the first-run permission prompt suspends, and a second tap must not start another session.
        guard !workoutRunning, !workoutStarting else { return }
        workoutStarting = true
        defer { workoutStarting = false }
        do {
            try await workout.ensureRunning()
        } catch {
            status = "Test failed: \(error.localizedDescription)"
            return
        }
        // Stopped while the permission prompt was up (a guided walk started).
        guard workout.isActive else { return }
        workoutRunning = true
        status = "Test running. Lower your wrist: a double buzz every 30 s for 2 min."
        buzzTask = Task { [weak self] in
            for index in 0..<Self.buzzCount {
                if index > 0 {
                    do { try await Task.sleep(for: Self.buzzInterval) } catch { return }
                }
                WKInterfaceDevice.current().play(.directionUp)
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                WKInterfaceDevice.current().play(.success)
            }
            self?.status = "Test running. Buzzes done."
        }
    }

    func stopWorkout() async {
        buzzTask?.cancel()
        buzzTask = nil
        _ = await workout.finish()
        // A start that was awaiting the permission prompt may have begun the buzzes while `finish` waited for it.
        buzzTask?.cancel()
        buzzTask = nil
        workoutRunning = false
        status = "Stopped"
    }

    /// Ends the test workout, if any, before a guided walk workout starts.
    func stopWorkoutIfRunning() async {
        guard workoutRunning || workoutStarting else { return }
        await stopWorkout()
    }

    func ping() async {
        pingStatus = "Pinging…"
        let start = ContinuousClock.now
        do {
            let reply = try await PhoneLink.shared.send(["type": "ping"])
            guard reply["type"] as? String == "pong" else { throw PhoneLinkError.unexpectedReply }
            let elapsed = ContinuousClock.now - start
            let ms = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            pingStatus = "Pong in \(ms) ms"
        } catch {
            pingStatus = "Failed: \(error.localizedDescription)"
        }
    }
}

struct WatchCheckView: View {
    let model: WatchCheckModel
    /// HealthKit allows one workout session: the test cannot start during a guided walk workout.
    let guidedWalkActive: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status).font(.footnote)
                if model.workoutRunning {
                    Button("Stop") { Task { await model.stopWorkout() } }
                } else {
                    Button("Start haptic test") { Task { await model.startWorkout() } }
                        .disabled(model.workoutStarting || guidedWalkActive)
                    if guidedWalkActive {
                        Text("Not available during a guided walk.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Ping phone") { Task { await model.ping() } }
                Text(model.pingStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
