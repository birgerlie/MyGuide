import Foundation
import SwiftData

/// What became of a buzz (design 7.7). `pending` until the owner hears or skips it, or walking mode ends.
public enum BuzzOutcome: String, Sendable, Codable {
    case pending, heard, skipped, ignored
}

/// One row of the buzz log, newest first from `MemoryStore.buzzLog()`.
public struct BuzzLogEntry: Sendable, Equatable {
    public var id: UUID
    public var at: Date
    public var placeID: String
    public var placeName: String
    /// `Candidate.kind`.
    public var kind: String
    /// `PlaceTier.rawValue`.
    public var tier: Int
    /// Metres from the walker when the buzz went out.
    public var distance: Double
    public var outcome: BuzzOutcome
    /// The deepest story level heard; 0 when none.
    public var deepestLevel: Int

    public init(id: UUID, at: Date, placeID: String, placeName: String, kind: String, tier: Int, distance: Double,
                outcome: BuzzOutcome, deepestLevel: Int) {
        self.id = id
        self.at = at
        self.placeID = placeID
        self.placeName = placeName
        self.kind = kind
        self.tier = tier
        self.distance = distance
        self.outcome = outcome
        self.deepestLevel = deepestLevel
    }
}

/// One fix of the walked track.
public struct TrackSample: Sendable, Equatable {
    public var at: Date
    public var coordinate: Coordinate

    public init(at: Date, coordinate: Coordinate) {
        self.at = at
        self.coordinate = coordinate
    }
}

/// Walking mode's memory (design 7.7): trips, the buzz log, place flags, walk stories and the track.
/// Every write saves at once; a failed save rolls back and rethrows.
extension MemoryStore {
    /// The current trip, extended to `now`, or a new trip when `TripRule` says one starts. A trip without a city
    /// adopts `city`. `lastUsedAt` never moves backwards.
    public func touchTrip(now: Date, city: String?) throws -> TripRecord {
        let city = TripRule.normalisedCity(city)
        var descriptor = FetchDescriptor<TripRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let current = try context.fetch(descriptor).first
        return try saving {
            if let current, !TripRule.startsNewTrip(lastUsedAt: current.lastUsedAt, tripCity: current.city,
                                                    now: now, city: city) {
                if TripRule.normalisedCity(current.city) == nil, let city { current.city = city }
                current.lastUsedAt = max(current.lastUsedAt, now)
                return current
            }
            let trip = TripRecord(id: UUID(), startedAt: now, city: city, lastUsedAt: now)
            context.insert(trip)
            return trip
        }
    }

