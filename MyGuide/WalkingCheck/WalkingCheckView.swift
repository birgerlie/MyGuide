import SwiftUI

/// Checks, on the owner's own device, that background location and audio from a notification action work.
struct WalkingCheckView: View {
    let model: WalkingCheckModel
    let watch: WatchLink

    var body: some View {
        // Pushed from Settings, so it lives in the app's NavigationStack rather than its own.
        List {
            row("Background location", status: model.locationStatus, result: model.locationResult) {
                Button(model.locationRunning ? "Stop" : "Start") {
                    if model.locationRunning { model.stopLocation() } else { model.startLocation() }
                }
            }
            row("Buzz from the watch", status: model.buzzStatus, result: model.buzzResult) {
                Button(model.buzzPending ? "Cancel" : "Send test notification") {
                    if model.buzzPending { model.cancelBuzz() } else { Task { await model.startBuzz() } }
                }
            }
            row("Live Activity", status: model.activityStatus, result: model.activityResult) {
                Button(model.activityRunning ? "End" : "Start") {
                    if model.activityRunning { model.endActivity() } else { Task { await model.startActivity() } }
                }
            }
            row("Watch", status: watchStatus, result: model.watchTellResult) {
                Text(model.watchTellStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Walking check")
    }

    private var watchStatus: String {
        let link = "Paired: \(yesNo(watch.isPaired)) · app installed: \(yesNo(watch.isInstalled)) · reachable: \(yesNo(watch.isReachable))"
        return "\(link) · last message: \(watch.lastReceived ?? "none")"
    }

    private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    @ViewBuilder
    private func row(_ title: String, status: String, result: CheckResult?,
                     @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .top) {
            Text(result == nil ? "…" : (result!.passed ? "✓" : "✗"))
                .foregroundStyle(result?.passed == true ? .green : (result == nil ? .secondary : .red))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(status).font(.footnote).foregroundStyle(.secondary)
                if let result {
                    Text(result.detail).font(.footnote).foregroundStyle(result.passed ? .green : .red)
                }
                button().buttonStyle(.bordered)
            }
        }
    }
}
