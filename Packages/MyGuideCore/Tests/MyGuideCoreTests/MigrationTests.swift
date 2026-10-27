import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

/// Opening stores written by earlier schema versions. These run on disk: an in-memory store is never migrated.
@MainActor @Suite struct MigrationTests {
    /// A fresh temp directory with the store URL inside it; `body` runs, then the directory is removed.
    static func withStoreURL(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MyGuideMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("memory.store"))
    }

    /// Writes one place and one capture with one story through the frozen V1 models. The container goes out of
    /// scope at the end, so the store file is closed before it is reopened.
    static let session = MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one"], at: 10)

    static func writeV1Store(at url: URL, schema: Schema) throws {
        let s = session
        let encoder = JSONEncoder()
        let v1 = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        let context = v1.mainContext
        context.insert(MemorySchemaV1.PlaceRecord(id: "osm:node/1", name: "Gate", latitude: 48.2, longitude: 16.36,
                                                  firstSeenAt: Date(timeIntervalSince1970: 10), deepestLevelHeard: 1,
                                                  lastHeardAt: Date(timeIntervalSince1970: 20)))
        // Written the way phase 1's MemoryStore.save wrote a session.
        let capture = MemorySchemaV1.CaptureRecord(
            id: s.id, takenAt: s.capture.takenAt, latitude: 0, longitude: 0, placeID: "osm:node/1",
            title: s.identified.title, subject: s.identified.subject, language: s.language.rawValue,
            photoJPEG: s.photoJPEG, thumbnailJPEG: s.thumbnailJPEG, captureJSON: try encoder.encode(s.capture),
            groundingJSON: try encoder.encode(s.grounding), identifiedJSON: try encoder.encode(s.identified))
        context.insert(capture)
        let story = MemorySchemaV1.StoryRecord(level: 1, text: s.levels[0], placeID: "osm:node/1",
                                               createdAt: s.capture.takenAt)
        context.insert(story)
        story.capture = capture
        try context.save()
    }

    static func expectMigrated(at url: URL) throws {
        let v2 = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self), migrationPlan: MemoryMigrationPlan.self,
                                    configurations: ModelConfiguration(url: url))
        let context = v2.mainContext
        let places = try context.fetch(FetchDescriptor<PlaceRecord>())
        #expect(places.count == 1)
        let place = try #require(places.first)
        #expect(place.id == "osm:node/1" && place.name == "Gate" && place.deepestLevelHeard == 1)
        #expect(place.lastHeardAt == Date(timeIntervalSince1970: 20))
        #expect(place.skippedAt == nil && place.lastBuzzedAt == nil && place.lastBuzzTripID == nil)
        let captures = try context.fetch(FetchDescriptor<CaptureRecord>())
        #expect(captures.count == 1)
        let capture = try #require(captures.first)
        #expect(capture.stories.count == 1)
        let story = try #require(capture.stories.first)
        #expect(story.text == "one" && story.level == 1 && story.walkStory == nil && story.capture === capture)
        #expect(try context.fetchCount(FetchDescriptor<TripRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BuzzRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TrackPoint>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WalkStoryRecord>()) == 0)

        // The migrated store reads phase 1 sessions back and takes phase 2 writes; the old place can be retired.
        let store = MemoryStore(context: context)
        #expect(try store.session(for: capture) == session)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: Coordinate(latitude: 0, longitude: 0),
                                       excludingSession: nil).map(\.text) == ["one"])
        let trip = try store.touchTrip(now: Date(timeIntervalSince1970: 1_000), city: "Wien")
        try store.markSkipped(Candidate(id: "osm:node/1", name: "Gate", coordinate: Coordinate(latitude: 48.2, longitude: 16.36),
                                        kind: "historic=city_gate"), at: Date(timeIntervalSince1970: 1_000))
        #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
        #expect(try context.fetchCount(FetchDescriptor<TripRecord>()) == 1 && trip.city == "Wien")
    }

    @Test func v1StoreOpensAsV2() throws {
        try Self.withStoreURL { url in
            try Self.writeV1Store(at: url, schema: Schema(versionedSchema: MemorySchemaV1.self))
            try Self.expectMigrated(at: url)
        }
    }

    /// Phase 1 device builds before the versioned schema wrote an unversioned store of the same four models.
    @Test func unversionedPhase1StoreOpensAsV2() throws {
        try Self.withStoreURL { url in
            try Self.writeV1Store(at: url, schema: Schema(MemorySchemaV1.models))
            try Self.expectMigrated(at: url)
        }
    }

    /// `Fixtures/phase1-memory.store` was written by the phase 1 code itself (commit 2df0edb, `MemoryStore.save` of
    /// `MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one", "two"], at: 10)` with the id below), so it
    /// fails if the frozen `MemorySchemaV1` copies drift from what phase 1 shipped: SwiftData then reports
    /// "Cannot use staged migration with an unknown model version". The other tests write through the frozen copies
    /// and cannot catch that.
    @Test func storeWrittenByPhase1CodeOpensAsV2() throws {
        let fixture = try #require(Bundle.module.url(forResource: "phase1-memory", withExtension: "store",
                                                     subdirectory: "Fixtures"))
        try Self.withStoreURL { url in
            try FileManager.default.copyItem(at: fixture, to: url)
            let v2 = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self),
                                        migrationPlan: MemoryMigrationPlan.self, configurations: ModelConfiguration(url: url))
            let store = MemoryStore(context: v2.mainContext)
            let captures = try store.context.fetch(FetchDescriptor<CaptureRecord>())
            #expect(captures.count == 1)
            let session = try store.session(for: try #require(captures.first))
            #expect(session.id == UUID(uuidString: "1B3EB1F9-6FD1-4920-BF00-A30E1DA26A74"))
            #expect(session.levels == ["one", "two"] && session.language == .english)
            #expect(session.identified.title == "T" && session.identified.subject == "Gate")
            #expect(session.capture.takenAt == Date(timeIntervalSince1970: 10))
            #expect(session.matchedCandidate?.candidate.id == "osm:node/1")
            #expect(captures.first?.stories.allSatisfy { $0.walkStory == nil } == true)
            let place = try #require(try store.place(id: "osm:node/1"))
            #expect(place.name == "Gate" && place.deepestLevelHeard == 2)
            #expect(place.skippedAt == nil && place.lastBuzzedAt == nil && place.lastBuzzTripID == nil)
            #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
            #expect(try store.context.fetchCount(FetchDescriptor<TripRecord>()) == 0)
        }
    }

    @Test func migratedStoreReopensWithoutAnotherMigration() throws {
        try Self.withStoreURL { url in
            try Self.writeV1Store(at: url, schema: Schema(versionedSchema: MemorySchemaV1.self))
            try Self.expectMigrated(at: url)
            let again = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self),
                                           migrationPlan: MemoryMigrationPlan.self, configurations: ModelConfiguration(url: url))
            #expect(try again.mainContext.fetchCount(FetchDescriptor<TripRecord>()) == 1)
            #expect(try again.mainContext.fetchCount(FetchDescriptor<CaptureRecord>()) == 1)
        }
    }

    @Test func schemaVersionsAndPlan() {
        #expect(MemorySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(MemorySchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(MemorySchemaV1.models.map { ObjectIdentifier($0) } == [
            ObjectIdentifier(MemorySchemaV1.CaptureRecord.self), ObjectIdentifier(MemorySchemaV1.StoryRecord.self),
            ObjectIdentifier(MemorySchemaV1.PlaceRecord.self), ObjectIdentifier(MemorySchemaV1.UsageRecord.self),
        ])
        #expect(MemorySchemaV2.models.map { ObjectIdentifier($0) } == MemorySchema.models.map { ObjectIdentifier($0) })
        let live: [any PersistentModel.Type] = [
            CaptureRecord.self, StoryRecord.self, PlaceRecord.self, UsageRecord.self,
            TripRecord.self, BuzzRecord.self, TrackPoint.self, WalkStoryRecord.self,
        ]
        #expect(MemorySchema.models.map { ObjectIdentifier($0) } == live.map { ObjectIdentifier($0) })
        #expect(MemoryMigrationPlan.schemas.map { ObjectIdentifier($0) }
                == [ObjectIdentifier(MemorySchemaV1.self), ObjectIdentifier(MemorySchemaV2.self)])
        #expect(MemoryMigrationPlan.stages.count == 1)
    }

    /// The app's fallback: V2 with the plan, in memory.
    @Test func v2WithPlanWorksInMemory() throws {
        let c = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self), migrationPlan: MemoryMigrationPlan.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = MemoryStore(context: c.mainContext)
        let s = MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s)
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        #expect(try store.session(for: rec) == s)
        #expect(try store.touchTrip(now: Date(timeIntervalSince1970: 0), city: nil).city == nil)
    }
}
