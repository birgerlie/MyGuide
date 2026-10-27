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

/// One told story level, full text (spec 8.2: "stories told (all levels, full text)").
@Model public final class StoryRecord {
    /// `StoryLevel.rawValue`, 1...3.
    public var level: Int
    public var text: String
    /// Copy of the capture's `placeID`, so priors can be fetched by place without a join.
    public var placeID: String?
    /// The capture's `takenAt` plus the level index in seconds, so levels sort in telling order.
    public var createdAt: Date
    public var capture: CaptureRecord?

    public init(level: Int, text: String, placeID: String?, createdAt: Date, capture: CaptureRecord? = nil) {
        self.level = level
        self.text = text
        self.placeID = placeID
        self.createdAt = createdAt
        self.capture = capture
    }
}

/// A known place the listener has photographed (spec 8.2: "places visited").
@Model public final class PlaceRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var firstSeenAt: Date
    /// The highest story level saved for this place; a level counts as heard once saved.
    public var deepestLevelHeard: Int
    public var lastHeardAt: Date?

    public init(id: String, name: String, latitude: Double, longitude: Double, firstSeenAt: Date,
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

public enum MemorySchema {
    /// Every persistent model; the app passes this to `.modelContainer(for:)`.
    public static let models: [any PersistentModel.Type] = [
        CaptureRecord.self, StoryRecord.self, PlaceRecord.self, UsageRecord.self
    ]
}
