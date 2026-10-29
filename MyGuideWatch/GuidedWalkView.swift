import MyGuideCore
import SwiftUI

/// Main screen "Guided walk": the phone's walk state, the time walked, and the controls (spec 6.1). In the design
/// colours with the system font (spec 15): forest green behind, ivory text, the main command ivory and the others
/// stone. Words follow the watch's language (`WatchTexts`).
struct GuidedWalkView: View {
    let model: GuidedWalkModel
    let check: WatchCheckModel

    private var phase: GuidedWalkPhase { model.state?.phase ?? .off }

    private var label: String {
        switch model.pending {
        case .start: WatchTexts.starting
        case .pause: WatchTexts.pausing
        case .resume: WatchTexts.resuming
        case .stop: WatchTexts.stopping
        case nil: WatchTexts.label(model.state)
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
                        Text(healthNote).font(.footnote).opacity(0.75)
                    }
                    buttons
                        .disabled(model.pending != nil)
                    if let problem {
                        // A symbol with the coral, so the problem never rests on colour alone.
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(WatchColour.coral)
                    }
                    NavigationLink(WatchTexts.check) {
                        WatchCheckView(model: check, guidedWalkActive: model.hasWorkout)
                    }
                    .buttonStyle(WatchButtonStyle())
                    .padding(.top, 8)
                }
                .foregroundStyle(WatchColour.ivory)
            }
            .navigationTitle(WatchTexts.title)
            .containerBackground(WatchColour.forest.gradient, for: .navigation)
        }
        .tint(WatchColour.coral)
    }

    @ViewBuilder private var buttons: some View {
        switch phase {
        case .off:
            command(WatchTexts.start, systemImage: "figure.walk", .start, primary: true)
        case .starting:
            command(WatchTexts.stop, systemImage: "stop.fill", .stop)
        case .walking:
            command(WatchTexts.pause, systemImage: "pause.fill", .pause, primary: true)
            command(WatchTexts.stop, systemImage: "stop.fill", .stop)
        case .pausedAuto, .pausedManual:
            command(WatchTexts.resume, systemImage: "play.fill", .resume, primary: true)
            command(WatchTexts.stop, systemImage: "stop.fill", .stop)
        }
    }

    private func command(_ title: String, systemImage: String, _ command: GuidedWalkCommand,
                         primary: Bool = false) -> some View {
        Button {
            Task { await model.send(command) }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(WatchButtonStyle(primary: primary))
    }

    /// `h:mm:ss`, whole seconds rounded down. 3725 s → "1:02:05"; 59.9 s → "0:00:59".
    static func formatted(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
