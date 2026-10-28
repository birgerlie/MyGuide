import Foundation
import MyGuideCore
import Observation
import SwiftUI
import UIKit

/// One day's story (spec 5.4–5.6): opens the stored story or writes one, writes it again on request, and renders
/// its pages for sharing. At most one write or share runs at a time; `cancel()` stops both. Owned by `DiaryWork`, so
/// it outlives its screen while another screen covers it.
@MainActor
@Observable
final class DayStoryModel {
    /// The screen's one alert, so a confirmation and an error never compete.
    enum Alert: Equatable {
        case confirmRewrite
        case error(String)
    }

    /// The rendered pages, ready for the share sheet.
    struct ShareSet: Identifiable {
        let id = UUID()
        let images: [UIImage]
    }

    static let writingText = "Writing the day story…"
    static let renderingText = "Preparing pages…"
    static let saveFailedText = "The day story was written but couldn't be saved."
    static let shareFailedText = "Couldn't prepare the pages to share."
    /// Shared pages are rendered at this size in points, times `shareScale`: 1080 × 1920 pixels (spec 5.5).
    static let sharePageSize = CGSize(width: 360, height: 640)
    static let shareScale: CGFloat = 3

    let dayKey: String
    private(set) var story: DayStory?
    private(set) var pages: DayStoryPages?
    /// The day's date, from its key; nil only for a malformed key.
    let date: Date?
    /// The day's city, when an entry of the day has one.
    private(set) var city: String?
    /// True once the stored story has been read (or found missing or unreadable).
    private(set) var loaded = false
    /// The stored record exists but cannot be read back; "Write again" replaces it.
    private(set) var unreadable = false
    var alert: Alert?
    var shareSet: ShareSet?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var writeTask: Task<Void, Never>? {
        didSet { isWriting = writeTask != nil }
    }
    @ObservationIgnored private var shareTask: Task<Void, Never>? {
        didSet { isRendering = shareTask != nil }
    }
    /// Observed mirrors of the two tasks.
    private(set) var isWriting = false
    private(set) var isRendering = false

    init(dayKey: String, services: AppServices) {
        self.dayKey = dayKey
        self.services = services
        date = Diary.startOfDay(dayKey: dayKey, timeZone: .current)
    }

    var busy: Bool { isWriting || isRendering }

    // MARK: - Opening

    /// Reads the stored story and shows its pages; with no story, writes one. Runs once per model.
    func open() {
        guard !loaded else { return }
        let photoTimes = loadDay()?.photoTimes ?? [:]
        do {
            if let stored = try services.memory.dayStory(dayKey: dayKey) {
                show(stored, photoTimes: photoTimes)
            }
        } catch {
            AppServices.logMemoryFailure("day story load failed", error)
            unreadable = true
        }
        loaded = true
        if story == nil, !unreadable { write() }
    }

    // MARK: - Writing

    /// Asks before replacing the story; writes at once when there is none to lose.
    func requestRewrite() {
        guard !busy else { return }
        if story == nil {
            write()
        } else {
            alert = .confirmRewrite
        }
    }

    /// Writes the day's story from the photos kept now and replaces the stored one. Ignored while busy.
    func write() {
        guard !busy else { return }
        let flow: DayStoryFlow
        do {
            flow = try services.makeDayStoryFlow()
        } catch {
            alert = .error(UserFacingMessage.message(for: error))
            return
        }
        guard let current = loadDay() else { return }
        guard let day = current.day else {
            // Every entry of the day has been deleted since the diary was read.
            alert = .error(UserFacingMessage.message(for: DayStoryError.noPhotos))
            return
        }
        let language = Self.storyLanguage()
        writeTask = Task { [services] in
            do {
                let (written, usage) = try await flow.write(day: day, language: language)
                // Paid for, so counted and kept even when the day left the stack meanwhile.
                services.recordUsage(usage)
                var saved = true
                do {
                    try services.memory.saveDayStory(written)
                } catch {
                    AppServices.logMemoryFailure("day story save failed", error)
                    saved = false
                }
                // Cancelled: the day left the stack, and `cancel()` has already cleared the task.
                guard !Task.isCancelled else { return }
                writeTask = nil
                unreadable = unreadable && !saved
                show(written, photoTimes: current.photoTimes)
                if !saved { alert = .error(Self.saveFailedText) }
            } catch {
                guard !Task.isCancelled else { return }
                writeTask = nil
                let message = UserFacingMessage.message(for: error)
                // A cancellation nobody asked for is still a failure the owner must see.
                alert = .error(message.isEmpty ? StoryViewModel.unexpectedCancellationText : message)
            }
        }
    }

