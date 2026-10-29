import MyGuideCore
import SwiftUI
import UIKit

// The story screens' shared parts (the photo story and the walk story): the photo with the ivory sheet over its lower
// edge, the spaced-capital section labels, the stone divider, "Mer om …" with "Kilder", the Lytt buttons and the
// sources sheet.

/// The photo across the top, then the sheet with `sheet` in it, over the photo's lower edge. Without a photo the sheet
/// starts at the top. `photoCredit` is the photo's credit, as a caption at the top of the sheet, right under the photo.
struct StorySheetPage<Sheet: View>: View {
    let photo: UIImage?
    var photoCredit: String?
    @ViewBuilder let sheet: () -> Sheet

    /// How far the sheet reaches up over the photo, and its corner radius.
    static var sheetOverlap: CGFloat { 24 }
    /// The photo's height as a share of its width (4:3 landscape crop).
    static var heroAspect: CGFloat { 3.0 / 4.0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let photo {
                    hero(photo)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                    if photo != nil, let photoCredit {
                        Text(photoCredit)
                            .font(Theme.Font.caption)
                            .opacity(0.75)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                    }
                    sheet()
                }
                .padding(.horizontal, Theme.Spacing.wideMargin)
                .padding(.top, Theme.Spacing.wideMargin)
                .padding(.bottom, Theme.Spacing.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colour.background,
                            in: UnevenRoundedRectangle(topLeadingRadius: Self.sheetOverlap,
                                                       topTrailingRadius: Self.sheetOverlap, style: .continuous))
                .padding(.top, photo == nil ? 0 : -Self.sheetOverlap)
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
}

/// "STED FUNNET", "KORT FORTELLING": small spaced capitals.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
            .tracking(1.6)
            .opacity(0.75)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A one-point stone line between the sheet's parts.
struct StoryDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colour.stone)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// "⊕ Mer om Pantheon" and "Kilder" side by side, as links rather than big buttons, with a divider under them.
/// `moreTitle` nil leaves "Mer" out (no next level). `failed` turns "Mer" into "Prøv igjen"; `failure` is shown in red
/// over the row.
struct MoreSourcesRow: View {
    let language: StoryLanguage
    let moreTitle: String?
    var working = false
    var failed = false
    var failure: String?
    let onMore: () -> Void
    let onSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
            if let failure {
                Text(failure)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: Theme.Spacing.margin) {
                if let moreTitle {
                    Button(action: onMore) {
                        HStack(spacing: Theme.Spacing.unit + 4) {
                            if working {
                                ProgressView()
                            } else {
                                Image(systemName: failed ? "arrow.clockwise.circle" : "plus.circle")
                                    .font(.system(size: 28, weight: .light))
                            }
                            Text(failed ? ScreenText.retry(language) : moreTitle)
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
                Button(action: onSources) {
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
                .frame(maxWidth: moreTitle == nil ? .infinity : nil, alignment: .leading)
            }
            StoryDivider()
        }
        .padding(.top, Theme.Spacing.unit)
    }
}

/// The bottom: "Lytt til fortellingen" (the first level) in coral with dark text, then a failure in red and the diary
/// status. `isActive` is loading or playing (the button then says "Stopp"); `isLoading` shows a spinner in place of
/// the symbol.
struct ListenBar: View {
    enum DiaryStatus { case saved, saveFailed }

    let language: StoryLanguage
    var isActive = false
    var isLoading = false
    var enabled = true
    var failure: String?
    var diaryStatus: DiaryStatus?
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.unit) {
            Button(action: action) {
                HStack(spacing: Theme.Spacing.unit + 4) {
                    if isLoading {
                        ProgressView().tint(Theme.Colour.forest)
                    } else {
                        Image(systemName: isActive ? "stop.fill" : "play.fill")
                    }
                    Text(isActive ? ScreenText.stop(language) : ScreenText.listenToStory(language))
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
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            if let failure {
                Text(failure)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            switch diaryStatus {
            case .saved:
                Label(ScreenText.savedInDiary(language), systemImage: "book")
                    .font(Theme.Font.body)
                    .opacity(0.75)
            case .saveFailed:
                Label(ScreenText.saveFailed(language), systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.top, Theme.Spacing.unit)
        .padding(.bottom, Theme.Spacing.unit)
        .background(Theme.Colour.background)
    }
}

/// Lytt / Stopp for a deeper level. Coral marks active audio (design package), always with forest-green text on it.
struct LevelListenButton: View {
    let language: StoryLanguage
    var isActive = false
    var isLoading = false
    var enabled = true
    var failure: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.unit / 2) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().tint(Theme.Colour.forest)
                    } else {
                        Image(systemName: isActive ? "stop.fill" : "play.fill")
                    }
                    Text(isActive ? ScreenText.stop(language) : ScreenText.listen(language))
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
            if let failure {
                Text(failure)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// «Kilder»: the sources behind the story, with links where there is one, and a plain note that the text is written
/// by an AI model and can be wrong. `emptyText` stands in for an empty list; `note` is the AI note under the list.
struct SourcesSheet: View {
    let sources: [StorySource]
    let language: StoryLanguage
    let emptyText: String
    let note: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sources.isEmpty {
                        Text(emptyText)
                    }
                    ForEach(sources) { source in
                        if let url = source.url {
                            Link(destination: url) { row(source, link: true) }
                        } else {
                            row(source, link: false)
                        }
                    }
                } footer: {
                    Text(note)
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