    /// Places that never buzz again: heard (a story level saved, photo or walk) or skipped.
    public func retiredPlaceIDs() throws -> Set<String> {
        let descriptor = FetchDescriptor<PlaceRecord>(predicate: #Predicate { place in
            place.deepestLevelHeard >= 1 || place.skippedAt != nil
        })
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// Places buzzed in the trip, from the buzz log.
    public func placeIDsBuzzed(tripID: UUID) throws -> Set<String> {
        let descriptor = FetchDescriptor<BuzzRecord>(predicate: #Predicate { $0.tripID == tripID })
        return Set(try context.fetch(descriptor).map(\.placeID))
    }

    /// Logs the buzz as pending and marks its place as buzzed in the trip. A new place starts unheard.
    /// Recording a buzz id that is already logged changes nothing.
    public func recordBuzz(_ buzz: Buzz, tripID: UUID, at: Date) throws {
        guard try buzzRecord(id: buzz.id) == nil else { return }
        let candidate = buzz.place.candidate
        try saving {
            context.insert(BuzzRecord(id: buzz.id, at: at, tripID: tripID, placeID: candidate.id,
                                      placeName: candidate.name, kind: candidate.kind, tier: buzz.place.tier.rawValue,
                                      distance: buzz.distance, outcome: BuzzOutcome.pending.rawValue))
            let place = try upsertWalkPlace(candidate, seenAt: at)
            place.lastBuzzedAt = at
            place.lastBuzzTripID = tripID
        }
    }

    /// Moves a buzz on from `pending`. Afterwards only `heard` → `heard` with a deeper level changes anything,
    /// and `ignored` yields to a late explicit `heard` or `skipped`; the deepest level never decreases. When the change applies, the buzz's place is updated in the same save:
    /// `heard` raises its `deepestLevelHeard` and sets `lastHeardAt = at`, `skipped` sets `skippedAt` (the first
    /// skip time is kept). Both retire the place. A refused change touches nothing.
    /// Throws `corruptRecord` for an unknown buzz id.
    public func setBuzzOutcome(_ id: UUID, _ outcome: BuzzOutcome, deepestLevel: Int, at: Date) throws {
        guard let record = try buzzRecord(id: id), let current = BuzzOutcome(rawValue: record.outcome) else {
            throw MemoryError.corruptRecord
        }
        let applies = current == .pending
            || (current == .ignored && (outcome == .heard || outcome == .skipped))
            || (current == .heard && outcome == .heard && deepestLevel > record.deepestLevel)
        guard applies else { return }
        // recordBuzz stores the place in the same save as the buzz, so it is only missing if deleted since.
        let place = try place(id: record.placeID)
        try saving {
            record.outcome = outcome.rawValue
            record.deepestLevel = max(record.deepestLevel, deepestLevel)
            switch outcome {
            case .heard:
                place?.deepestLevelHeard = max(place?.deepestLevelHeard ?? 0, deepestLevel)
                place?.lastHeardAt = at
            case .skipped:
                if let place, place.skippedAt == nil { place.skippedAt = at }
            case .pending, .ignored:
                break
            }
        }
    }

    /// The deepest story level heard for the buzz (0 when none); nil when the buzz was never logged.
    public func deepestLevelHeard(buzzID: UUID) throws -> Int? {
        try buzzRecord(id: buzzID)?.deepestLevel
    }

    /// Retires the place for good, storing it first if it is unknown (for example when `recordBuzz` failed), so a
    /// skip is never lost. The first skip time is kept.
    public func markSkipped(_ candidate: Candidate, at: Date) throws {
        try saving {
            let place = try upsertWalkPlace(candidate, seenAt: at)
            if place.skippedAt == nil { place.skippedAt = at }
        }
    }

    /// Every pending buzz becomes ignored (walking mode ended without an answer).
    public func closePendingBuzzes() throws {
        let pending = BuzzOutcome.pending.rawValue
        let records = try context.fetch(FetchDescriptor<BuzzRecord>(predicate: #Predicate { $0.outcome == pending }))
        guard !records.isEmpty else { return }
        try saving {
            for record in records { record.outcome = BuzzOutcome.ignored.rawValue }
        }
    }

    /// Upserts the story keyed by `story.id`; its fields are refreshed, except the trip it was first saved in.
    /// Story levels not yet stored are appended, and stored levels are never rewritten. A buzz story stores its
    /// place but does not mark it heard; a stop story stores no place (design 7.6).
    public func saveWalkStory(_ story: WalkStory, tripID: UUID) throws {
        let encoder = JSONEncoder()
        let placeJSON = try story.place.map { try encoder.encode($0) }
        let addressJSON = try story.address.map { try encoder.encode($0) }
        let placeID = story.place?.id
        let existing = try walkStoryRecord(id: story.id)

        try saving {
            let record: WalkStoryRecord
            if let existing {
                record = existing
                record.kind = story.kind.rawValue
                record.placeID = placeID
                record.placeJSON = placeJSON
                record.addressJSON = addressJSON
                record.detail = story.detail
                record.title = story.title
                record.latitude = story.position.latitude
                record.longitude = story.position.longitude
                record.course = story.course
                record.language = story.language.rawValue
                record.createdAt = story.createdAt
            } else {
                record = WalkStoryRecord(
                    id: story.id, kind: story.kind.rawValue, placeID: placeID, placeJSON: placeJSON,
                    addressJSON: addressJSON, detail: story.detail, title: story.title,
                    latitude: story.position.latitude, longitude: story.position.longitude, course: story.course,
                    language: story.language.rawValue, createdAt: story.createdAt, tripID: tripID)
                context.insert(record)
            }

            // As in `save(_ session:)`: placeID is a denormalised copy kept in step; text, level and createdAt
            // are never rewritten.
            let storedLevels = Set(record.stories.map(\.level))
            for stored in record.stories where stored.placeID != placeID { stored.placeID = placeID }
            for (index, text) in story.levels.enumerated() where !storedLevels.contains(index + 1) {
                let level = StoryRecord(level: index + 1, text: text, placeID: placeID,
                                        createdAt: story.createdAt.addingTimeInterval(TimeInterval(index)))
                context.insert(level)
                level.walkStory = record
            }

            // A saved buzz story may never have been played (it is prepared when the buzz goes out), so it does
            // not mark its place heard; `setBuzzOutcome(.heard, ...)` does that once it plays.
            if story.kind == .buzz, let candidate = story.place {
                _ = try upsertWalkPlace(candidate, seenAt: story.createdAt)
            }
        }
    }

    /// Rebuilds a saved walk story; nil when the id is unknown. Throws `corruptRecord` when the record cannot be
    /// read back (bad JSON, unknown kind or language, levels not exactly 1...n).
    public func walkStory(id: UUID) throws -> WalkStory? {
        guard let record = try walkStoryRecord(id: id) else { return nil }
        let decoder = JSONDecoder()
        guard let kind = WalkStory.Kind(rawValue: record.kind),
              let language = StoryLanguage(rawValue: record.language)
        else { throw MemoryError.corruptRecord }
        let place: Candidate?
        let address: Address?
        do {
            place = try record.placeJSON.map { try decoder.decode(Candidate.self, from: $0) }
            address = try record.addressJSON.map { try decoder.decode(Address.self, from: $0) }
        } catch {
            throw MemoryError.corruptRecord
        }
        let stories = record.stories.sorted { $0.level < $1.level }
        guard stories.map(\.level) == stories.indices.map({ $0 + 1 }) else { throw MemoryError.corruptRecord }
        return WalkStory(id: record.id, kind: kind, place: place,
                         position: Coordinate(latitude: record.latitude, longitude: record.longitude),
                         course: record.course, language: language, title: record.title,
                         levels: stories.map(\.text), createdAt: record.createdAt, address: address,
                         detail: record.detail)
    }

    /// Stores each sample as a `TrackPoint` of the trip.
    public func appendTrack(_ samples: [TrackSample], tripID: UUID) throws {
        guard !samples.isEmpty else { return }
        try saving {
            for sample in samples {
                context.insert(TrackPoint(at: sample.at, latitude: sample.coordinate.latitude,
                                          longitude: sample.coordinate.longitude, tripID: tripID))
            }
        }
    }

    /// Every logged buzz, newest first. Throws `corruptRecord` for a stored outcome it cannot read.
    public func buzzLog() throws -> [BuzzLogEntry] {
        let descriptor = FetchDescriptor<BuzzRecord>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        return try context.fetch(descriptor).map { record in
            guard let outcome = BuzzOutcome(rawValue: record.outcome) else { throw MemoryError.corruptRecord }
            return BuzzLogEntry(id: record.id, at: record.at, placeID: record.placeID, placeName: record.placeName,
                                kind: record.kind, tier: record.tier, distance: record.distance, outcome: outcome,
                                deepestLevel: record.deepestLevel)
        }
    }

    // MARK: - Private

    /// Runs `body` and saves; on any error rolls back and rethrows.
    private func saving<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    private func buzzRecord(id: UUID) throws -> BuzzRecord? {
        var descriptor = FetchDescriptor<BuzzRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func walkStoryRecord(id: UUID) throws -> WalkStoryRecord? {
        var descriptor = FetchDescriptor<WalkStoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The stored place for `candidate`, with its name and position refreshed, or a new unheard one.
    private func upsertWalkPlace(_ candidate: Candidate, seenAt: Date) throws -> PlaceRecord {
        if let place = try place(id: candidate.id) {
            place.name = candidate.name
            place.latitude = candidate.coordinate.latitude
            place.longitude = candidate.coordinate.longitude
            place.firstSeenAt = min(place.firstSeenAt, seenAt)
            return place
        }
        let place = PlaceRecord(id: candidate.id, name: candidate.name, latitude: candidate.coordinate.latitude,
                                longitude: candidate.coordinate.longitude, firstSeenAt: seenAt,
                                deepestLevelHeard: 0, lastHeardAt: nil)
        context.insert(place)
        return place
    }
}
