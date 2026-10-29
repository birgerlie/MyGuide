import MyGuideCore
import SwiftUI
import UIKit

/// A walking story in the app (a tap on its notification, or the panel's title), in the photo story screen's layout
/// (spec 8): the place's Wikipedia picture across the top when there is one, the ivory sheet with «STED I NÆRHETEN»
/// («HER DU STOPPET» for a stop story), the name in Playfair and where it was from the walker, then «KORT FORTELLING»
/// and every level with `StoryText` (deeper levels with their own label and Lytt), «Mer om …» and «Kilder», and
/// «Lytt til fortellingen» at the bottom. «Hopp over dette stedet» is a quiet link for a buzz story. The buttons send
/// the same commands as the notifications, so this is also the last fallback when the lock screen fails. Opening a
/// buzz or chosen story counts as reading it (spec 13.2), once per opening, as soon as its text shows.
struct WalkStoryView: View {
    let stories: WalkingStories
    let placeImages: PlaceImages
    let id: UUID

    /// The story as saved in memory, for one from an earlier run; read once when the screen opens.
    @State private var stored: WalkStory?
    @State private var loaded = false
    /// The story this screen has marked read; at most once per opening.
    @State private var markedRead: UUID?
    /// The place's picture and its credit, once loaded; nil while loading, without a picture, and for a stop story.
    @State private var picture: UIImage?
    @State private var pictureInfo: PlaceImageInfo?
    @State private var showingSources = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .foregroundStyle(Theme.Colour.text)
            .background(Theme.Colour.background.ignoresSafeArea())
            .navigationTitle(story.map(Self.name) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: id) {
                stored = stories.storedStory(id)
                loaded = true
                markReadOnce()
            }
            // A story still preparing when the screen opened is read once its text arrives.
            .onChange(of: story != nil) { markReadOnce() }
            .task(id: pictureTitle) { await loadPicture() }
            .sheet(isPresented: $showingSources) {
                if let story {
                    // The photo credit's wording belongs to the story; the sheet's own words are screen texts.
                    SourcesSheet(sources: StorySources.list(for: story, image: pictureInfo, language: story.language),
                                 language: UILanguage.current,
                                 emptyText: WalkStoryText.noPlaceSources(UILanguage.current),
                                 note: WalkStoryText.aiNote(UILanguage.current))
                }
            }
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

    /// The failure of this story's latest command (preparing, "more", a level's speech), in words in `language`; nil
    /// when none.
    private func failure(_ language: StoryLanguage) -> String? {
        guard let failure = stories.lastFailure, failure.id == id else { return nil }
        return failure.text(language)
    }

    @ViewBuilder
    private var content: some View {
        if let story {
            storyPage(story)
        } else if !loaded || stories.isPreparing(id) {
            preparing
        } else {
            gone
        }
    }

    // MARK: - Preparing and gone