    // MARK: - Sharing

    /// Renders the summary page and every photo page at 1080 × 1920 and offers them to the share sheet.
    /// Rendering is on the main actor, one page at a time, yielding between pages so the progress shows.
    func share() {
        guard !busy, let pages else { return }
        let header = header
        shareTask = Task {
            // Let the progress overlay draw before the first page blocks the main thread.
            try? await Task.sleep(for: .milliseconds(50))
            var images: [UIImage] = []
            let contents = [DayStoryPageView.Content.summary(header: header, summary: pages.summary,
                                                             note: pages.countNote)]
                + pages.photos.map { DayStoryPageView.Content.photo(time: $0.time, caption: $0.caption) }
            // The summary page shows the first photo.
            let imageIDs: [String?] = [pages.photos.first?.id] + pages.photos.map(\.id)
            for (content, id) in zip(contents, imageIDs) {
                guard !Task.isCancelled else { return }
                let photo = id.flatMap { services.photoJPEG(id: $0) }.flatMap(UIImage.init(data:))
                if let image = Self.render(DayStoryPageView(content: content, image: photo)) {
                    images.append(image)
                }
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            shareTask = nil
            if images.count == contents.count {
                shareSet = ShareSet(images: images)
            } else {
                alert = .error(Self.shareFailedText)
            }
        }
    }

    /// One page as a 1080 × 1920 image, kept as JPEG data so a dozen pages do not sit decoded in memory.
    private static func render(_ page: DayStoryPageView) -> UIImage? {
        let renderer = ImageRenderer(content: page.frame(width: sharePageSize.width, height: sharePageSize.height))
        renderer.proposedSize = ProposedViewSize(sharePageSize)
        renderer.scale = shareScale
        return renderer.uiImage?.jpegData(compressionQuality: 0.9).flatMap(UIImage.init(data:))
    }

    // MARK: - Photos

    /// The photo's stored image, decoded off the main thread; nil when it is gone or unreadable.
    func displayImage(id: String) async -> UIImage? {
        guard let data = services.photoJPEG(id: id), let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }

    /// Date and city for the summary page.
    var header: DayStoryPageView.Header {
        DayStoryPageView.Header(date: date, city: city)
    }

    // MARK: - Lifetime

    /// Stops a running write or share; a write whose request has already been answered still saves its story.
    func cancel() {
        writeTask?.cancel()
        writeTask = nil
        shareTask?.cancel()
        shareTask = nil
    }

    // MARK: - Private

    private func show(_ story: DayStory, photoTimes: [String: Date]) {
        self.story = story
        pages = DayStoryPages(story: story, photoTimes: photoTimes)
    }

    /// The day as kept now, and every photo still kept (id to time). Nil on a memory failure, shown as an alert.
    private func loadDay() -> (day: DiaryDay?, photoTimes: [String: Date])? {
        let entries: [DiaryEntry]
        do {
            entries = try services.memory.diaryEntries { field in
                AppServices.memoryLog.error("diary entry field unreadable: \(field, privacy: .public)")
            }
        } catch {
            AppServices.logMemoryFailure("diary load failed", error)
            alert = .error(DiaryView.loadFailedText)
            return nil
        }
        // All photos, not just this day's: a story's photos stay its own even if the phone's time zone moved
        // one of them to a neighbouring day.
        var photoTimes: [String: Date] = [:]
        for entry in entries where entry.hasPhoto {
            photoTimes[entry.id] = entry.time
        }
        let day = Diary.days(entries, timeZone: .current).first { $0.id == dayKey }
        city = day?.city
        return (day, photoTimes)
    }

    private static func storyLanguage() -> StoryLanguage {
        UserDefaults.standard.string(forKey: AppServices.storyLanguageKey).flatMap(StoryLanguage.init(rawValue:)) ?? .english
    }
}
