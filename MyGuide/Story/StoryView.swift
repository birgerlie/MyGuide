import MyGuideCore
import SwiftUI
import UIKit

/// One photo's story. While it is found and written: the photo, the step in words ("Finner stedet …", then the likely
/// place, then "Skriver fortellingen …" and the text as it streams in). Then the place card with Lytt, the title, the
/// badges and every level; or the error with Retry. Typography and colours come from `Theme`.
struct StoryView: View {
    let model: StoryViewModel
    let location: LocationProvider

    var body: some View {
        content
            .foregroundStyle(Theme.Colour.text)
            .background(Theme.Colour.background.ignoresSafeArea())
            .navigationTitle("Story")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if model.saveFailed {
                    Text("Couldn't save to memory")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, Theme.Spacing.unit)
                }
            }
    }

    private var language: StoryLanguage { model.language }

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

    // MARK: - While working

    /// Each step replaces the one before, and every spinner has words next to it.
    private var progress: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                if let preview = model.photoPreview {
                    photo(preview)
                }
                if let card = model.card {
                    placeCard(card, canListen: false)
                }
                switch model.state {
                case .finding:
                    step(ScreenText.finding(language))
                case .guess:
                    // The guess card replaces "Finding the place …".
                    EmptyView()
                case .writing(_, let text):
                    if text.isEmpty {
                        step(ScreenText.writing(language))
                    } else {
                        Text(text)
                            .font(Theme.Font.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        step(ScreenText.writing(language))
                    }
                case .showing, .failed:
                    EmptyView()
                }
            }
            .padding(.horizontal, Theme.Spacing.margin)
            .padding(.vertical, Theme.Spacing.margin)
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

    private func photo(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCorner, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: - Place card

    /// Name, distance and direction, with Lytt for the first level (disabled until the story exists; `canListen` nil
    /// leaves it out). A guess carries "Kanskje:" / "Maybe:"; "unsure" shows the not-sure sentence instead of a place.
    private func placeCard(_ card: PlaceCard, canListen: Bool?) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.margin) {
            VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
                switch card.mark {
                case .guess:
                    Text(ScreenText.maybe(card, language))
                        .font(Theme.Font.bodyMedium)
                case .identified:
                    Text(card.name)
                        .font(Theme.Font.title)
                    if let where_ = ScreenText.distanceAndDirection(card, language) {
                        Text(where_)
                            .font(Theme.Font.caption)
                    }
                case .unsure:
                    Text(ScreenText.notSure(language))
                        .font(Theme.Font.bodyMedium)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let canListen { listenButton(level: 0, enabled: canListen) }
        }
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.stone.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: Theme.buttonCorner, style: .continuous))
    }

    /// Lytt / Stop for one level. Coral marks active audio (design package), always with forest-green text on it.
    @ViewBuilder
    private func listenButton(level: Int, enabled: Bool = true) -> some View {
        let state = model.speechState(for: level)
        let active = state == .loading || state == .playing
        VStack(spacing: Theme.Spacing.unit / 2) {
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
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            if case .failed(let message) = state {
                Text(message ?? "Couldn't play audio")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Story

    private func story(_ session: StorySession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                if let image = UIImage(data: session.thumbnailJPEG) {
                    photo(image)
                }
                placeCard(PlaceCard(session: session), canListen: true)
                if model.morePlaces != nil {
                    Button(ScreenText.morePlaces(language)) { model.retryWithMorePlaces() }
                    .buttonStyle(.themeSecondary)
                }
                Text(session.identified.title)
                    .font(Theme.Font.title)
                ForEach(StoryBadges.badges(for: session), id: \.self) { badge in
                    Label(badge, systemImage: "questionmark.circle")
                        .font(Theme.Font.caption)
                }
                ForEach(Array(session.levels.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
                        Text(text)
                            .font(Theme.Font.body)
                            .textSelection(.enabled)
                        // The first level's Lytt is on the card.
                        if index > 0 { listenButton(level: index) }
                    }
                }
                if let moreText = model.moreText {
                    Text(moreText)
                        .font(Theme.Font.body)
                }
                moreControls(session)
                thenControls
            }
            .padding(Theme.Spacing.margin)
        }
    }

    @ViewBuilder
    private func moreControls(_ session: StorySession) -> some View {
        if let next = session.nextLevel {
            if case .failed(let message) = model.moreState {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
            let working = model.moreState == .working
            Button {
                model.tellMore()
            } label: {
                HStack(spacing: Theme.Spacing.unit) {
                    if working { ProgressView().tint(Theme.Colour.onPrimaryFill) }
                    Text(buttonTitle(for: next, failed: model.moreState != .idle && !working))
                }
            }
            .buttonStyle(.themePrimary())
            .disabled(working)
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
                HStack(spacing: Theme.Spacing.unit) {
                    if working { ProgressView().tint(Theme.Colour.forest) }
                    Text(model.thenState == .idle || working ? "Show me how it looked" : "Retry")
                }
            }
            .buttonStyle(.themeSecondary)
            .disabled(working)
        }
    }

    private func buttonTitle(for level: StoryLevel, failed: Bool) -> String {
        if failed { return "Retry" }
        return level == .more ? "Tell me more" : "Even more"
    }

    // MARK: - Failure

    private func failure(message: String, canUseCurrentPosition: Bool) -> some View {
        VStack(spacing: Theme.Spacing.margin) {
            // The list's guess stays, still marked "Kanskje:" / "Maybe:"; nothing from the broken stream does.
            if let card = model.card { placeCard(card, canListen: nil) }
            Text(message)
                .font(Theme.Font.body)
                .multilineTextAlignment(.center)
            if canUseCurrentPosition {
                let fix = location.fix()
                Button("Use where I am now") {
                    guard let fix = location.fix() else { return }
                    model.useCurrentPosition(fix.coordinate, accuracy: fix.accuracy)
                }
                .buttonStyle(.themePrimary())
                .disabled(fix == nil)
                if fix == nil {
                    Text("Waiting for a GPS fix…")
                        .font(Theme.Font.caption)
                }
            }
            Button("Retry") { model.retry() }
                .buttonStyle(.themeSecondary)
        }
        .padding(Theme.Spacing.wideMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
