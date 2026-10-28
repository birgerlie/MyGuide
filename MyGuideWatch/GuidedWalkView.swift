import MyGuideCore
import SwiftUI

/// Main screen "Guided walk": the phone's walk state, the time walked, and the controls (spec 6.1).
struct GuidedWalkView: View {
    let model: GuidedWalkModel
    let check: WatchCheckModel

    private var phase: GuidedWalkPhase { model.state?.phase ?? .off }

    private var label: String {
        switch model.pending {
        case .start: "Starting…"
        case .pause: "Pausing…"
        case .resume: "Resuming…"
        case .stop: "Stopping…"
        case nil: model.state?.label ?? "Off"
        }
    }

    /// The watch's own failure first, else the phone's reason for the last failed start or command.
    private var problem: String? { model.error ?? model.state?.problem }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let state = model.state, state.phase != .off {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.formatted(state.activeTime(now: context.date)))
                                .font(.title2.monospacedDigit())
                        }
                    }
                    if let healthNote = model.healthNote {
                        Text(healthNote).font(.footnote).foregroundStyle(.secondary)
                    }
                    buttons
                        .disabled(model.pending != nil)
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    NavigationLink("Check") {
                        WatchCheckView(model: check, guidedWalkActive: model.hasWorkout)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Guided walk")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch phase {
        case .off:
            command("Start", systemImage: "figure.walk", .start)
        case .starting:
            command("Stop", systemImage: "stop.fill", .stop)
        case .walking:
            command("Pause", systemImage: "pause.fill", .pause)
            command("Stop", systemImage: "stop.fill", .stop)
        case .pausedAuto, .pausedManual:
            command("Resume", systemImage: "play.fill", .resume)
            command("Stop", systemImage: "stop.fill", .stop)
        }
    }

    private func command(_ title: String, systemImage: String, _ command: GuidedWalkCommand) -> some View {
        Button {
            Task { await model.send(command) }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    /// `h:mm:ss`, whole seconds rounded down. 3725 s → "1:02:05"; 59.9 s → "0:00:59".
    static func formatted(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
