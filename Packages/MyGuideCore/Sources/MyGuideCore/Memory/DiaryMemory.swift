import Foundation
import SwiftData

/// A day's story (spec 3): a summary and a caption per photo. Mirrors `DayStoryRecord`.
public struct DayStory: Sendable, Equatable {
    /// `yyyy-MM-dd` in the phone's time zone.
    public var dayKey: String
    public var createdAt: Date
    public var language: StoryLanguage
    public var summary: String
    /// Photo id (`capture:<uuid>` / `library:<uuid>`) to caption.
    public var captions: [String: String]
    /// Photo ids in page order.
    public var photoIDs: [String]
    /// All photos of the day, including any not sent for captions.
    public var totalPhotos: Int

    public init(dayKey: String, createdAt: Date, language: StoryLanguage, summary: String,
                captions: [String: String], photoIDs: [String], totalPhotos: Int) {
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.language = language
        self.summary = summary
        self.captions = captions
        self.photoIDs = photoIDs
        self.totalPhotos = totalPhotos
    }
}

/// The diary's memory: photos imported from the library and day stories. Every write saves at once; a failed
/// save rolls back and rethrows.
extension MemoryStore {
    /// Stored sizes of an imported photo: long side in pixels, and JPEG quality.
    /// Public so the app can downscale off the main actor before importing.
    nonisolated public static let libraryPhotoLongSide = 1536
    static let libraryThumbnailLongSide = 400
    nonisolated public static let libraryJPEGQuality = 0.7

    /// Stores the photo downscaled (long side 1536, thumbnail 400, JPEG 0.7, no EXIF), stamped with `now()` as its
    /// import time. Returns its id, or nil when `assetIdentifier` is already stored. Throws an
    /// `ImageProcessingError` for an unreadable image, storing nothing.
    public func importLibraryPhoto(jpeg: Data, assetIdentifier: String, takenAt: Date,
                                   coordinate: Coordinate?) throws -> UUID? {
        guard try libraryPhotoRecord(assetIdentifier: assetIdentifier) == nil else { return nil }
        let photo = try ImageProcessing.downscaledJPEG(jpeg, maxLongSide: Self.libraryPhotoLongSide,
                                                       quality: Self.libraryJPEGQuality)
        // From the downscaled copy, so the original is decoded once.
        let thumbnail = try ImageProcessing.downscaledJPEG(photo, maxLongSide: Self.libraryThumbnailLongSide,
                                                           quality: Self.libraryJPEGQuality)
        let id = UUID()
        try saving {
            context.insert(LibraryPhotoRecord(
                id: id, assetIdentifier: assetIdentifier, takenAt: takenAt, latitude: coordinate?.latitude,
                longitude: coordinate?.longitude, photoJPEG: photo, thumbnailJPEG: thumbnail, importedAt: now()))
        }
        return id
    }

    /// Removes the photo; an unknown id changes nothing.
    public func deleteLibraryPhoto(id: UUID) throws {
        guard let record = try libraryPhoto(id: id) else { return }
        try saving { context.delete(record) }
    }

