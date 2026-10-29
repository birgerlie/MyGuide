import MyGuideCore
import SwiftUI

/// Walking mode in the «Rundt deg» sheet, in the place of «Gå en tur» while a walk runs (spec 14): the status
/// ("Går · 2 varsler", refreshed every second so a stale fix turns into "venter på GPS"), the «hørt om alt» line while
/// the engine is quiet because every due place is used (spec 13.7), the walking story that is playing or ready (its
/// title opens it; Lytt/Stopp, Mer and, for a buzz story, Hopp over), and Pause and Avslutt turen. A paused walk
/// shows «Fortsett turen» in the sheet instead (spec 16.4).
struct WalkingPanel: View {
    let walking: WalkingController
    let language: StoryLanguage

    private var stories: WalkingStories { walking.stories }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let text = WalkingStatus.text(isOn: walking.isOn, lastFixAt: walking.lastFixAt,
                                                 buzzCount: walking.buzzCount, now: context.date,
                                                 pause: walking.pauseKind, language: language) {
                    Label(text, systemImage: walking.isPaused ? "pause.circle" : "figure.walk.motion")
                        .font(Theme.Font.bodyMedium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Hidden while paused (`heardEverythingNearby` is false then): no decisions are made, so it could be stale.
            if walking.heardEverythingNearby {
                Label(Self.heardEverythingText(language), systemImage: "checkmark.circle")
                    .font(Theme.Font.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            storyRow
            HStack(spacing: 12) {
                // A paused walk shows «Fortsett turen» in the sheet instead of this panel (spec 16.4).
                Button {
                    walking.pause(source: .phone)
                } label: {
                    Label(AroundTexts.pause(language), systemImage: "pause.fill")
                }
                .buttonStyle(.themeSecondary)
                // Secondary, not forest: ending the walk is not the main action here.
                Button {
                    walking.stop()
                } label: {
                    Label(AroundTexts.stopWalk(language), systemImage: "stop.fill")
                }
                .buttonStyle(.themeSecondary)
            }
        }
        .foregroundStyle(Theme.Colour.text)
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
    }

    static func heardEverythingText(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Du har hørt om alt i nærheten" : "You've heard about everything nearby"
    }

    @ViewBuilder
    private var storyRow: some View {
        if let story = stories.featuredStory {
            let playing = stories.listening?.id == story.id
            HStack(spacing: Theme.Spacing.unit) {
                Button {
                    stories.open(story.id)
                } label: {
                    Text(story.title)
                        .font(.custom(Theme.FontName.display, size: 17, relativeTo: .headline))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    if playing { stories.stopListening() } else { stories.tellMe(story.id) }
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Colour.forest)
                        .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                        .background(Theme.Colour.coral, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? AroundTexts.stop(language) : AroundTexts.listen(language))
                Button {
                    stories.more(story.id)
                } label: {
                    if stories.fetchingMore.contains(story.id) {
                        ProgressView().tint(Theme.Colour.text).frame(width: 44, height: 44)
                    } else {
                        icon("forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AroundTexts.more(language))
                .disabled(!stories.canMore(story.id))
                // A stop story has no place to skip.
                if story.canSkip {
                    Button {
                        stories.skip(story.id)
                    } label: {
                        icon("xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AroundTexts.skip(language))
                }
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.Colour.text)
            .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
            .contentShape(Rectangle())
    }
}
