import MyGuideCore
import SwiftUI

/// The walking story that is playing or ready, above the capture controls: its title (tap to open it), Play/Stop,
/// More and, for a buzz story, Skip. Above it, while the engine is quiet because every due place is used, a line
/// says so (spec 13.7).
struct WalkingPanel: View {
    let walking: WalkingController

    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english

    private var stories: WalkingStories { walking.stories }

    var body: some View {
        VStack(spacing: 8) {
            if walking.heardEverythingNearby {
                Label(Self.heardEverythingText(storyLanguage), systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }
            storyRow
        }
    }

    static func heardEverythingText(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Du har hørt om alt i nærheten" : "You've heard about everything nearby"
    }

    @ViewBuilder
    private var storyRow: some View {
        if let story = stories.featuredStory {
            let playing = stories.listening?.id == story.id
            HStack(spacing: 12) {
                Button {
                    stories.open(story.id)
                } label: {
                    Text(story.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    if playing { stories.stopListening() } else { stories.tellMe(story.id) }
                } label: {
                    icon(playing ? "stop.fill" : "play.fill")
                }
                .accessibilityLabel(playing ? "Stop story" : "Play story")
                Button {
                    stories.more(story.id)
                } label: {
                    if stories.fetchingMore.contains(story.id) {
                        ProgressView().tint(.white).frame(width: 44, height: 44)
                    } else {
                        icon("forward.fill")
                    }
                }
                .accessibilityLabel("More")
                .disabled(!stories.canMore(story.id))
                // A stop story has no place to skip.
                if story.canSkip {
                    Button {
                        stories.skip(story.id)
                    } label: {
                        icon("xmark")
                    }
                    .accessibilityLabel("Skip")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
    }
}
