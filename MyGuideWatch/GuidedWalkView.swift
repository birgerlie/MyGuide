import MyGuideCore
import SwiftUI

/// Main screen "Guided walk": the phone's walk state, the time walked, the next stop while the phone runs a tour, and
/// the controls (spec 6.1). In the design colours with the system font (spec 15): forest green behind, ivory text, the
/// main command ivory and the others stone. Words follow the watch's language (`WatchTexts`); the next stop's line is
/// the phone's, in the iPhone's language, as a buzz's line is.
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
    private var problem: String? { model.error ?? model.state?.problem.map(WatchTexts.problem) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let buzz = model.buzz {
                        buzzCard(buzz)
                    }
                    Text(label)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let state = model.state, state.phase != .off {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.formatted(state.activeTime(now: context.date)))
                                .font(.title2.monospacedDigit())
                        }
                        // A tour on the phone: its next stop and distance, worded by the phone (tours spec 7).
                        if let nextStop = state.nextStop {
                            Label(nextStop.line, systemImage: "mappin.and.ellipse")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
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

    /// The place the phone just buzzed about, first on screen: heading, name and direction, and «Lytt», which asks
    /// the phone to tell its story (spec 18).
    private func buzzCard(_ buzz: GuidedWalkBuzz) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(WatchTexts.nearbyPlace, systemImage: "mappin.and.ellipse")
                .font(.footnote)
                .foregroundStyle(WatchColour.coral)
            Text(buzz.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(buzz.line)
                .font(.footnote)
                .opacity(0.75)
            Button {
                Task { await model.listenToBuzz() }
            } label: {
                Label(WatchTexts.listen, systemImage: "headphones")
            }
            .buttonStyle(WatchButtonStyle(coral: true))
            .disabled(model.listeningBuzzID == buzz.id)
            .padding(.top, 4)
            if let note = model.buzzNote {
                Text(note).font(.footnote).opacity(0.75)
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
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
        // While a buzz card shows, its coral «Lytt» is the screen's one main action and the walk's commands are stone.
        .buttonStyle(WatchButtonStyle(primary: primary && model.buzz == nil))
    }

    /// `h:mm:ss`, whole seconds rounded down. 3725 s → "1:02:05"; 59.9 s → "0:00:59".
    static func formatted(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
