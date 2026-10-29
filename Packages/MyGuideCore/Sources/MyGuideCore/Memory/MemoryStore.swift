import Foundation
import SwiftData

/// Estimated spend, from the stored `UsageRecord`s.
public struct UsageTotals: Equatable, Sendable {
    public var monthUSD: Double
    public var allTimeUSD: Double
    /// Requests recorded in the current calendar month.
    public var monthRequests: Int
    /// Requests this month whose cost could not be estimated (unknown model).
    public var unpricedRequests: Int

    public init(monthUSD: Double, allTimeUSD: Double, monthRequests: Int, unpricedRequests: Int) {
        self.monthUSD = monthUSD
        self.allTimeUSD = allTimeUSD
        self.monthRequests = monthRequests
        self.unpricedRequests = unpricedRequests
    }
}

public enum MemoryError: Error, Equatable {
    /// The session has no coordinate; the store never writes a record at 0,0.
    case noPosition
    /// A stored record could not be turned back into a session (bad JSON, unknown language, missing level).
    case corruptRecord
}

/// The on-device memory of places, captures, stories, trips and buzzes (spec 8.2, design 7.7).
@MainActor public final class MemoryStore {
    /// Metres around the capture point within which unidentified captures count as the same spot.
    public static let priorRadius = 75.0
    /// The most prior stories handed to a story request.
    public static let priorLimit = 12
    /// Metres per degree of latitude (and of longitude at the equator) on the GeoMath sphere: 6_371_000 · π / 180.
    nonisolated static let metresPerDegree = 111_195.0