    public func libraryPhoto(id: UUID) throws -> LibraryPhotoRecord? {
        var descriptor = FetchDescriptor<LibraryPhotoRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Stores the story, replacing any story of the same `dayKey`.
    public func saveDayStory(_ story: DayStory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let captionsJSON = try encoder.encode(story.captions)
        let existing = try dayStoryRecord(dayKey: story.dayKey)
        try saving {
            if let existing {
                existing.createdAt = story.createdAt
                existing.language = story.language.rawValue
                existing.summary = story.summary
                existing.captionsJSON = captionsJSON
                existing.photoIDs = story.photoIDs
                existing.totalPhotos = story.totalPhotos
            } else {
                context.insert(DayStoryRecord(
                    dayKey: story.dayKey, createdAt: story.createdAt, language: story.language.rawValue,
                    summary: story.summary, captionsJSON: captionsJSON, photoIDs: story.photoIDs,
                    totalPhotos: story.totalPhotos))
            }
        }
    }

    /// The saved story of the day; nil when there is none. Throws `corruptRecord` when the record cannot be read
    /// back (bad captions JSON or unknown language).
    public func dayStory(dayKey: String) throws -> DayStory? {
        guard let record = try dayStoryRecord(dayKey: dayKey) else { return nil }
        guard let language = StoryLanguage(rawValue: record.language),
              let captions = try? JSONDecoder().decode([String: String].self, from: record.captionsJSON)
        else { throw MemoryError.corruptRecord }
        return DayStory(dayKey: record.dayKey, createdAt: record.createdAt, language: language,
                        summary: record.summary, captions: captions, photoIDs: record.photoIDs,
                        totalPhotos: record.totalPhotos)
    }

    /// Every capture, stop story, heard buzz story (`BuzzRecord.deepestLevel` >= 1; a buzz story nobody heard, or
    /// without a log entry, is left out) and library photo, in no particular order: group with `Diary.days`.
    /// A record whose JSON cannot be decoded keeps its entry but loses that field (no city, or no coordinate for
    /// a buzz), so one corrupt record never hides the diary. `onCorrupt` is called once per such field, and once
    /// per walk story of an unknown kind (which is left out), with the entry id and the field, such as
    /// `capture:<uuid> groundingJSON`. Photo bytes are not fetched.
    public func diaryEntries(onCorrupt: (String) -> Void = { _ in }) throws -> [DiaryEntry] {
        let decoder = JSONDecoder()
        var entries: [DiaryEntry] = []

        // Core Data keeps small external-storage blobs inline in SQLite, so name the fields to load.
        var captures = FetchDescriptor<CaptureRecord>()
        captures.propertiesToFetch = [\.id, \.takenAt, \.latitude, \.longitude, \.title, \.subject, \.groundingJSON]
        for capture in try context.fetch(captures) {
            let id = "capture:\(capture.id.uuidString)"
            let grounding: Grounding?
            do {
                grounding = try decoder.decode(Grounding.self, from: capture.groundingJSON)
            } catch {
                onCorrupt("\(id) groundingJSON")
                grounding = nil
            }
            entries.append(DiaryEntry(
                id: id, kind: .photoStory, time: capture.takenAt, title: capture.title, placeName: capture.subject,
                coordinate: Coordinate(latitude: capture.latitude, longitude: capture.longitude),
                firstSentence: Self.firstSentence(of: capture.stories), city: grounding?.address?.city,
                hasPhoto: true))
        }

        // Only a simple comparison goes into the predicate; SwiftData's SQL generation rejects richer forms.
        let heard = try context.fetch(FetchDescriptor<BuzzRecord>(predicate: #Predicate { $0.deepestLevel >= 1 }))
        let heardBuzzes = Dictionary(heard.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for walk in try context.fetch(FetchDescriptor<WalkStoryRecord>()) {
            let id = "walk:\(walk.id.uuidString)"
            let kind: DiaryEntry.Kind
            switch walk.kind {
            case WalkStory.Kind.buzz.rawValue: kind = .buzz
            case WalkStory.Kind.stop.rawValue: kind = .stop
            default:
                onCorrupt("\(id) kind")
                continue
            }
            if kind == .buzz, heardBuzzes[walk.id] == nil { continue }

            // JSON null (a failed lookup) decodes to nil, like no data at all.
            var city: String?
            if let data = walk.addressJSON {
                do {
                    city = try decoder.decode(Address?.self, from: data)?.city
                } catch {
                    onCorrupt("\(id) addressJSON")
                }
            }
            if kind == .buzz, let buzz = heardBuzzes[walk.id] {
                var coordinate: Coordinate?
                if let data = walk.placeJSON {
                    do {
                        coordinate = try decoder.decode(Candidate.self, from: data).coordinate
                    } catch {
                        onCorrupt("\(id) placeJSON")
                    }
                }
                entries.append(DiaryEntry(
                    id: id, kind: .buzz, time: walk.createdAt, title: walk.title, placeName: buzz.placeName,
                    coordinate: coordinate, firstSentence: Self.firstSentence(of: walk.stories), city: city,
                    hasPhoto: false))
            } else {
                entries.append(DiaryEntry(
                    id: id, kind: .stop, time: walk.createdAt, title: walk.title, placeName: nil,
                    coordinate: Coordinate(latitude: walk.latitude, longitude: walk.longitude),
                    firstSentence: Self.firstSentence(of: walk.stories), city: city, hasPhoto: false))
            }
        }

        var photos = FetchDescriptor<LibraryPhotoRecord>()
        photos.propertiesToFetch = [\.id, \.takenAt, \.latitude, \.longitude]
        for photo in try context.fetch(photos) {
            let coordinate: Coordinate?
            if let latitude = photo.latitude, let longitude = photo.longitude {
                coordinate = Coordinate(latitude: latitude, longitude: longitude)
            } else {
                coordinate = nil
            }
            entries.append(DiaryEntry(
                id: "library:\(photo.id.uuidString)", kind: .libraryPhoto, time: photo.takenAt, title: "",
                placeName: nil, coordinate: coordinate, firstSentence: nil, city: nil, hasPhoto: true))
        }
        return entries
    }

    // MARK: - Private

    private static func firstSentence(of stories: [StoryRecord]) -> String? {
        stories.first { $0.level == 1 }.map { RecentStories.firstSentence($0.text) }
    }

    private func libraryPhotoRecord(assetIdentifier: String) throws -> LibraryPhotoRecord? {
        var descriptor = FetchDescriptor<LibraryPhotoRecord>(predicate: #Predicate { $0.assetIdentifier == assetIdentifier })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func dayStoryRecord(dayKey: String) throws -> DayStoryRecord? {
        var descriptor = FetchDescriptor<DayStoryRecord>(predicate: #Predicate { $0.dayKey == dayKey })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
