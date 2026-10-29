import MyGuideCore
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Everything kept, by local day, newest day first and each day oldest first (spec 4). Photo stories open their
/// stored story, walk stories their walk story screen and library photos full screen. Only library photos are
/// deleted here; other stories are deleted in History.
struct DiaryView: View {
    let services: AppServices
    let location: LocationProvider
    /// Pushes the walk story screen onto Home's stack.
    let openWalkStory: (UUID) -> Void
    /// Pushes the day story screen onto Home's stack.
    let openDayStory: (DiaryDay) -> Void

    @State private var days: [DiaryDay] = []
    /// Photo id to caption, from the stored day stories of the days shown.
    @State private var captions: [String: String] = [:]
    @State private var loaded = false
    @State private var story: StoryViewModel?
    @State private var fullScreenPhoto: FullScreenPhoto?
    @State private var pickerItems: [PhotosPickerItem] = []
    /// False while another screen covers the diary. The import (owned by `DiaryWork`) runs on meanwhile; its
    /// summary waits until the diary is back on top.
    @State private var visible = false
    /// The screen's one alert, so an error and an import summary never compete.
    @State private var alert: DiaryAlert?
    /// The screen texts follow the iPhone's language (spec 17).
    private var screenLanguage: StoryLanguage { UILanguage.current }

