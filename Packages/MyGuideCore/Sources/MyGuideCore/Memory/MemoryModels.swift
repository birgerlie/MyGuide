import Foundation
import SwiftData

/// One photo and everything learned about it (spec 8.2: "photos taken").
@Model public final class CaptureRecord {
    @Attribute(.unique) public var id: UUID
    public var takenAt: Date
    public var latitude: Double
    public var longitude: Double
    /// The matched candidate's ID, or nil when the subject was not tied to a known place.
    public var placeID: String?
    public var title: String
    public var subject: String
    /// `StoryLanguage.rawValue`.
    public var language: String
    @Attribute(.externalStorage) public var photoJPEG: Data
    @Attribute(.externalStorage) public var thumbnailJPEG: Data
    /// JSON of `CaptureContext`.
    public var captureJSON: Data
    /// JSON of `Grounding`.
    public var groundingJSON: Data
    /// JSON of `IdentifiedStory`.
    public var identifiedJSON: Data
    @Attribute(.externalStorage) public var thenImagePNG: Data?
    @Relationship(deleteRule: .cascade, inverse: \StoryRecord.capture) public var stories: [StoryRecord] = []

    public init(id: UUID, takenAt: Date, latitude: Double, longitude: Double, placeID: String?, title: String,
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

/// One told story level, full text (spec 8.2: "stories told (all levels, full text)"). Belongs to a photo capture
/// or to a walk story.
@Model public final class StoryRecord {
    /// `StoryLevel.rawValue`, 1...3.
    public var level: Int
    public var text: String
    /// Copy of the owner's `placeID`, so priors can be fetched by place without a join.
    public var placeID: String?
    /// When the level was stored (`MemoryStore`'s clock); levels stored in one save share it, so order by level too.
    /// Levels stored before this rule carry their capture's `takenAt` / walk story's `createdAt` plus the level index.
    public var createdAt: Date
    public var capture: CaptureRecord?
    public var walkStory: WalkStoryRecord?

    public init(level: Int, text: String, placeID: String?, createdAt: Date, capture: CaptureRecord? = nil,
                walkStory: WalkStoryRecord? = nil) {
        self.level = level
        self.text = text
        self.placeID = placeID
        self.createdAt = createdAt
        self.capture = capture
        self.walkStory = walkStory
    }
}

/// A known place: photographed, buzzed or heard.
@Model public final class PlaceRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var firstSeenAt: Date
    /// The highest story level saved for this place; a level counts as heard once saved.
    public var deepestLevelHeard: Int
    public var lastHeardAt: Date?
    /// When the owner first skipped a buzz about this place; a skipped place never buzzes again.
    public var skippedAt: Date?
    public var lastBuzzedAt: Date?
    public var lastBuzzTripID: UUID?

    public init(id: String, name: String, latitude: Double, longitude: Double, firstSeenAt: Date,
                deepestLevelHeard: Int, lastHeardAt: Date?, skippedAt: Date? = nil, lastBuzzedAt: Date? = nil,
                lastBuzzTripID: UUID? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.firstSeenAt = firstSeenAt
        self.deepestLevelHeard = deepestLevelHeard
        self.lastHeardAt = lastHeardAt
        self.skippedAt = skippedAt
        self.lastBuzzedAt = lastBuzzedAt
        self.lastBuzzTripID = lastBuzzTripID
    }
}

/// One metered API call, written by `MemoryStore.recordUsage`.
@Model public final class UsageRecord {
    public var date: Date
    public var kind: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var words: Int
    public var images: Int
    public var estimatedUSD: Double?

    public init(date: Date, kind: String, model: String, inputTokens: Int, outputTokens: Int, words: Int,
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

/// A stretch of use in one city (design 7.7); see `TripRule`.
@Model public final class TripRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    /// Filled from the first known city when the trip started without one.
    public var city: String?
    public var lastUsedAt: Date

    public init(id: UUID, startedAt: Date, city: String?, lastUsedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        self.city = city
        self.lastUsedAt = lastUsedAt
    }
}

/// One buzz in the buzz log (design 7.7).
@Model public final class BuzzRecord {
    /// `Buzz.id`.
    @Attribute(.unique) public var id: UUID
    public var at: Date
    public var tripID: UUID
    public var placeID: String
    public var placeName: String
    /// `Candidate.kind`.
    public var kind: String
    /// `PlaceTier.rawValue`.
    public var tier: Int
    /// Metres from the walker when the buzz went out.
    public var distance: Double
    /// `BuzzOutcome.rawValue`.
    public var outcome: String
    /// The deepest story level heard from this buzz; 0 when none.
    public var deepestLevel: Int = 0

    public init(id: UUID, at: Date, tripID: UUID, placeID: String, placeName: String, kind: String, tier: Int,
                distance: Double, outcome: String, deepestLevel: Int = 0) {
        self.id = id
        self.at = at
        self.tripID = tripID
        self.placeID = placeID
        self.placeName = placeName
        self.kind = kind
        self.tier = tier
        self.distance = distance
        self.outcome = outcome
        self.deepestLevel = deepestLevel
    }
}

/// One point of the walked track (spec 8.2), for the later trip diary.
@Model public final class TrackPoint {
    public var at: Date
    public var latitude: Double
    public var longitude: Double
    public var tripID: UUID

