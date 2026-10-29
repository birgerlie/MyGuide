import MyGuideCore
import SwiftUI

/// A walking story in the app (a tap on its notification, or the panel's title): title, every level's text with a
/// speaker button, "Tell me more" and "Skip this place". The buttons send the same commands as the notifications,
/// so this is also the last fallback when the lock screen fails. Opening a buzz or chosen story counts as reading it
/// (spec 13.2), once per opening, as soon as its text shows.
struct WalkStoryView: View {
    let stories: WalkingStories
    let id: UUID

    /// The story as saved in memory, for one from an earlier run; read once when the screen opens.
    @State private var stored: WalkStory?
    @State private var loaded = false
    /// The story this screen has marked read; at most once per opening.
    @State private var markedRead: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle("Story")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: id) {
                stored = stories.storedStory(id)
                loaded = true
                markReadOnce()
            }
            // A story still preparing when the screen opened is read once its text arrives.
            .onChange(of: story != nil) { markReadOnce() }
    }

    private func markReadOnce() {
        guard loaded, markedRead != id, let story else { return }
        markedRead = id
        stories.markRead(story)
    }

    /// The prepared copy gains levels as they arrive; the stored one covers stories no longer prepared.
    private var story: WalkStory? {
        let live = stories.story(id)
        guard let stored else { return live }
        guard let live else { return stored }
        return live.levels.count >= stored.levels.count ? live : stored
    }

    @ViewBuilder
    private var content: some View {
        if let story {
            text(story)
        } else if !loaded || stories.isPreparing(id) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(WalkingStories.goneText)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func text(_ story: WalkStory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(story.title)
                    .font(.title2.bold())
                ForEach(Array(story.levels.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: 8) {
                        StoryText(text: text, font: .body, selectable: true)
                        speaker(level: index + 1)
                    }
                }
                if let failure = stories.lastFailure, failure.id == id {
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if story.nextLevel != nil {
                    let working = stories.fetchingMore.contains(id)
                    Button {
                        stories.more(id)
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView() }
                            Text("Tell me more")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                }
                // A stop story has no place to skip.
                if story.canSkip {
                    Button("Skip this place", role: .destructive) {
                        stories.skip(id)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    /// Play/Stop for one level, as on the photo story screen.
    @ViewBuilder
    private func speaker(level: Int) -> some View {
        let listening = stories.listening.flatMap { $0.id == id && $0.level == level ? $0 : nil }
        HStack(spacing: 12) {
            Button {
                if listening != nil { stories.stopListening() } else { stories.listen(id, level: level) }
            } label: {
                if listening != nil {
                    Label("Stop", systemImage: "stop.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(listening == nil && !stories.canListen(id, level: level))
            if listening?.isLoading == true { ProgressView().controlSize(.small) }
        }
    }
}
