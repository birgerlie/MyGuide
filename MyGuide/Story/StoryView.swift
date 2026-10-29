import MyGuideCore
import SwiftUI
import UIKit

/// One photo's story, laid out as the owner's sketch: the photo across the top, an ivory sheet over its lower edge
/// with the status ("STED FUNNET" / "TROLIG STED" / "KANSKJE" / not sure), the place name, where it is, then
/// "KORT FORTELLING" and the text, with Mer and Kilder as quiet links. "Lytt til fortellingen" sits at the bottom
/// with the diary status under it. While it is found and written the same layout shows the steps in words
/// ("Finner stedet …", the likely place, "Skriver fortellingen …" and the text as it streams in), with Lytt disabled.
struct StoryView: View {
    let model: StoryViewModel
    let location: LocationProvider
    @State private var showingSources = false

    var body: some View {
        content
            .foregroundStyle(Theme.Colour.text)
            .background(Theme.Colour.background.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSources) {
                if let session = model.session {
                    SourcesSheet(sources: StorySources.list(for: session), language: language,
                                 emptyText: ScreenText.noPlaceSources(language), note: ScreenText.aiNote(language))
                }
            }
    }

    private var language: StoryLanguage { model.language }

    /// The place's name once identified; empty while guessing or when not sure.
    private var navigationTitle: String {
        guard let card = model.card, card.mark == .identified else { return "" }
        return card.name
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .finding, .guess, .writing:
            progress
        case .showing:
            if let session = model.session {
                story(session)
            }
        case .failed(let message, let canUseCurrentPosition):
            failure(message: message, canUseCurrentPosition: canUseCurrentPosition)
        }
    }

    // MARK: - Place header

    /// The status label, the name in Playfair and the line with where it is. "Unsure" shows the not-sure sentence in
    /// place of a name, so an uncertain identification never looks like a found place (design guidelines).
    @ViewBuilder
    private func placeHeader(_ card: PlaceCard, confidence: SubjectConfidence?, address: Address?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            switch card.mark {
            case .unsure:
                SectionLabel(ScreenText.unsureLabel(language))
                Text(ScreenText.notSure(language))
                    .font(Theme.Font.title)
            case .guess, .identified:
                SectionLabel(ScreenText.statusLabel(card.mark, confidence: confidence, language))
                Text(card.name)
                    .font(Theme.Font.display)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = ScreenText.whereLine(card, address: address, language) {
                    Label {
                        Text(line).font(Theme.Font.body)
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.Colour.coral)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - While working

    /// Each step replaces the one before, and every spinner has words next to it.
    private var progress: some View {
        StorySheetPage(photo: model.photoPreview) {
            if let card = model.card {
                placeHeader(card, confidence: nil, address: nil)
            } else {
                step(ScreenText.finding(language))
            }
            switch model.state {
            case .writing(_, let text):
                StoryDivider()
                SectionLabel(ScreenText.shortStory(language))
                if !text.isEmpty {
                    StoryText(text: text)
                }
                step(ScreenText.writing(language))
            case .finding, .guess, .showing, .failed:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(listenEnabled: false, diaryStatus: false)
        }
    }

    private func step(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.unit) {
            ProgressView()
            Text(text)
                .font(Theme.Font.bodyMedium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Story

    private func story(_ session: StorySession) -> some View {
        let card = PlaceCard(session: session)
        // The model's screen-sized preview; the small thumbnail only while that is being decoded. Never the full
        // photo here: the body redraws up to ten times a second while "Mer" streams in.
        return StorySheetPage(photo: model.photoPreview ?? UIImage(data: session.thumbnailJPEG)) {
            placeHeader(card, confidence: session.identified.confidence, address: session.grounding.address)
            let badges = StoryBadges.badges(for: session)
            if !badges.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
                    ForEach(badges, id: \.self) { badge in
                        Label(badge, systemImage: "questionmark.circle")
                            .font(Theme.Font.caption)
                    }
                }
            }
            if model.morePlaces != nil {
                Button(ScreenText.morePlaces(language)) { model.retryWithMorePlaces() }
                    .buttonStyle(.themeSecondary)
            }
            StoryDivider()
            SectionLabel(ScreenText.shortStory(language))
            ForEach(Array(session.levels.enumerated()), id: \.offset) { index, text in
                if index == 0 {
                    StoryText(text: text, selectable: true)
                } else {
                    // Each deeper level gets its own label and Lytt; the bottom button reads the short story.
                    SectionLabel(ScreenText.moreLabel(index, language))
                        .padding(.top, Theme.Spacing.unit)
                    StoryText(text: text, selectable: true)
                    listenButton(level: index)
                }
            }
            if let moreText = model.moreText {
                SectionLabel(ScreenText.moreLabel(session.levels.count, language))
                    .padding(.top, Theme.Spacing.unit)
                StoryText(text: moreText)
            }
            moreAndSources(session, card: card)
            thenControls
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(listenEnabled: true, diaryStatus: true)
        }
    }

    /// "⊕ Mer om Pantheon" and "Kilder" side by side, as links rather than big buttons.
    private func moreAndSources(_ session: StorySession, card: PlaceCard) -> some View {
        let failure: String? = if case .failed(let message) = model.moreState { message } else { nil }
        let working = model.moreState == .working
        return MoreSourcesRow(
            language: language,
            moreTitle: session.nextLevel.map {
                ScreenText.more($0, name: card.mark == .identified ? card.name : nil, language)
            },
            working: working,
            failed: model.moreState != .idle && !working,
            failure: failure,
            onMore: { model.tellMore() },
            onSources: { showingSources = true })
    }

    /// The bottom: "Lytt til fortellingen" (the first level) in coral with dark text, then the diary status.
    private func bottomBar(listenEnabled: Bool, diaryStatus: Bool) -> some View {
        let state = model.speechState(for: 0)
        return ListenBar(
            language: language,
            isActive: state == .loading || state == .playing,
            isLoading: state == .loading,
            enabled: listenEnabled,
            failure: speechFailure(state),
            diaryStatus: diaryStatus ? (model.saveFailed ? .saveFailed : .saved) : nil,
            action: { model.toggleSpeech(level: 0) })
    }

    /// Lytt / Stopp for a deeper level.
    private func listenButton(level: Int) -> some View {
        let state = model.speechState(for: level)
        return LevelListenButton(
            language: language,
            isActive: state == .loading || state == .playing,
            isLoading: state == .loading,
            failure: speechFailure(state),
            action: { model.toggleSpeech(level: level) })
    }

    private func speechFailure(_ state: StoryViewModel.SpeechState) -> String? {
        guard case .failed(let message) = state else { return nil }
        return message ?? ScreenText.couldNotPlay(language)
    }

    @ViewBuilder
    private var thenControls: some View {
        switch model.thenState {
        case .showing:
            if let image = model.thenImage {
                // The label is part of the image view itself, so the image can never appear without it.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) {
                        Text(ThenImage.label)
                            .font(Theme.Font.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(.black.opacity(0.7))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCorner, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ThenImage.label)
            }
        case .idle, .working, .failed:
            let working = model.thenState == .working
            if case .failed(let message) = model.thenState {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
            Button {
                model.showThen()
            } label: {
                HStack(spacing: Theme.Spacing.unit + 4) {
                    if working {
                        ProgressView()
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 22, weight: .light))
                    }
                    Text(model.thenState == .idle || working ? ScreenText.showThen(language) : ScreenText.retry(language))
                        .font(Theme.Font.body)
                }
                .frame(minHeight: Theme.minimumTouchHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working)
        }
    }

    // MARK: - Failure

    private func failure(message: String, canUseCurrentPosition: Bool) -> some View {
        StorySheetPage(photo: model.photoPreview) {
            // The list's guess stays, still marked "Kanskje:" / "Maybe:"; nothing from the broken stream does.
            if let card = model.card { placeHeader(card, confidence: nil, address: nil) }
            Text(message)
                .font(Theme.Font.body)
            if canUseCurrentPosition {
                let fix = location.fix()
                Button(ScreenText.useWhereIAm(language)) {
                    guard let fix = location.fix() else { return }
                    model.useCurrentPosition(fix.coordinate, accuracy: fix.accuracy)
                }
                .buttonStyle(.themePrimary(.coral))
                .disabled(fix == nil)
                if fix == nil {
                    Text(ScreenText.waitingForGPS(language))
                        .font(Theme.Font.caption)
                }
            }
            Button(ScreenText.retry(language)) { model.retry() }
                .buttonStyle(.themeSecondary)
        }
    }
}
