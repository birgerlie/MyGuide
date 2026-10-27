import SwiftUI
import WatchKit

/// State behind the watch check screen: the workout, the double-tap haptic and the phone round trip.
@MainActor
@Observable
final class WatchCheckModel {
    private static let buzzInterval: Duration = .seconds(30)
    private static let buzzCount = 5  // at 0, 30, 60, 90 and 120 s

    private(set) var workoutRunning = false
    private(set) var status = "Not started"
    private(set) var pingStatus = "Not tried"

    @ObservationIgnored private let workout = WorkoutKeeper()
    @ObservationIgnored private var buzzTask: Task<Void, Never>?

    func startWorkout() async {
        guard !workoutRunning else { return }
        do {
            try await workout.start()
        } catch {
            status = "Workout failed: \(error.localizedDescription)"
            return
        }
        workoutRunning = true
        status = "Workout running. Lower your wrist: a double buzz every 30 s for 2 min."
        buzzTask = Task { [weak self] in
            for index in 0..<Self.buzzCount {
                if index > 0 {
                    do { try await Task.sleep(for: Self.buzzInterval) } catch { return }
                }
                WKInterfaceDevice.current().play(.directionUp)
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                WKInterfaceDevice.current().play(.success)
            }
            self?.status = "Workout running. Buzzes done."
        }
    }

    func stopWorkout() async {
        buzzTask?.cancel()
        buzzTask = nil
        await workout.stop()
        workoutRunning = false
        status = "Stopped"
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status).font(.footnote)
                if model.workoutRunning {
                    Button("Stop") { Task { await model.stopWorkout() } }
                } else {
                    Button("Start workout") { Task { await model.startWorkout() } }
                }
                Button("Ping phone") { Task { await model.ping() } }
                Text(model.pingStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
