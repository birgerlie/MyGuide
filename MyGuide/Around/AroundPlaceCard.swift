import CoreLocation
import MyGuideCore
import SwiftUI
import UIKit

/// What the card shows (spec 6.5, 16.6): the selected place, or the reason there is none, in words. Never an old
/// place.
enum AroundCardState: Equatable {
    case locationDenied
    /// No usable fix yet.
    case locating
    /// A fix, but no list in the story language yet.
    case loading
    case noPlaces
    /// A fix too inaccurate to select from (spec 6.4).
    case uncertainPosition
    case selected(SelectedPlace)

    /// Denied access wins; a selection is shown whenever there is one. Without one: no fix reads as locating, no
    /// list as loading, then the selector's reason.
    @MainActor
    static func of(_ model: AroundModel, authorization: CLAuthorizationStatus) -> AroundCardState {
        if authorization == .denied || authorization == .restricted { return .locationDenied }
        switch model.selection {
        case .selected(let selected):
            return .selected(selected)
        case .noPlaces, .uncertainPosition:
            if model.position == nil { return .locating }
            if model.loading { return .loading }
            return model.selection == .noPlaces ? .noPlaces : .uncertainPosition
        }
    }
}

/// The compact place card in the sheet (spec 6.5, 14): the picture on the left (or the kind's symbol on stone), the
/// name in Playfair, the arrow and "50 m · foran til høyre", «Ta et bilde» when only a photo can tell places apart,
/// and a round coral «Lytt» with the word under it, which becomes a spinner and «Stopp» while this place plays.
/// A tap on the picture or the text opens the place's story.
struct AroundPlaceCard: View {
    let selected: SelectedPlace
    let stories: WalkingStories
    let placeImages: PlaceImages
    let language: StoryLanguage
    let listen: () -> Void
    let open: () -> Void
    let takePhoto: () -> Void

    @State private var picture: UIImage?

    private static let pictureSize: CGFloat = 64
    private static let listenSize: CGFloat = 56

    private var candidate: Candidate { selected.vector.place.candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: Theme.Spacing.margin) {
                Button(action: open) {
                    HStack(alignment: .center, spacing: Theme.Spacing.margin) {
                        pictureView
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.name)
                                .font(Theme.Font.title)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .multilineTextAlignment(.leading)
                            whereLine
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(AroundTexts.openStoryHint(language))
                listenButton
            }
            if selected.suggestPhoto {
                AroundTakePhotoLink(language: language, action: takePhoto)
            }
        }
        .foregroundStyle(Theme.Colour.text)
        .padding(12)
        .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
        // On demand, once per place (spec 12.6): from the cache when it is there, else fetched.
        .task(id: candidate.id) { await loadPicture() }
    }

    @ViewBuilder
    private var pictureView: some View {
        if let picture {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: Self.pictureSize, height: Self.pictureSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
        } else {
            PlaceSymbolTile(symbol: PlaceSymbol.systemName(for: candidate), size: Self.pictureSize)
        }
    }

    /// The arrow only when a direction may be stated (spec 6.4); the line says "i nærheten" otherwise.
    private var whereLine: some View {
        HStack(spacing: 6) {
            if let relative = selected.relative {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(relative))
                    .accessibilityHidden(true)
            }
            Text(AroundText.whereLine(distance: selected.vector.distance, relative: selected.relative,
                                      language: language))
                .font(Theme.Font.body)
                .lineLimit(2)
        }
        .opacity(0.85)
    }

    /// While this place plays or loads, a tap stops it (`stopListening`); otherwise it tells the place.
    private var listenButton: some View {
        let isActive = stories.playingPlaceID == candidate.id
        let isLoading = isActive && (stories.listening?.isLoading ?? (stories.playback.playing == nil))
        let word = isActive ? AroundTexts.stop(language) : AroundTexts.listen(language)
        return Button {
            if isActive { stories.stopListening() } else { listen() }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Theme.Colour.coral)
                    if isLoading {
                        ProgressView().tint(Theme.Colour.forest)
                    } else {
                        Image(systemName: isActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Colour.forest)
                    }
                }
                .frame(width: Self.listenSize, height: Self.listenSize)
                Text(word)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Colour.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word)
    }

    private func loadPicture() async {
        picture = nil
        guard let title = PlaceImages.title(for: candidate),
              let stored = await placeImages.image(wikipediaTitle: title), !Task.isCancelled else { return }
        let url = stored.fileURL
        let loaded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
        guard !Task.isCancelled else { return }
        picture = loaded
    }
}

/// The card's other states, in words with a symbol (never colour alone), and the action each offers.
struct AroundCardStateView: View {
    let state: AroundCardState
    let language: StoryLanguage
    let takePhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit * 1.5) {
            HStack(spacing: 12) {
                symbol
                    .frame(width: 28)
                Text(text)
                    .font(Theme.Font.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            switch state {
            case .locationDenied:
                Button(AroundTexts.openSettings(language)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.themeSecondary)
            case .uncertainPosition:
                AroundTakePhotoLink(language: language, action: takePhoto)
            default:
                EmptyView()
            }
        }
        .foregroundStyle(Theme.Colour.text)
        .padding(Theme.Spacing.margin)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .locating, .loading:
            ProgressView().tint(Theme.Colour.text)
        case .locationDenied:
            Image(systemName: "location.slash").accessibilityHidden(true)
        case .noPlaces:
            Image(systemName: "mappin.slash").accessibilityHidden(true)
        case .uncertainPosition:
            Image(systemName: "location.magnifyingglass").accessibilityHidden(true)
        case .selected:
            EmptyView()
        }
    }

    private var text: String {
        switch state {
        case .locationDenied: AroundTexts.locationDenied(language)
        case .locating: AroundTexts.locating(language)
        case .loading: AroundTexts.loading(language)
        case .noPlaces: AroundTexts.noPlaces(language)
        case .uncertainPosition: AroundTexts.uncertainPosition(language)
        case .selected: ""
        }
    }
}

/// «Ta et bilde» as a quiet link with the camera symbol; it opens the camera.
struct AroundTakePhotoLink: View {
    let language: StoryLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(AroundTexts.takePhoto(language), systemImage: "camera")
                .font(Theme.Font.bodyMedium)
                .underline()
                .foregroundStyle(Theme.Colour.text)
                .frame(minHeight: Theme.minimumTouchHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
