import MyGuideCore
import SwiftUI
import UIKit

/// The day's story, full screen (spec 5.4): the summary over the first photo, then one page per photo still kept.
/// A stored story shows at once; with none, one is written while a progress view shows. Close, Share and Write
/// again sit at the top; nothing that would start a second write or share works while one runs. The model belongs to
/// `DiaryWork`: a screen pushed on top leaves a running write going, and going back from this screen stops it.
struct DayStoryScreen: View {
    let model: DayStoryModel

    @State private var selection = 0
    /// False while another screen covers this one: its alert and share sheet wait until it is back on top.
    @State private var visible = false
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Photos fill the pages on black; the screens without pages sit on the theme's dark background.
            (model.pages == nil ? Theme.Colour.forest : Color.black).ignoresSafeArea()
            content
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) { controls }
        .overlay {
            if model.isWriting || model.isRendering {
                ProgressView {
                    Text(model.isWriting ? DiaryTexts.writing(storyLanguage) : DiaryTexts.rendering(storyLanguage))
                        .font(Theme.Font.body)
                }
                .tint(Theme.Colour.ivory)
                .foregroundStyle(Theme.Colour.ivory)
                .padding(Theme.Spacing.margin)
                .background(Theme.Colour.forest.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .environment(\.colorScheme, .dark)
            } else if !model.loaded {
                ProgressView().tint(Theme.Colour.ivory)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .onAppear {
            visible = true
            model.open()
        }
        .onDisappear { visible = false }
        .onChange(of: model.pages) { selection = 0 }
        .alert(model.alert?.title(storyLanguage) ?? "", isPresented: alertPresented, presenting: model.alert) { alert in
            switch alert {
            case .confirmRewrite:
                Button(DiaryTexts.writeAgain(storyLanguage)) { model.write() }
                Button(DiaryTexts.cancel(storyLanguage), role: .cancel) {}
            case .error:
                Button(DiaryTexts.ok(storyLanguage), role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message(storyLanguage))
        }
        .sheet(item: shareSet) { set in
            ActivityView(items: set.images) { model.shareSet = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pages = model.pages {
            pager(pages)
        } else if model.unreadable, !model.isWriting {
            emptyState(DiaryTexts.dayStoryUnreadable(storyLanguage), systemImage: "exclamationmark.triangle",
                       action: DiaryTexts.writeAgain(storyLanguage)) { model.requestRewrite() }
        } else if model.loaded, !model.isWriting {
            // The first write failed (its alert said why) or could not start.
            emptyState(DiaryTexts.noDayStory(storyLanguage), systemImage: "book.pages",
                       action: DiaryTexts.writeDayStory(storyLanguage)) { model.write() }
        }
    }

    /// No pages: what is wrong in Playfair on forest green, and the one way on as the primary button (ivory in the
    /// dark appearance, with forest text).
    private func emptyState(_ title: String, systemImage: String, action: String,
                            perform: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label {
                Text(title).font(Theme.Font.title)
            } icon: {
                Image(systemName: systemImage)
            }
        } actions: {
            Button(action, action: perform)
                .buttonStyle(.themePrimary())
                .fixedSize()
        }
        .foregroundStyle(Theme.Colour.ivory)
        .padding(.horizontal, Theme.Spacing.wideMargin)
    }

    /// Pages draw edge to edge; the reader passes them the insets that keep their text clear of the screen edges,
    /// the controls and the page dots.
    private func pager(_ pages: DayStoryPages) -> some View {
        GeometryReader { proxy in
            TabView(selection: $selection) {
                DayStoryPageSlot(model: model, imageID: pages.photos.first?.id,
                                 content: .summary(header: model.header, summary: pages.summary,
                                                   note: model.summaryNote(pages)),
                                 insets: proxy.safeAreaInsets)
                    .tag(0)
                ForEach(Array(pages.photos.enumerated()), id: \.element.id) { index, photo in
                    DayStoryPageSlot(model: model, imageID: photo.id,
                                     content: .photo(time: photo.time, caption: photo.caption),
                                     insets: proxy.safeAreaInsets)
                        .tag(index + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.unit + 4) {
            if model.pages != nil {
                controlButton(DiaryTexts.share(storyLanguage), systemImage: "square.and.arrow.up") { model.share() }
                    .disabled(model.busy)
                controlButton(DiaryTexts.writeAgain(storyLanguage), systemImage: "arrow.clockwise") {
                    model.requestRewrite()
                }
                .disabled(model.busy)
            }
            // Always available: going back stops a running write or share.
            controlButton(DiaryTexts.close(storyLanguage), systemImage: "xmark") { dismiss() }
        }
        .padding(Theme.Spacing.margin)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Colour.forest)
                .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                .background(Theme.Colour.ivory, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Bindings

    private var alertPresented: Binding<Bool> {
        Binding(get: { visible && model.alert != nil }, set: { if !$0, visible { model.alert = nil } })
    }

    private var shareSet: Binding<DayStoryModel.ShareSet?> {
        Binding(get: { visible ? model.shareSet : nil }, set: { if visible { model.shareSet = $0 } })
    }
}

/// A page in the pager: loads its photo when it comes into view, and drops it when the page's photo changes or goes
/// (the summary page shows the first photo, which a rewrite or a deletion can change).
private struct DayStoryPageSlot: View {
    let model: DayStoryModel
    let imageID: String?
    let content: DayStoryPageView.Content
    let insets: EdgeInsets

    @State private var image: UIImage?
    /// The photo `image` was loaded for.
    @State private var imageFor: String?

    var body: some View {
        // Clear of the page dots (about 26 pt) and the controls row (44 pt plus padding).
        DayStoryPageView(content: content, image: image,
                         insets: EdgeInsets(top: insets.top + 60, leading: insets.leading,
                                            bottom: insets.bottom + 36, trailing: insets.trailing))
            .ignoresSafeArea()
            .task(id: imageID) {
                // Coming back into view with its photo already shown: nothing to do.
                if imageFor == imageID, image != nil { return }
                image = nil
                imageFor = imageID
                guard let imageID else { return }
                let loaded = await model.displayImage(id: imageID)
                // Superseded by a newer photo or gone from view: a late result must not overwrite the newer one.
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// One page, drawn the same in the pager and for sharing: the photo filling the page on black, then either the day
/// and its summary, or the photo's caption on a dark gradient with its time in the corner. No materials or
/// animations, so `ImageRenderer` draws it as seen.
struct DayStoryPageView: View {
    struct Header: Equatable {
        var date: Date?
        var city: String?
    }

    enum Content {
        case summary(header: Header, summary: String, note: String?)
        case photo(time: Date, caption: String?)
    }

    let content: Content
    let image: UIImage?
    /// Space kept clear at the edges, beyond the page's own margins.
    var insets = EdgeInsets()

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { bottom }
            .overlay(alignment: .topLeading) { corner }
            // An overlong summary at a large text size must not spill past the page.
            .clipped()
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var bottom: some View {
        switch content {
        case .summary(let header, let summary, let note):
            VStack(alignment: .leading, spacing: 10) {
                if let date = header.date {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(Theme.Font.title)
                }
                if let city = header.city, !city.isEmpty {
                    Text(city).font(Theme.Font.bodyMedium).opacity(0.85)
                }
                Text(summary)
                    .font(.custom(Theme.FontName.regular, size: 20, relativeTo: .title3))
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note).font(Theme.Font.caption).opacity(0.8)
                }
            }
            .modifier(OnGradient(insets: insets, midpoint: 0.25))
        case .photo(_, let caption):
            if let caption {
                Text(caption)
                    .font(Theme.Font.body)
                    .minimumScaleFactor(0.7)
                    .modifier(OnGradient(insets: insets, midpoint: 0.5))
            }
        }
    }

    @ViewBuilder
    private var corner: some View {
        if case .photo(let time, _) = content {
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.custom(Theme.FontName.medium, size: 15, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(Theme.Colour.forest)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.Colour.ivory, in: Capsule())
                .padding(.top, insets.top + 16)
                .padding(.leading, insets.leading + 16)
        }
    }
}

/// Ivory text, full width, on a gradient that darkens towards the bottom of the page.
private struct OnGradient: ViewModifier {
    let insets: EdgeInsets
    /// Where the gradient reaches its middle darkness, from 0 (top of the text block and its padding) to 1 (bottom).
    let midpoint: Double

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.Colour.ivory)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .padding(.top, 80)
            .padding(.bottom, insets.bottom + 24)
            .background {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black.opacity(0.55), location: midpoint),
                                       .init(color: .black.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
    }
}

private extension DayStoryModel.Alert {
    func title(_ language: StoryLanguage) -> String {
        switch self {
        case .confirmRewrite: DiaryTexts.confirmRewriteTitle(language)
        case .error: DiaryTexts.failedTitle(language)
        }
    }

    func message(_ language: StoryLanguage) -> String {
        switch self {
        case .confirmRewrite: DiaryTexts.confirmRewriteMessage(language)
        case .error(let text): text
        }
    }
}

/// The system share sheet for the rendered pages. `onDone` runs when it finishes, shared or not, so the sheet that
/// hosts it can close.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [UIImage]
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDone() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