    var body: some View {
        VStack(spacing: 0) {
            if let fallback = services.memoryFallback { MemoryUnavailableNotice(fallback: fallback) }
            content
        }
        .foregroundStyle(Theme.Colour.text)
        .background(Theme.Colour.background.ignoresSafeArea())
        .themedTitle(DiaryTexts.title(screenLanguage))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Read here: the picker's label closure is Sendable and cannot reach the view's state.
                let addPhotos = DiaryTexts.addPhotos(screenLanguage)
                PhotosPicker(selection: $pickerItems, maxSelectionCount: LibraryImport.maxSelection,
                             matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label(addPhotos, systemImage: "photo.badge.plus")
                }
                .disabled(isImporting)
            }
        }
        // Nothing can be opened, deleted or left while photos are added, so the summary is always seen.
        .navigationBarBackButtonHidden(isImporting)
        .overlay {
            if isImporting {
                ProgressView {
                    Text(DiaryTexts.addingPhotos(screenLanguage))
                        .font(Theme.Font.body)
                }
                .tint(Theme.Colour.text)
                .foregroundStyle(Theme.Colour.text)
                .padding(Theme.Spacing.margin)
                .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
            }
        }
        .navigationDestination(isPresented: storyPresented) {
            if let story {
                StoryView(model: story, location: location)
            }
        }
        .fullScreenCover(item: $fullScreenPhoto) { photo in
            LibraryPhotoScreen(id: photo.id, memory: services.memory, language: screenLanguage)
        }
        .alert(alert?.title(screenLanguage) ?? "", isPresented: alertPresented, presenting: alert) { _ in
            Button(DiaryTexts.ok(screenLanguage), role: .cancel) {}
        } message: { alert in
            Text(alert.message(screenLanguage))
        }
        .onAppear {
            visible = true
            let summary = services.diary.takeImportSummary()
            reload()
            if let summary { showSummary(summary) }
        }
        .onDisappear { visible = false }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty, !isImporting else { return }
            pickerItems = []
            services.diary.startImport(items, memory: services.memory)
        }
        .onChange(of: services.diary.importSummary) { importFinished() }
    }

    @ViewBuilder
    private var content: some View {
        if days.isEmpty {
            if loaded {
                ThemedEmptyState(title: DiaryTexts.emptyTitle(screenLanguage), systemImage: "book",
                                 description: DiaryTexts.emptyDescription(screenLanguage))
            } else {
                Color.clear
            }
        } else {
            List {
                ForEach(days) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        DiaryDayHeader(day: day, language: screenLanguage) { openDayStory(day) }
                    }
                    .themedRows()
                }
            }
            .themedList()
            .disabled(isImporting)
        }
    }

    private func row(_ entry: DiaryEntry) -> some View {
        Button { open(entry) } label: {
            DiaryRow(entry: entry, caption: captions[entry.id], language: screenLanguage, loadThumbnail: thumbnail)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if entry.kind == .libraryPhoto {
                Button(DiaryTexts.delete(screenLanguage), systemImage: "trash", role: .destructive) { delete(entry) }
            }
        }
    }

    // MARK: - Loading

    /// Reads every entry and the captions of the days' stored stories. A corrupt field only costs that field
    /// (logged); a corrupt day story only costs its captions.
    private func reload() {
        let entries: [DiaryEntry]
        do {
            entries = try services.memory.diaryEntries { field in
                AppServices.memoryLog.error("diary entry field unreadable: \(field, privacy: .public)")
            }
        } catch {
            AppServices.logMemoryFailure("diary load failed", error)
            showError(DiaryTexts.loadFailed(screenLanguage))
            loaded = true
            return
        }
        let days = Diary.days(entries, timeZone: .current)
        var captions: [String: String] = [:]
        for day in days where day.entries.contains(where: { $0.kind == .libraryPhoto }) {
            do {
                if let story = try services.memory.dayStory(dayKey: day.id) {
                    captions.merge(story.captions) { _, new in new }
                }
            } catch {
                AppServices.logMemoryFailure("day story load failed", error)
            }
        }
        self.days = days
        self.captions = captions
        loaded = true
    }

    private func thumbnail(_ entry: DiaryEntry) -> UIImage? {
        guard let id = entry.recordID else { return nil }
        let data: Data?
        do {
            switch entry.kind {
            case .photoStory: data = try fetchCapture(id)?.thumbnailJPEG
            case .libraryPhoto: data = try services.memory.libraryPhoto(id: id)?.thumbnailJPEG
            case .buzz, .stop: data = nil
            }
        } catch {
            AppServices.logMemoryFailure("diary thumbnail load failed", error)
            return nil
        }
        return data.flatMap(UIImage.init(data:))
    }

    private func fetchCapture(_ id: UUID) throws -> CaptureRecord? {
        var descriptor = FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try services.memory.context.fetch(descriptor).first
    }

    // MARK: - Actions

    private func open(_ entry: DiaryEntry) {
        guard let id = entry.recordID else {
            showError(HistoryTexts.corrupt(screenLanguage))
            return
        }
        switch entry.kind {
        case .photoStory:
            do {
                guard let record = try fetchCapture(id) else {
                    // Deleted in History since the diary was read.
                    showError(HistoryTexts.corrupt(screenLanguage))
                    reload()
                    return
                }
                let session = try services.memory.session(for: record)
                story = StoryViewModel(session: session, services: services)
            } catch {
                AppServices.logMemoryFailure("open session failed", error)
                showError(HistoryTexts.corrupt(screenLanguage))
            }
        case .buzz, .stop:
            openWalkStory(id)
        case .libraryPhoto:
            fullScreenPhoto = FullScreenPhoto(id: id)
        }
    }

    private func delete(_ entry: DiaryEntry) {
        guard entry.kind == .libraryPhoto, let id = entry.recordID else { return }
        do {
            try services.memory.deleteLibraryPhoto(id: id)
        } catch {
            AppServices.logMemoryFailure("library photo delete failed", error)
            showError(DiaryTexts.deleteFailed(screenLanguage))
        }
        reload()
    }

    private var isImporting: Bool { services.diary.isImporting }

    /// The import finished: shown now if the diary is on top, else when it comes back (`onAppear`).
    private func importFinished() {
        guard visible, let summary = services.diary.takeImportSummary() else { return }
        reload()
        showSummary(summary)
    }

    private func showSummary(_ summary: LibraryImport.Summary) {
        // A load failure from the reload is the more urgent message.
        if alert == nil { alert = .summary(summary) }
    }

    private func showError(_ text: String) {
        alert = .error(text)
    }

    // MARK: - Bindings

    private var storyPresented: Binding<Bool> {
        Binding(get: { story != nil }, set: { presented in
            guard !presented else { return }
            // The story screen is being dropped (navigated back): stop its work silently.
            story?.cancel()
            story = nil
        })
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
    }
}

private enum DiaryAlert {
    case error(String)
    case summary(LibraryImport.Summary)

    func title(_ language: StoryLanguage) -> String {
        switch self {
        case .error: DiaryTexts.failedTitle(language)
        case .summary(let summary): summary.title(language)
        }
    }

    func message(_ language: StoryLanguage) -> String {
        switch self {
        case .error(let text): text
        case .summary(let summary): summary.message(language)
        }
    }
}

private struct FullScreenPhoto: Identifiable {
    let id: UUID
}

/// A library photo at its stored size, on black; read once when shown.
private struct LibraryPhotoScreen: View {
    let id: UUID
    let memory: MemoryStore
    let language: StoryLanguage

    @State private var image: UIImage?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .accessibilityLabel(DiaryTexts.photo(language))
            } else if loaded {
                Text(DiaryTexts.photoUnreadable(language))
                    .font(Theme.Font.body)
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel(DiaryTexts.close(language))
            .padding()
        }
        .task(id: id) {
            do {
                image = try memory.libraryPhoto(id: id).flatMap { UIImage(data: $0.photoJPEG) }
            } catch {
                AppServices.logMemoryFailure("library photo load failed", error)
            }
            loaded = true
        }
    }
}