    public init(at: Date, latitude: Double, longitude: Double, tripID: UUID) {
        self.at = at
        self.latitude = latitude
        self.longitude = longitude
        self.tripID = tripID
    }
}

/// A `WalkStory` without its levels; the levels are `StoryRecord`s.
@Model public final class WalkStoryRecord {
    @Attribute(.unique) public var id: UUID
    /// `WalkStory.Kind.rawValue`.
    public var kind: String
    /// The buzzed place's ID; nil for stop stories.
    public var placeID: String?
    /// JSON of the buzzed `Candidate`; nil for stop stories.
    public var placeJSON: Data?
    /// JSON of the walker's `Address` when the story was made (buzz and stop stories); JSON null when the lookup
    /// failed; nil when none was stored (a buzz story from before buzz stories looked one up): unknown.
    public var addressJSON: Data?
    /// The buzz direction line; nil for stop stories.
    public var detail: String?
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var course: Double?
    /// `StoryLanguage.rawValue`.
    public var language: String
    public var createdAt: Date
    /// The trip the story was first saved in.
    public var tripID: UUID
    @Relationship(deleteRule: .cascade, inverse: \StoryRecord.walkStory) public var stories: [StoryRecord] = []

    public init(id: UUID, kind: String, placeID: String?, placeJSON: Data?, addressJSON: Data?, detail: String?,
                title: String, latitude: Double, longitude: Double, course: Double?, language: String, createdAt: Date,
                tripID: UUID) {
        self.id = id
        self.kind = kind
        self.placeID = placeID
        self.placeJSON = placeJSON
        self.addressJSON = addressJSON
        self.detail = detail
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.course = course
        self.language = language
        self.createdAt = createdAt
        self.tripID = tripID
    }
}

/// A photo imported from the phone's photo library (spec 4.3). Nothing is sent anywhere on import.
@Model public final class LibraryPhotoRecord {
    @Attribute(.unique) public var id: UUID
    /// The library asset's local identifier; an asset is stored once.
    @Attribute(.unique) public var assetIdentifier: String
    public var takenAt: Date
    public var latitude: Double?
    public var longitude: Double?
    @Attribute(.externalStorage) public var photoJPEG: Data
    @Attribute(.externalStorage) public var thumbnailJPEG: Data
    public var importedAt: Date

    public init(id: UUID, assetIdentifier: String, takenAt: Date, latitude: Double?, longitude: Double?,
                photoJPEG: Data, thumbnailJPEG: Data, importedAt: Date) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.photoJPEG = photoJPEG
        self.thumbnailJPEG = thumbnailJPEG
        self.importedAt = importedAt
    }
}

/// The story of one day: a summary and a caption per photo (spec 3). Rebuilt as a `DayStory` by `MemoryStore`.
@Model public final class DayStoryRecord {
    /// `yyyy-MM-dd` in the phone's time zone.
    @Attribute(.unique) public var dayKey: String
    public var createdAt: Date
    /// `StoryLanguage.rawValue`.
    public var language: String
    public var summary: String
    /// JSON of `[String: String]`: photo id (`capture:<uuid>` / `library:<uuid>`) to caption.
    public var captionsJSON: Data
    /// Photo ids in page order.
    public var photoIDs: [String]
    /// All photos of the day, including any not sent for captions.
    public var totalPhotos: Int

    public init(dayKey: String, createdAt: Date, language: String, summary: String, captionsJSON: Data,
                photoIDs: [String], totalPhotos: Int) {
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.language = language
        self.summary = summary
        self.captionsJSON = captionsJSON
        self.photoIDs = photoIDs
        self.totalPhotos = totalPhotos
    }
}

public enum MemorySchema {
    /// Every live persistent model (`MemorySchemaV3`). The app opens the store through `MemorySchemaV3` and
    /// `MemoryMigrationPlan`; tests may use this list directly.
    public static let models: [any PersistentModel.Type] = MemorySchemaV3.models
}

/// Version 2 of the store: phase 2's trips, buzz log, track, walk stories and place flags. Every attribute it adds
/// to a version 1 entity is optional or defaulted, so the step from version 1 is lightweight.
/// Version 3 only adds entities, so the eight classes are shared with it rather than frozen into copies; the list
/// is explicit so adding a model to the live schema cannot change what version 2 means. Before a later version
/// changes any of these eight, freeze version 2 into nested copies like `MemorySchemaV1`.
public enum MemorySchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [CaptureRecord.self, StoryRecord.self, PlaceRecord.self, UsageRecord.self,
         TripRecord.self, BuzzRecord.self, TrackPoint.self, WalkStoryRecord.self]
    }
}

/// Version 3 of the store: version 2 plus library photos and day stories. Only entities are added, so the step
/// from version 2 is lightweight.
public enum MemorySchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        MemorySchemaV2.models + [LibraryPhotoRecord.self, DayStoryRecord.self]
    }
}

/// Migration plan for the memory store.
public enum MemoryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MemorySchemaV1.self, MemorySchemaV2.self, MemorySchemaV3.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: MemorySchemaV1.self, toVersion: MemorySchemaV2.self),
         .lightweight(fromVersion: MemorySchemaV2.self, toVersion: MemorySchemaV3.self)]
    }
}
