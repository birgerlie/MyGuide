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

    /// How far the sheet reaches up over the photo, and its corner radius.
    private static let sheetOverlap: CGFloat = 24
    /// The photo's height as a share of its width (4:3 landscape crop).
    private static let heroAspect: CGFloat = 3.0 / 4.0

    var body: some View {
        content
            .foregroundStyle(Theme.Colour.text)
            .background(Theme.Colour.background.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSources) {
                if let session = model.session {
                    SourcesSheet(sources: StorySources.list(for: session), language: language)
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

    // MARK: - Layout

    /// The photo, then the sheet with `sheet` in it, over the photo's lower edge.
    private func page(photo image: UIImage?, @ViewBuilder sheet: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if let image {
                    hero(image)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                    sheet()
                }
                .padding(.horizontal, Theme.Spacing.wideMargin)
                .padding(.top, Theme.Spacing.wideMargin)
                .padding(.bottom, Theme.Spacing.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colour.background,
                            in: UnevenRoundedRectangle(topLeadingRadius: Self.sheetOverlap,
                                                       topTrailingRadius: Self.sheetOverlap, style: .continuous))
                .padding(.top, image == nil ? 0 : -Self.sheetOverlap)
            }
        }
    }

    /// Edge to edge, cropped to 4:3 so a tall or dark photo never pushes the story off the screen.
    private func hero(_ image: UIImage) -> some View {
        Color.clear
            .aspectRatio(1 / Self.heroAspect, contentMode: .fit)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .accessibilityHidden(true)
    }

    /// "STED FUNNET", "KORT FORTELLING": small spaced capitals.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
            .tracking(1.6)
            .opacity(0.75)
            .accessibilityAddTraits(.isHeader)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colour.stone)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - Place header

    /// The status label, the name in Playfair and the line with where it is. "Unsure" shows the not-sure sentence in
    /// place of a name, so an uncertain identification never looks like a found place (design guidelines).
    @ViewBuilder
    private func placeHeader(_ card: PlaceCard, confidence: SubjectConfidence?, address: Address?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            switch card.mark {
            case .unsure:
                sectionLabel(ScreenText.unsureLabel(language))
                Text(ScreenText.notSure(language))
                    .font(Theme.Font.title)
            case .guess, .identified:
                sectionLabel(ScreenText.statusLabel(card.mark, confidence: confidence, language))
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
        page(photo: model.photoPreview) {
            if let card = model.card {
                placeHeader(card, confidence: nil, address: nil)
            } else {
                step(ScreenText.finding(language))
            }
            switch model.state {
            case .writing(_, let text):
                divider
                sectionLabel(ScreenText.shortStory(language))
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
        return page(photo: model.photoPreview ?? UIImage(data: session.thumbnailJPEG)) {
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
            divider
            sectionLabel(ScreenText.shortStory(language))
            ForEach(Array(session.levels.enumerated()), id: \.offset) { index, text in
                if index == 0 {
                    StoryText(text: text, selectable: true)
                } else {
                    // Each deeper level gets its own label and Lytt; the bottom button reads the short story.
                    sectionLabel(ScreenText.moreLabel(index, language))
                        .padding(.top, Theme.Spacing.unit)
                    StoryText(text: text, selectable: true)
                    listenButton(level: index)
                }
            }
            if let moreText = model.moreText {
                sectionLabel(ScreenText.moreLabel(session.levels.count, language))
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
    @ViewBuilder
    private func moreAndSources(_ session: StorySession, card: PlaceCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            if case .failed(let message) = model.moreState {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: Theme.Spacing.margin) {
                if let next = session.nextLevel {
                    let working = model.moreState == .working
                    let failed = model.moreState != .idle && !working
                    Button {
                        model.tellMore()
                    } label: {
                        HStack(spacing: Theme.Spacing.unit + 4) {
                            if working {
                                ProgressView()
                            } else {
                                Image(systemName: failed ? "arrow.clockwise.circle" : "plus.circle")
                                    .font(.system(size: 28, weight: .light))
                            }
                            Text(failed ? ScreenText.retry(language)
                                 : ScreenText.more(next, name: card.mark == .identified ? card.name : nil, language))
                                .font(Theme.Font.body)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(minHeight: Theme.minimumTouchHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(Theme.Colour.stone)
                        .frame(width: 1, height: 32)
                        .accessibilityHidden(true)
                }
                Button {
                    showingSources = true
                } label: {
                    HStack(spacing: Theme.Spacing.unit) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 22, weight: .light))
                        Text(ScreenText.sources(language))
                            .font(Theme.Font.body)
                            .underline()
                    }
                    .frame(minHeight: Theme.minimumTouchHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .frame(maxWidth: session.nextLevel == nil ? .infinity : nil, alignment: .leading)
            }
            divider
        }
        .padding(.top, Theme.Spacing.unit)
    }

    /// The bottom: "Lytt til fortellingen" (the first level) in coral with dark text, then the diary status.
    private func bottomBar(listenEnabled: Bool, diaryStatus: Bool) -> some View {
        let state = model.speechState(for: 0)
        let active = state == .loading || state == .playing
        return VStack(spacing: Theme.Spacing.unit) {
            Button {
                model.toggleSpeech(level: 0)
            } label: {
                HStack(spacing: Theme.Spacing.unit + 4) {
                    if state == .loading {
                        ProgressView().tint(Theme.Colour.forest)
                    } else {
                        Image(systemName: active ? "stop.fill" : "play.fill")
                    }
                    Text(active ? ScreenText.stop(language) : ScreenText.listenToStory(language))
                }
                // Forest on coral is 4.26:1: under the 4.5:1 for normal text. Inter Medium (weight 500) at 19 pt is not
                // "large text" (14 pt at weight 700, or 24 pt), so this is the design package's colours, kept by the
                // owner's call, not a pass.
                .font(.custom(Theme.FontName.medium, size: 19, relativeTo: .body))
                .foregroundStyle(Theme.Colour.forest)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.Colour.coral, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!listenEnabled)
            .opacity(listenEnabled ? 1 : 0.5)
            if case .failed(let message) = state {
                Text(message ?? ScreenText.couldNotPlay(language))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if diaryStatus {
                if model.saveFailed {
                    Label(ScreenText.saveFailed(language), systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                } else {
                    Label(ScreenText.savedInDiary(language), systemImage: "book")
                        .font(Theme.Font.body)
                        .opacity(0.75)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.top, Theme.Spacing.unit)
        .padding(.bottom, Theme.Spacing.unit)
        .background(Theme.Colour.background)
    }

    /// Lytt / Stopp for a deeper level. Coral marks active audio (design package), always with forest-green text on it.
    @ViewBuilder
    private func listenButton(level: Int) -> some View {
        let state = model.speechState(for: level)
        let active = state == .loading || state == .playing
        VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
            Button {
                model.toggleSpeech(level: level)
            } label: {
                HStack(spacing: 6) {
                    if state == .loading {
                        ProgressView().tint(Theme.Colour.forest)
                    } else {
                        Image(systemName: active ? "stop.fill" : "play.fill")
                    }
                    Text(active ? ScreenText.stop(language) : ScreenText.listen(language))
                }
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Colour.forest)
                .padding(.horizontal, Theme.Spacing.margin)
                .frame(minWidth: Theme.minimumTouchHeight, minHeight: Theme.minimumTouchHeight)
                .background(Theme.Colour.coral, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if case .failed(let message) = state {
                Text(message ?? ScreenText.couldNotPlay(language))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
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
        page(photo: model.photoPreview) {
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
                .buttonStyle(.themePrimary())
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

/// «Kilder»: the sources behind the story, with links where there is one, and a plain note that the text is written
/// by an AI model and can be wrong.
private struct SourcesSheet: View {
    let sources: [StorySource]
    let language: StoryLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sources.isEmpty {
                        Text(ScreenText.noPlaceSources(language))
                    }
                    ForEach(sources) { source in
                        if let url = source.url {
                            Link(destination: url) { row(source, link: true) }
                        } else {
                            row(source, link: false)
                        }
                    }
                } footer: {
                    Text(ScreenText.aiNote(language))
                }
            }
            .navigationTitle(ScreenText.sources(language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ScreenText.done(language)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ source: StorySource, link: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScreenText.sourceName(source.kind, language))
                    .font(Theme.Font.bodyMedium)
                if let detail = source.detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                }
            }
            Spacer()
            if link {
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.Colour.text)
    }
}
