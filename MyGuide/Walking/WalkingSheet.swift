import MyGuideCore
import SwiftUI

/// What the walking line opens (spec 14, amended 2026-10-30): everything walking mode used to show in the «Rundt deg»
/// sheet. Running: the walking panel (status with the buzz count, the story, Pause and Avslutt). Paused (spec 16.4):
/// «Fortsett turen», the status, and a quiet way to end. With a tour (tours spec 6) the tour panel comes first, and
/// under it the walking panel or, while walking mode is paused or off (a restored tour), «Fortsett turen»; the tour
/// panel's «Avslutt turen» is then the one way to end. It closes itself when the walk and the tour are both over.
struct WalkingSheet: View {
    let walking: WalkingController
    let position: Coordinate?
    let language: StoryLanguage

    @Environment(\.dismiss) private var dismiss

    private var isActive: Bool { walking.isOn || walking.tour != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                Text(AroundTexts.walkingSheetTitle(language))
                    .font(Theme.Font.display)
                    .accessibilityAddTraits(.isHeader)
                content
                if walking.isOn, let problem = walking.problems.first {
                    Label(problem.text(language), systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.wideMargin)
            .padding(.top, Theme.Spacing.wideMargin)
            .padding(.bottom, Theme.Spacing.margin)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Theme.Colour.text)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Colour.background)
        .onChange(of: isActive) { _, active in
            if !active { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tour = walking.tour {
            TourPanel(walking: walking, tour: tour, position: position, language: language)
            if walking.isOn, !walking.isPaused {
                WalkingPanel(walking: walking, language: language, showsStop: false)
            } else if !tour.isFinished {
                VStack(spacing: Theme.Spacing.unit) {
                    WalkButton(walking: walking, language: language)
                    if walking.isOn { pausedStatus }
                }
            }
        } else if walking.isOn, !walking.isPaused {
            WalkingPanel(walking: walking, language: language)
        } else if walking.isOn {
            VStack(spacing: Theme.Spacing.unit) {
                WalkButton(walking: walking, language: language)
                pausedStatus
                Button(AroundTexts.stopWalk(language)) { walking.stop() }
                    .font(Theme.Font.bodyMedium)
                    .underline()
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.minimumTouchHeight)
            }
        }
    }

    /// The paused walk's status with its buzz count, refreshed every second.
    private var pausedStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let status = WalkingStatus.text(isOn: true, lastFixAt: walking.lastFixAt,
                                               buzzCount: walking.buzzCount, now: context.date,
                                               pause: walking.pauseKind, language: language) {
                Label(status, systemImage: "pause.circle")
                    .font(.custom(Theme.FontName.regular, size: 15, relativeTo: .subheadline))
                    .opacity(0.75)
            }
        }
    }
}

/// The wide coral button: «Gå en tur» starts walking mode; while a walk is paused, «Fortsett turen» resumes it.
/// With a tour and walking mode off (restored, or stopped by the app), «Fortsett turen» starts walking mode on it.
struct WalkButton: View {
    let walking: WalkingController
    let language: StoryLanguage

    var body: some View {
        let paused = walking.isOn
        let continues = paused || walking.tour != nil
        Button {
            if paused {
                walking.resume(source: .phone)
            } else {
                Task { await walking.start() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: continues ? "play.fill" : "figure.walk")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityHidden(true)
                Text(continues ? AroundTexts.continueWalk(language) : AroundTexts.goForAWalk(language))
                    .font(.custom(Theme.FontName.medium, size: 20, relativeTo: .title3))
                Spacer(minLength: 0)
                if walking.isStarting {
                    ProgressView().tint(Theme.Colour.forest)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 56)
        }
        .buttonStyle(.themePrimary(.coral))
        .disabled(walking.isStarting)
    }
}
