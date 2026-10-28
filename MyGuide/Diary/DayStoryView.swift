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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) { controls }
        .overlay {
            if model.isWriting || model.isRendering {
                ProgressView(model.isWriting ? DayStoryModel.writingText : DayStoryModel.renderingText)
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .environment(\.colorScheme, .dark)
            } else if !model.loaded {
                ProgressView().tint(.white)
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
        .alert(model.alert?.title ?? "", isPresented: alertPresented, presenting: model.alert) { alert in
            switch alert {
            case .confirmRewrite:
                Button("Write again") { model.write() }
                Button("Cancel", role: .cancel) {}
            case .error:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
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
            ContentUnavailableView {
                Label("This day story couldn't be opened.", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Write again") { model.requestRewrite() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.loaded, !model.isWriting {
            // The first write failed (its alert said why) or could not start.
            ContentUnavailableView {
                Label("No day story yet.", systemImage: "book.pages")
            } actions: {
                Button("Write day story") { model.write() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Pages draw edge to edge; the reader passes them the insets that keep their text clear of the screen edges,
    /// the controls and the page dots.
    private func pager(_ pages: DayStoryPages) -> some View {
        GeometryReader { proxy in
            TabView(selection: $selection) {
                DayStoryPageSlot(model: model, imageID: pages.photos.first?.id,
                                 content: .summary(header: model.header, summary: pages.summary,
                                                   note: pages.countNote),
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
        HStack(spacing: 12) {
            if model.pages != nil {
                controlButton("Share", systemImage: "square.and.arrow.up") { model.share() }
                    .disabled(model.busy)
                controlButton("Write again", systemImage: "arrow.clockwise") { model.requestRewrite() }
                    .disabled(model.busy)
            }
            // Always available: going back stops a running write or share.
            controlButton("Close", systemImage: "xmark") { dismiss() }
        }
        .padding()
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
        }
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
                        .font(.title2.weight(.bold))
                }
                if let city = header.city, !city.isEmpty {
                    Text(city).font(.headline).opacity(0.85)
                }
                Text(summary)
                    .font(.title3)
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note).font(.footnote).opacity(0.8)
                }
            }
            .modifier(OnGradient(insets: insets, midpoint: 0.25))
        case .photo(_, let caption):
            if let caption {
                Text(caption)
                    .font(.body)
                    .minimumScaleFactor(0.7)
                    .modifier(OnGradient(insets: insets, midpoint: 0.5))
            }
        }
    }

    @ViewBuilder
    private var corner: some View {
        if case .photo(let time, _) = content {
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, insets.top + 16)
                .padding(.leading, insets.leading + 16)
        }
    }
}

/// White text, full width, on a gradient that darkens towards the bottom of the page.
private struct OnGradient: ViewModifier {
    let insets: EdgeInsets
    /// Where the gradient reaches its middle darkness, from 0 (top of the text block and its padding) to 1 (bottom).
    let midpoint: Double

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
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
    var title: String {
        switch self {
        case .confirmRewrite: "Write the day story again?"
        case .error: "Couldn't complete that"
        }
    }

    var message: String {
        switch self {
        case .confirmRewrite: "The new story replaces this one."
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
