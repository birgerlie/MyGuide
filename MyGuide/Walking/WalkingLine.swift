import MyGuideCore
import SwiftUI

/// Walking mode in one line over the tab bar while a walk or a tour runs (spec 14, amended 2026-10-30), refreshed
/// every second. It says the most pressing thing first: a problem (e.g. location Always missing), waiting for GPS, the
/// walking story that is playing or ready (with Lytt/Stopp beside it), paused, the tour's next stop, and otherwise
/// «Gåmodus · 42 min». A tap anywhere but Lytt/Stopp opens the walking sheet (`WalkingSheet`) with the buzz count,
/// Pause, Avslutt and the tour's buttons.
struct WalkingLine: View {
    let walking: WalkingController
    /// The owner's position, for the distance to the next stop; nil leaves the distance out.
    let position: Coordinate?
    let language: StoryLanguage
    let open: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(now: context.date)
        }
        .foregroundStyle(Theme.Colour.text)
    }

    private func row(now: Date) -> some View {
        let content = Self.content(walking: walking, position: position, now: now, language: language)
        return HStack(spacing: Theme.Spacing.unit) {
            Button(action: open) {
                HStack(spacing: Theme.Spacing.unit) {
                    Label(content.text, systemImage: content.symbol)
                        .font(Theme.Font.bodyMedium)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.5)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Theme.minimumTouchHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(AroundTexts.walkingLineHint(language))
            if let story = content.story {
                let playing = walking.stories.listening?.id == story.id
                Button {
                    if playing { walking.stories.stopListening() } else { walking.stories.tellMe(story.id) }
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colour.forest)
                        .frame(width: 36, height: 36)
                        .background(Theme.Colour.coral, in: Circle())
                        .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? AroundTexts.stop(language) : AroundTexts.listen(language))
            }
        }
        .padding(.horizontal, Theme.Spacing.margin)
    }

    /// What the line says, its symbol, and the story whose Lytt/Stopp sits beside it. Ranked: problem, waiting for
    /// GPS, story, paused, tour, walking. A restored tour with walking mode off reads as the tour.
    static func content(walking: WalkingController, position: Coordinate?, now: Date, language: StoryLanguage)
        -> (text: String, symbol: String, story: WalkStory?) {
        if walking.isOn, let problem = walking.problems.first {
            return (problem.text(language), "exclamationmark.triangle", nil)
        }
        let line = WalkingStatus.line(isOn: walking.isOn, startedAt: walking.startedAt, lastFixAt: walking.lastFixAt,
                                      now: now, pause: walking.pauseKind, language: language)
        if case .waitingForGPS(let text) = line { return (text, "location.slash", nil) }
        if let story = walking.stories.featuredStory { return (story.title, "headphones", story) }
        if case .paused(let text) = line { return (text, "pause.circle", nil) }
        if let tour = walking.tour {
            let tourLine = TourPanel.line(tour, position: position, language: language)
            return (tourLine.text, tourLine.symbol, nil)
        }
        return (line?.text ?? AroundTexts.goForAWalk(language), "figure.walk.motion", nil)
    }
}
