import MyGuideCore
import SwiftData
import SwiftUI
import UIKit

/// Past sessions, newest first. A row opens its stored story; swipe deletes it.
struct HistoryView: View {
    let services: AppServices
    let location: LocationProvider

    @Query(sort: \CaptureRecord.takenAt, order: .reverse) private var records: [CaptureRecord]
    @State private var story: StoryViewModel?
    @State private var errorText: String?

    static let corruptText = "This story couldn't be opened."
    static let deleteFailedText = "Couldn't delete the story."

    var body: some View {
        VStack(spacing: 0) {
            if let fallback = services.memoryFallback { MemoryUnavailableNotice(fallback: fallback) }
            content
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: storyPresented) {
            if let story {
                StoryView(model: story, location: location)
            }
        }
        .alert("Couldn't complete that", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            ContentUnavailableView("No stories yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Photograph something and its story will be kept here."))
        } else {
            List {
                ForEach(records) { record in
                    Button { open(record) } label: { HistoryRow(record: record) }
                        .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
        }
    }

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

    private func open(_ record: CaptureRecord) {
        do {
            let session = try services.memory.session(for: record)
            story = StoryViewModel(session: session, services: services)
        } catch {
            AppServices.logMemoryFailure("open session failed", error)
            errorText = Self.corruptText
        }
    }

    private func delete(at offsets: IndexSet) {
        // Resolve every record first: deleting shifts the live query's indices.
        let doomed = offsets.map { records[$0] }
        for record in doomed {
            do {
                try services.deleteHistoryEntry(record)
            } catch {
                errorText = Self.deleteFailedText
                return
            }
        }
    }
}

private struct HistoryRow: View {
    let record: CaptureRecord

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.headline).lineLimit(2)
                Text(record.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(data: record.thumbnailJPEG) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 56, height: 56)
        }
    }

    /// Date, then the city when the stored grounding decodes and has one. A bad blob only drops the city.
    private var caption: String {
        let date = record.takenAt.formatted(date: .abbreviated, time: .shortened)
        let city = (try? JSONDecoder().decode(Grounding.self, from: record.groundingJSON))?.address?.city
        guard let city, !city.isEmpty else { return date }
        return "\(date) · \(city)"
    }
}

/// Shown when the persistent store could not be opened and memory lives in RAM only, worded by why.
struct MemoryUnavailableNotice: View {
    let fallback: MemoryFallback
    @AppStorage(AppServices.storyLanguageKey) private var storyLanguage: StoryLanguage = .english

    var body: some View {
        Text(fallback.notice(language: storyLanguage))
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.85))
    }
}
