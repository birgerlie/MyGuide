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
    /// Stores the photo downscaled (long side 1536, thumbnail 400, JPEG 0.7, no EXIF), stamped with `now()` as its
    /// import time. Returns its id, or nil when `assetIdentifier` is already stored. Throws an
    /// `ImageProcessingError` for an unreadable image, storing nothing.
    public func importLibraryPhoto(jpeg: Data, assetIdentifier: String, takenAt: Date,
                                   coordinate: Coordinate?) throws -> UUID? {
        guard try libraryPhotoRecord(assetIdentifier: assetIdentifier) == nil else { return nil }
        let photo = try ImageProcessing.downscaledJPEG(jpeg, maxLongSide: PhotoStoryFlow.uploadLongSide,
                                                       quality: PhotoStoryFlow.jpegQuality)
        let thumbnail = try ImageProcessing.downscaledJPEG(jpeg, maxLongSide: PhotoStoryFlow.thumbnailLongSide,
                                                           quality: PhotoStoryFlow.jpegQuality)
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
        let captionsJSON = try JSONEncoder().encode(story.captions)
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

    // MARK: - Private

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
