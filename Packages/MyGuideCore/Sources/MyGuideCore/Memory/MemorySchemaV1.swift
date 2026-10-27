import Foundation
import SwiftData

/// Version 1 of the store: the four phase 1 models, frozen. These copies must stay exactly as phase 1 shipped them
/// (class names, attributes, relationships, options), since SwiftData matches stores to versions by the entity
/// shapes. Never edit them; a model change adds a new version and a stage to `MemoryMigrationPlan`.
public enum MemorySchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [CaptureRecord.self, StoryRecord.self, PlaceRecord.self, UsageRecord.self]
    }

    @Model final class CaptureRecord {
        @Attribute(.unique) var id: UUID
        var takenAt: Date
        var latitude: Double
        var longitude: Double
        var placeID: String?
        var title: String
        var subject: String
        var language: String
        @Attribute(.externalStorage) var photoJPEG: Data
        @Attribute(.externalStorage) var thumbnailJPEG: Data
        var captureJSON: Data
        var groundingJSON: Data
        var identifiedJSON: Data
        @Attribute(.externalStorage) var thenImagePNG: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoryRecord.capture) var stories: [StoryRecord] = []

        init(id: UUID, takenAt: Date, latitude: Double, longitude: Double, placeID: String?, title: String,
             subject: String, language: String, photoJPEG: Data, thumbnailJPEG: Data, captureJSON: Data,
             groundingJSON: Data, identifiedJSON: Data, thenImagePNG: Data? = nil) {
            self.id = id
            self.takenAt = takenAt
            self.latitude = latitude
            self.longitude = longitude
            self.placeID = placeID
            self.title = title
            self.subject = subject
            self.language = language
            self.photoJPEG = photoJPEG
            self.thumbnailJPEG = thumbnailJPEG
            self.captureJSON = captureJSON
            self.groundingJSON = groundingJSON
            self.identifiedJSON = identifiedJSON
            self.thenImagePNG = thenImagePNG
        }
    }

    @Model final class StoryRecord {
        var level: Int
        var text: String
        var placeID: String?
        var createdAt: Date
        var capture: CaptureRecord?

        init(level: Int, text: String, placeID: String?, createdAt: Date, capture: CaptureRecord? = nil) {
            self.level = level
            self.text = text
            self.placeID = placeID
            self.createdAt = createdAt
            self.capture = capture
        }
    }

    @Model final class PlaceRecord {
        @Attribute(.unique) var id: String
        var name: String
        var latitude: Double
        var longitude: Double
        var firstSeenAt: Date
        var deepestLevelHeard: Int
        var lastHeardAt: Date?

        init(id: String, name: String, latitude: Double, longitude: Double, firstSeenAt: Date,
             deepestLevelHeard: Int, lastHeardAt: Date?) {
            self.id = id
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.firstSeenAt = firstSeenAt
            self.deepestLevelHeard = deepestLevelHeard
            self.lastHeardAt = lastHeardAt
        }
    }

    @Model final class UsageRecord {
        var date: Date
        var kind: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var words: Int
        var images: Int
        var estimatedUSD: Double?

        init(date: Date, kind: String, model: String, inputTokens: Int, outputTokens: Int, words: Int,
             images: Int, estimatedUSD: Double?) {
            self.date = date
            self.kind = kind
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.words = words
            self.images = images
            self.estimatedUSD = estimatedUSD
        }
    }
}
