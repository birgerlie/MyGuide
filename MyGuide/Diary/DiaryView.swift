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
    @State private var isImporting = false
    @State private var importSummary: LibraryImport.Summary?
    @State private var errorText: String?

    static let loadFailedText = "Couldn't load the diary."
    static let deleteFailedText = "Couldn't delete the photo."

    var body: some View {
        VStack(spacing: 0) {
            if !services.memoryIsPersistent { MemoryUnavailableNotice() }
            content
        }
        .navigationTitle("Diary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: LibraryImport.maxSelection,
                             matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label("Add photos", systemImage: "photo.badge.plus")
                }
                .disabled(isImporting)
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Adding photos…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationDestination(isPresented: storyPresented) {
            if let story {
                StoryView(model: story, location: location)
            }
        }
        .fullScreenCover(item: $fullScreenPhoto) { photo in
            LibraryPhotoScreen(id: photo.id, memory: services.memory)
        }
        .alert(importSummary?.title ?? "", isPresented: summaryPresented, presenting: importSummary) { _ in
            Button("OK", role: .cancel) {}
        } message: { summary in
            Text(summary.message)
        }
        .alert("Couldn't complete that", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: reload)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importPhotos(items) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if days.isEmpty {
            if loaded {
                ContentUnavailableView("No diary entries yet", systemImage: "book",
                                       description: Text("Photo stories, walk stories and photos you add are kept here by day."))
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
                        DiaryDayHeader(day: day) { openDayStory(day) }
                    }
                }
            }
        }
    }

    private func row(_ entry: DiaryEntry) -> some View {
        Button { open(entry) } label: {
            DiaryRow(entry: entry, caption: captions[entry.id], loadThumbnail: thumbnail)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if entry.kind == .libraryPhoto {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
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
            errorText = Self.loadFailedText
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
            errorText = HistoryView.corruptText
            return
        }
        switch entry.kind {
        case .photoStory:
            do {
                guard let record = try fetchCapture(id) else {
                    // Deleted in History since the diary was read.
                    errorText = HistoryView.corruptText
                    reload()
                    return
                }
                let session = try services.memory.session(for: record)
                story = StoryViewModel(session: session, services: services)
            } catch {
                AppServices.logMemoryFailure("open session failed", error)
                errorText = HistoryView.corruptText
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
            errorText = Self.deleteFailedText
        }
        reload()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        let summary = await LibraryImport.run(items, memory: services.memory)
        isImporting = false
        reload()
        importSummary = summary
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

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private var summaryPresented: Binding<Bool> {
        Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
    }
}

private struct FullScreenPhoto: Identifiable {
    let id: UUID
}

/// A library photo at its stored size, on black; read once when shown.
private struct LibraryPhotoScreen: View {
    let id: UUID
    let memory: MemoryStore

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
                    .accessibilityLabel("Photo")
            } else if loaded {
                Text("This photo couldn't be opened.")
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
            .accessibilityLabel("Close")
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