    /// The story's text is being written: the same sheet with the step in words and Lytt disabled.
    private var preparing: some View {
        let language = UILanguage.current
        return StorySheetPage(photo: nil) {
            HStack(spacing: Theme.Spacing.unit) {
                ProgressView()
                Text(ScreenText.writing(language))
                    .font(Theme.Font.bodyMedium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .safeAreaInset(edge: .bottom) {
            ListenBar(language: language, enabled: false, action: {})
        }
    }

    /// No prepared or stored story: the failure that ended it when there is one, else that it is gone.
    private var gone: some View {
        let language = UILanguage.current
        let message = failure(language)
        return StorySheetPage(photo: nil) {
            Label {
                Text(message ?? WalkingStories.goneText(language))
                    .font(Theme.Font.body)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(message == nil ? Theme.Colour.text : .red)
        }
    }

    // MARK: - Story

    /// The screen's words in the iPhone's language; the story's text and its photo credit in the story's language.
    private func storyPage(_ story: WalkStory) -> some View {
        let language = UILanguage.current
        let shownCredit = pictureInfo.flatMap {
            NotificationText.photoCredit(author: $0.author, licence: $0.licence, story.language)
        }
        return StorySheetPage(photo: picture, photoCredit: shownCredit) {
            header(story)
            StoryDivider()
            SectionLabel(ScreenText.shortStory(language))
            ForEach(Array(story.levels.enumerated()), id: \.offset) { index, text in
                if index == 0 {
                    StoryText(text: text, selectable: true)
                } else {
                    // Each deeper level gets its own label and Lytt; the bottom button reads the short story (level 1).
                    SectionLabel(ScreenText.moreLabel(index, language))
                        .padding(.top, Theme.Spacing.unit)
                    StoryText(text: text, selectable: true)
                    levelListenButton(level: index + 1, language: language)
                }
            }
            MoreSourcesRow(
                language: language,
                moreTitle: story.nextLevel.map {
                    ScreenText.more($0, name: story.kind == .stop ? nil : Self.name(story), language)
                },
                working: stories.fetchingMore.contains(id),
                onMore: { stories.more(id) },
                onSources: { showingSources = true })
            // A stop story has no place to skip, and a chosen place was asked for.
            if story.canSkip {
                Button {
                    stories.skip(id)
                    dismiss()
                } label: {
                    Text(WalkStoryText.skip(language))
                        .font(Theme.Font.body)
                        .underline()
                        .opacity(0.75)
                        .frame(minHeight: Theme.minimumTouchHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            listenBar(language: language)
        }
    }

    /// The status label, the name in Playfair and the line with where the place was from the walker. The label stays
    /// its own VoiceOver heading; the name and the where-line are read as one.
    private func header(_ story: WalkStory) -> some View {
        let language = UILanguage.current
        return VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            SectionLabel(story.kind == .stop
                         ? NotificationText.stoppedLabel(language) : NotificationText.nearbyLabel(language))
            VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
                Text(Self.name(story))
                    .font(Theme.Font.display)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = WalkStoryText.whereLine(story) {
                    Label {
                        Text(line).font(Theme.Font.body)
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.Colour.coral)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bottom: "Lytt til fortellingen" plays level 1, or stops this story's level 1 while it plays or loads.
    /// The story is saved in the diary when its text arrives; a failed save says so (`saveFailedIDs`).
    private func listenBar(language: StoryLanguage) -> some View {
        let listening = listening(level: 1)
        return ListenBar(
            language: language,
            isActive: listening != nil,
            isLoading: listening?.isLoading == true,
            enabled: listening != nil || stories.canListen(id, level: 1),
            failure: failure(language),
            diaryStatus: stories.saveFailedIDs.contains(id) ? .saveFailed : .saved,
            action: { toggle(level: 1, active: listening != nil) })
    }

    /// Lytt / Stopp for a deeper level (1-based, as `WalkingStories` counts).
    private func levelListenButton(level: Int, language: StoryLanguage) -> some View {
        let listening = listening(level: level)
        return LevelListenButton(
            language: language,
            isActive: listening != nil,
            isLoading: listening?.isLoading == true,
            enabled: listening != nil || stories.canListen(id, level: level),
            action: { toggle(level: level, active: listening != nil) })
    }

    /// This story's level in the player (playing, or its speech loading); nil otherwise.
    private func listening(level: Int) -> WalkingStories.Listening? {
        guard let listening = stories.listening, listening.id == id, listening.level == level else { return nil }
        return listening
    }

    private func toggle(level: Int, active: Bool) {
        if active { stories.stopListening() } else { stories.listen(id, level: level) }
    }

    /// The place's name for a buzz or chosen story; the story's title for a stop story (no place).
    private static func name(_ story: WalkStory) -> String {
        guard story.kind != .stop, let place = story.place else { return story.title }
        return place.name
    }

    // MARK: - Picture

    /// The place's Wikipedia title; nil for a stop story, before the story is known, or for a place with no article.
    private var pictureTitle: String? {
        guard let story, story.kind != .stop, let place = story.place else { return nil }
        return PlaceImages.title(for: place)
    }

    /// From the cache, else fetched once on demand (spec 12.6; no cap here, the cap is for notifications). The file
    /// is decoded off the main thread. Without a title, a picture or a decodable file there is no hero.
    private func loadPicture() async {
        picture = nil
        pictureInfo = nil
        guard let title = pictureTitle,
              let storedImage = await placeImages.image(wikipediaTitle: title), !Task.isCancelled else { return }
        let url = storedImage.fileURL
        let decoded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
        guard !Task.isCancelled, let decoded else { return }
        picture = decoded
        pictureInfo = storedImage.info
    }
}

/// The walk story screen's texts, in the language they are given (`UILanguage.current`, spec 17).
enum WalkStoryText {
    static func skip(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hopp over dette stedet" : "Skip this place"
    }

    static func noPlaceSources(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ingen stedskilder. Fortellingen bygger bare på posisjonen."
            : "No place sources. The story is based only on the position."
    }

    static func aiNote(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Fortellingen er skrevet av en AI-modell (OpenAI) ut fra posisjonen og kildene over. Den kan ta feil."
            : "The story is written by an AI model (OpenAI) from the position and the sources above. It can be wrong."
    }

    /// "Roma, Italia · 50 m · til venstre for deg": the walker's address city line when known, then (a buzz or chosen
    /// story) the distance and the place's direction relative to the walking direction when the story was made
    /// (`AroundText.whereLine`, "i nærheten · 50 m" without a course). A stop story has only the city line; nil with
    /// neither part. The words are screen texts, in the iPhone's language.
    static func whereLine(_ story: WalkStory) -> String? {
        var parts = [PlaceLocationLine.text(story.address)].compactMap { $0 }
        if story.kind != .stop, let place = story.place {
            let distance = GeoMath.distance(story.position, place.coordinate)
            let relative = story.course.map {
                PlaceSelector.offset(heading: $0, bearing: GeoMath.bearing(from: story.position, to: place.coordinate))
            }
            parts.append(AroundText.whereLine(distance: distance, relative: relative, language: UILanguage.current))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