    public let context: ModelContext
    /// A ModelContext does not keep its container alive, and fetching after the container is gone traps.
    /// Holding it here lets callers pass just a context (for example `container.mainContext` of a local container).
    private let container: ModelContainer
    /// The clock a newly stored story level is stamped with (`StoryRecord.createdAt`).
    let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.container = context.container
        self.now = now
    }

    /// Upserts the session keyed by `session.id`. The capture's blobs and denormalised fields are refreshed;
    /// story levels not yet stored are appended, and stored levels are never rewritten.
    public func save(_ session: StorySession) throws {
        guard let coordinate = session.capture.coordinate else { throw MemoryError.noPosition }
        let encoder = JSONEncoder()
        let captureJSON = try encoder.encode(session.capture)
        let groundingJSON = try encoder.encode(session.grounding)
        let identifiedJSON = try encoder.encode(session.identified)
        let placeID = session.matchedCandidate?.candidate.id

        do {
            let record: CaptureRecord
            if let existing = try captureRecord(id: session.id) {
                record = existing
                record.takenAt = session.capture.takenAt
                record.latitude = coordinate.latitude
                record.longitude = coordinate.longitude
                record.placeID = placeID
                record.title = session.identified.title
                record.subject = session.identified.subject
                record.language = session.language.rawValue
                if record.photoJPEG != session.photoJPEG { record.photoJPEG = session.photoJPEG }
                if record.thumbnailJPEG != session.thumbnailJPEG { record.thumbnailJPEG = session.thumbnailJPEG }
                record.captureJSON = captureJSON
                record.groundingJSON = groundingJSON
                record.identifiedJSON = identifiedJSON
            } else {
                record = CaptureRecord(
                    id: session.id, takenAt: session.capture.takenAt, latitude: coordinate.latitude,
                    longitude: coordinate.longitude, placeID: placeID, title: session.identified.title,
                    subject: session.identified.subject, language: session.language.rawValue,
                    photoJPEG: session.photoJPEG, thumbnailJPEG: session.thumbnailJPEG, captureJSON: captureJSON,
                    groundingJSON: groundingJSON, identifiedJSON: identifiedJSON)
                context.insert(record)
            }

            // Stored text, level and createdAt are never rewritten. placeID is a denormalised copy of the
            // capture's and is kept in step, so a story is found by exactly one of the two prior queries.
            // A new level is stamped with when it was written, not when the photo was taken (an imported photo can
            // be years old); levels written in the same save share the time and are ordered by level.
            let storedLevels = Set(record.stories.map(\.level))
            for story in record.stories where story.placeID != placeID { story.placeID = placeID }
            var appended = false
            let writtenAt = now()
            for (index, text) in session.levels.enumerated() where !storedLevels.contains(index + 1) {
                let story = StoryRecord(level: index + 1, text: text, placeID: placeID, createdAt: writtenAt)
                context.insert(story)
                story.capture = record
                appended = true
            }

            if let candidate = session.matchedCandidate?.candidate {
                try upsertPlace(candidate, takenAt: session.capture.takenAt, deepestLevel: session.levels.count,
                                heardNow: appended)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Rebuilds the session a record was saved from.
    public func session(for record: CaptureRecord) throws -> StorySession {
        let decoder = JSONDecoder()
        guard let capture = try? decoder.decode(CaptureContext.self, from: record.captureJSON),
              let grounding = try? decoder.decode(Grounding.self, from: record.groundingJSON),
              let identified = try? decoder.decode(IdentifiedStory.self, from: record.identifiedJSON),
              let language = StoryLanguage(rawValue: record.language)
        else { throw MemoryError.corruptRecord }
        let stories = record.stories.sorted { $0.level < $1.level }
        // Levels must be exactly 1...n; a gap would shift every later level down.
        guard stories.map(\.level) == stories.indices.map({ $0 + 1 }) else {
            throw MemoryError.corruptRecord
        }
        return StorySession(id: record.id, capture: capture, photoJPEG: record.photoJPEG,
                            thumbnailJPEG: record.thumbnailJPEG, language: language, grounding: grounding,
                            identified: identified, levels: stories.map(\.text))
    }

    /// Attaches the "then" image to a saved session, replacing any earlier one.
    /// Throws `corruptRecord` when the session was never saved: there is nothing to attach to.
    public func saveThenImage(_ png: Data, sessionID: UUID) throws {
        guard let record = try captureRecord(id: sessionID) else { throw MemoryError.corruptRecord }
        do {
            record.thenImagePNG = png
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// The stored "then" image of a session; nil when there is none or the session is unknown.
    public func thenImage(sessionID: UUID) throws -> Data? {
        try captureRecord(id: sessionID)?.thenImagePNG
    }

    /// Stories already told about any of `placeIDs` (anywhere, photo or buzz), plus stories from unidentified captures
    /// and stop stories within `priorRadius` of `near`, excluding the capture or walk story `excludingSession`;
    /// newest first, at most `priorLimit`. A buzz story is saved when its buzz goes out, before anyone listens, so a
    /// buzz story level counts only once its buzz log entry has heard that deep (`BuzzRecord.deepestLevel`, the buzz
    /// sharing the story's id); without a log entry none of its levels count. Photo, stop and chosen story levels always count
    /// (a chosen story is found by its place like a photo story).
    public func priorStories(placeIDs: [String], near: Coordinate, excludingSession: UUID?) throws -> [PriorStory] {
        var stories: [StoryRecord] = []

        let ids = placeIDs.filter { !$0.isEmpty }
        if !ids.isEmpty {
            // Written as a nil check plus force unwrap because SwiftData's SQL generation rejects
            // `ids.contains(story.placeID ?? "")` with an uncaught exception ("bad LHS"), which traps.
            let byPlace = FetchDescriptor<StoryRecord>(predicate: #Predicate { story in
                story.placeID != nil && ids.contains(story.placeID!)
            })
            stories += try context.fetch(byPlace)
        }

        for capture in try unidentifiedCaptures(near: near) {
            stories += capture.stories
        }
        for walkStory in try stopStories(near: near) {
            stories += walkStory.stories
        }

        let buzzKind = WalkStory.Kind.buzz.rawValue
        let buzzStoryIDs = Array(Set(stories.compactMap { $0.walkStory }.filter { $0.kind == buzzKind }.map(\.id)))
        var heardDepth: [UUID: Int] = [:]
        if !buzzStoryIDs.isEmpty {
            let buzzes = FetchDescriptor<BuzzRecord>(predicate: #Predicate { buzzStoryIDs.contains($0.id) })
            for buzz in try context.fetch(buzzes) { heardDepth[buzz.id] = buzz.deepestLevel }
        }

        return stories
            .filter { story in
                guard let walkStory = story.walkStory, walkStory.kind == buzzKind else { return true }
                return story.level <= heardDepth[walkStory.id, default: 0]
            }
            .filter { excludingSession == nil || ($0.capture?.id != excludingSession && $0.walkStory?.id != excludingSession) }
            .sorted { ($0.createdAt, $0.level) > ($1.createdAt, $1.level) }
            .prefix(Self.priorLimit)
            .compactMap { story in
                StoryLevel(rawValue: story.level).map {
                    PriorStory(placeID: story.placeID, level: $0, text: story.text, toldAt: story.createdAt)
                }
            }
    }

    /// Story levels created at or after `since`, newest first, at most `RecentStories.limit`: photo levels; stop story
    /// levels; buzz levels up to the buzz's `deepestLevel`; and level 1 of a buzz that is still `pending` with
    /// `deepestLevel` 0, marked prepared (a buzz story is saved when its buzz goes out and stays pending until heard,
    /// skipped or ignored). A buzz story without a log entry counts as neither and is left out. Excludes the capture or
    /// walk story `excludingSession`.
    public func recentStories(since: Date, excludingSession: UUID?) throws -> [RecentStory] {
        // Only the date goes into the predicate; SwiftData's SQL generation rejects richer forms.
        let fetched = try context.fetch(FetchDescriptor<StoryRecord>(predicate: #Predicate { $0.createdAt >= since }))

        let buzzKind = WalkStory.Kind.buzz.rawValue
        let buzzStoryIDs = Array(Set(fetched.compactMap { $0.walkStory }.filter { $0.kind == buzzKind }.map(\.id)))
        var buzzes: [UUID: BuzzRecord] = [:]
        if !buzzStoryIDs.isEmpty {
            let descriptor = FetchDescriptor<BuzzRecord>(predicate: #Predicate { buzzStoryIDs.contains($0.id) })
            for buzz in try context.fetch(descriptor) { buzzes[buzz.id] = buzz }
        }
        let pending = BuzzOutcome.pending.rawValue

        return fetched
            .filter { excludingSession == nil || ($0.capture?.id != excludingSession && $0.walkStory?.id != excludingSession) }
            // Text breaks ties so the order (and so the request) does not depend on the fetch order.
            .sorted { ($0.createdAt, $0.level, $0.text) > ($1.createdAt, $1.level, $1.text) }
            .compactMap { story -> RecentStory? in
                guard let level = StoryLevel(rawValue: story.level) else { return nil }
                if let capture = story.capture {
                    return RecentStory(toldAt: story.createdAt, placeName: capture.subject, level: level, text: story.text, prepared: false)
                }
                guard let walkStory = story.walkStory else { return nil }
                guard walkStory.kind == buzzKind else {
                    // A chosen story has no buzz record: every level counts as told, under the stored place's name.
                    let name = walkStory.kind == WalkStory.Kind.chosen.rawValue
                        ? walkStory.placeJSON.flatMap { try? JSONDecoder().decode(Candidate.self, from: $0) }?.name : nil
                    return RecentStory(toldAt: story.createdAt, placeName: name, level: level, text: story.text, prepared: false)
                }
                guard let buzz = buzzes[walkStory.id] else { return nil }
                if story.level <= buzz.deepestLevel {
                    return RecentStory(toldAt: story.createdAt, placeName: buzz.placeName, level: level, text: story.text, prepared: false)
                }
                if buzz.outcome == pending, buzz.deepestLevel == 0, story.level == 1 {
                    return RecentStory(toldAt: story.createdAt, placeName: buzz.placeName, level: level, text: story.text, prepared: true)
                }
                return nil
            }
            .prefix(RecentStories.limit)
            .map { $0 }
    }

    /// Deletes a capture (its stories cascade) and, in the same save, its `PlaceRecord` when nothing else needs it: no
    /// other capture refers to the place and walking mode has no history with it (`hasWalkHistory`), because the place
    /// is what keeps a skipped or heard place from buzzing again. A failed save rolls back and rethrows.
    public func deleteCapture(_ record: CaptureRecord) throws {
        let id = record.id
        let placeID = record.placeID
        do {
            context.delete(record)
            if let placeID, let place = try place(id: placeID) {
                let others = FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.placeID == placeID && $0.id != id })
                if try context.fetchCount(others) == 0, try !hasWalkHistory(place) {
                    context.delete(place)
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// True when walking mode has touched the place: it was skipped or buzzed, a buzz about it was heard or skipped,
    /// or a walk story about it was saved.
    func hasWalkHistory(_ place: PlaceRecord) throws -> Bool {
        if place.skippedAt != nil || place.lastBuzzedAt != nil { return true }
        let id = place.id
        let heard = BuzzOutcome.heard.rawValue, skipped = BuzzOutcome.skipped.rawValue
        let answered = FetchDescriptor<BuzzRecord>(predicate: #Predicate { buzz in
            buzz.placeID == id && (buzz.outcome == heard || buzz.outcome == skipped)
        })
        if try context.fetchCount(answered) > 0 { return true }
        let walkStories = FetchDescriptor<WalkStoryRecord>(predicate: #Predicate { $0.placeID == id })
        return try context.fetchCount(walkStories) > 0
    }

    public func place(id: String) throws -> PlaceRecord? {
        var descriptor = FetchDescriptor<PlaceRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Stores one `UsageRecord` per entry, with its cost estimated now, and saves at once. Saves itself rather
    /// than relying on autosave; a failed save rolls back and rethrows.
    public func recordUsage(_ entries: [UsageEntry], prices: PriceTable) throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            context.insert(UsageRecord(date: entry.date, kind: entry.kind.rawValue, model: entry.model,
                                       inputTokens: entry.inputTokens, outputTokens: entry.outputTokens,
                                       words: entry.words, images: entry.images,
                                       estimatedUSD: prices.estimatedUSD(entry)))
        }
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
    }

    /// Spend this calendar month (in `calendar`) and over all time.
    public func usageTotals(now: Date = Date(), calendar: Calendar = .current) throws -> UsageTotals {
        // Half-open [start, end): DateInterval.contains would include the first instant of the next month.
        let month = calendar.dateInterval(of: .month, for: now)
        var totals = UsageTotals(monthUSD: 0, allTimeUSD: 0, monthRequests: 0, unpricedRequests: 0)
        for record in try context.fetch(FetchDescriptor<UsageRecord>()) {
            totals.allTimeUSD += record.estimatedUSD ?? 0
            if let month, record.date >= month.start && record.date < month.end {
                totals.monthRequests += 1
                totals.monthUSD += record.estimatedUSD ?? 0
                if record.estimatedUSD == nil { totals.unpricedRequests += 1 }
            }
        }
        return totals
    }

    // MARK: - Private

    private func captureRecord(id: UUID) throws -> CaptureRecord? {
        var descriptor = FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func upsertPlace(_ candidate: Candidate, takenAt: Date, deepestLevel: Int, heardNow: Bool) throws {
        let heardAt = now()
        if let place = try place(id: candidate.id) {
            place.name = candidate.name
            place.latitude = candidate.coordinate.latitude
            place.longitude = candidate.coordinate.longitude
            place.firstSeenAt = min(place.firstSeenAt, takenAt)
            place.deepestLevelHeard = max(place.deepestLevelHeard, deepestLevel)
            if heardNow { place.lastHeardAt = heardAt }
        } else {
            context.insert(PlaceRecord(id: candidate.id, name: candidate.name,
                                       latitude: candidate.coordinate.latitude,
                                       longitude: candidate.coordinate.longitude, firstSeenAt: takenAt,
                                       deepestLevelHeard: deepestLevel, lastHeardAt: deepestLevel > 0 ? heardAt : nil))
        }
    }

    /// A latitude/longitude box around a point that contains every point within `priorRadius` of it.
    private struct NearBox {
        var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
        /// False when the box wraps the antimeridian (or spans all longitudes): then bound by latitude only.
        var boundsLongitude: Bool { minLon >= -180 && maxLon <= 180 }

        init(around point: Coordinate, radius: Double) {
            let latSpan = radius / MemoryStore.metresPerDegree
            minLat = point.latitude - latSpan
            maxLat = point.latitude + latSpan
            // A degree of longitude shrinks with cos φ and vanishes at the poles, where the division would blow up
            // to infinity. Any span of 180° or more already covers every longitude, so clamp there.
            let cosLat = cos(point.latitude * .pi / 180)
            let lonSpan = cosLat > 0 ? min(180, radius / (MemoryStore.metresPerDegree * cosLat)) : 180
            minLon = point.longitude - lonSpan
            maxLon = point.longitude + lonSpan
        }
    }

    /// Captures with no place ID within `priorRadius` of `point`. The fetch is bounded by a box around the point;
    /// the exact distance is checked in Swift.
    private func unidentifiedCaptures(near point: Coordinate) throws -> [CaptureRecord] {
        let radius = Self.priorRadius
        let box = NearBox(around: point, radius: radius)
        let (minLat, maxLat, minLon, maxLon) = (box.minLat, box.maxLat, box.minLon, box.maxLon)
        let predicate: Predicate<CaptureRecord>
        if box.boundsLongitude {
            predicate = #Predicate { c in
                c.placeID == nil && c.latitude >= minLat && c.latitude <= maxLat
                    && c.longitude >= minLon && c.longitude <= maxLon
            }
        } else {
            predicate = #Predicate { c in
                c.placeID == nil && c.latitude >= minLat && c.latitude <= maxLat
            }
        }
        return try context.fetch(FetchDescriptor(predicate: predicate)).filter {
            GeoMath.distance(point, Coordinate(latitude: $0.latitude, longitude: $0.longitude)) <= radius
        }
    }

    /// Stop stories (walk stories with no place ID) told within `priorRadius` of `point`; bounded like
    /// `unidentifiedCaptures`.
    private func stopStories(near point: Coordinate) throws -> [WalkStoryRecord] {
        let radius = Self.priorRadius
        let box = NearBox(around: point, radius: radius)
        let (minLat, maxLat, minLon, maxLon) = (box.minLat, box.maxLat, box.minLon, box.maxLon)
        let predicate: Predicate<WalkStoryRecord>
        if box.boundsLongitude {
            predicate = #Predicate { w in
                w.placeID == nil && w.latitude >= minLat && w.latitude <= maxLat
                    && w.longitude >= minLon && w.longitude <= maxLon
            }
        } else {
            predicate = #Predicate { w in
                w.placeID == nil && w.latitude >= minLat && w.latitude <= maxLat
            }
        }
        return try context.fetch(FetchDescriptor(predicate: predicate)).filter {
            GeoMath.distance(point, Coordinate(latitude: $0.latitude, longitude: $0.longitude)) <= radius
        }
    }
}
