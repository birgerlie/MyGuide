import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

@MainActor @Suite struct DiaryMemoryTests {
    static func store(now: Date = Date(timeIntervalSince1970: 5_000)) throws -> MemoryStore {
        let c = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                   migrationPlan: MemoryMigrationPlan.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return MemoryStore(context: c.mainContext, now: { now })
    }

    static let taken = Date(timeIntervalSince1970: 1_000)

    static func story(dayKey: String = "2026-10-28", summary: String = "A day.",
                      captions: [String: String] = ["library:A": "One", "capture:B": "Two"]) -> DayStory {
        DayStory(dayKey: dayKey, createdAt: Date(timeIntervalSince1970: 2_000), language: .norwegian,
                 summary: summary, captions: captions, photoIDs: ["capture:B", "library:A"], totalPhotos: 2)
    }

    @Test func importStoresDownscaledPhoto() throws {
        let store = try Self.store()
        // 4000x3000 landscape: long side 4000 > 1536, scale 1536/4000 = 0.384 -> 1536 x 1152;
        // thumbnail scale 400/4000 = 0.1 -> 400 x 300.
        let source = TestImages.jpeg(width: 4000, height: 3000)
        let id = try #require(try store.importLibraryPhoto(
            jpeg: source, assetIdentifier: "asset-1", takenAt: Self.taken,
            coordinate: Coordinate(latitude: 48.2, longitude: 16.36)))
        let record = try #require(try store.libraryPhoto(id: id))
        let photo = try #require(ImageProcessing.pixelSize(of: record.photoJPEG))
        let thumb = try #require(ImageProcessing.pixelSize(of: record.thumbnailJPEG))
        #expect(photo.width == 1536 && photo.height == 1152)
        #expect(thumb.width == 400 && thumb.height == 300)
        #expect(record.assetIdentifier == "asset-1" && record.takenAt == Self.taken)
        #expect(record.latitude == 48.2 && record.longitude == 16.36)
        #expect(record.importedAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test func smallPhotoIsNotUpscaledAndMissingCoordinateIsNil() throws {
        let store = try Self.store()
        // 300x200 is below both limits: stays 300 x 200 in both copies.
        let id = try #require(try store.importLibraryPhoto(
            jpeg: TestImages.jpeg(width: 300, height: 200), assetIdentifier: "small", takenAt: Self.taken,
            coordinate: nil))
        let record = try #require(try store.libraryPhoto(id: id))
        let photo = try #require(ImageProcessing.pixelSize(of: record.photoJPEG))
        let thumb = try #require(ImageProcessing.pixelSize(of: record.thumbnailJPEG))
        #expect(photo.width == 300 && photo.height == 200)
        #expect(thumb.width == 300 && thumb.height == 200)
        #expect(record.latitude == nil && record.longitude == nil)
    }

    @Test func reimportIsSkipped() throws {
        let store = try Self.store()
        let jpeg = TestImages.jpeg(width: 100, height: 100)
        let first = try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "same", takenAt: Self.taken, coordinate: nil)
        let second = try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "same", takenAt: Self.taken, coordinate: nil)
        #expect(first != nil)
        #expect(second == nil)
        #expect(try store.context.fetchCount(FetchDescriptor<LibraryPhotoRecord>()) == 1)
        // A different asset is a second photo: 1 + 1 = 2.
        _ = try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "other", takenAt: Self.taken, coordinate: nil)
        #expect(try store.context.fetchCount(FetchDescriptor<LibraryPhotoRecord>()) == 2)
    }

    @Test func hasLibraryPhotoTracksStoredAssets() throws {
        let store = try Self.store()
        let jpeg = TestImages.jpeg(width: 100, height: 100)
        #expect(try !store.hasLibraryPhoto(assetIdentifier: "asset"))
        let id = try #require(try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "asset", takenAt: Self.taken,
                                                           coordinate: nil))
        #expect(try store.hasLibraryPhoto(assetIdentifier: "asset"))
        // Only an exact identifier counts.
        #expect(try !store.hasLibraryPhoto(assetIdentifier: "other"))
        #expect(try !store.hasLibraryPhoto(assetIdentifier: "Asset"))
        #expect(try !store.hasLibraryPhoto(assetIdentifier: ""))
        try store.deleteLibraryPhoto(id: id)
        #expect(try !store.hasLibraryPhoto(assetIdentifier: "asset"))
    }

    @Test func unreadableImageThrowsAndStoresNothing() throws {
        let store = try Self.store()
        #expect(throws: ImageProcessingError.unreadableImage) {
            try store.importLibraryPhoto(jpeg: Data([1, 2, 3]), assetIdentifier: "bad", takenAt: Self.taken, coordinate: nil)
        }
        #expect(try store.context.fetchCount(FetchDescriptor<LibraryPhotoRecord>()) == 0)
    }

    @Test func deleteRemovesPhoto() throws {
        let store = try Self.store()
        let jpeg = TestImages.jpeg(width: 100, height: 100)
        let keep = try #require(try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "keep", takenAt: Self.taken, coordinate: nil))
        let gone = try #require(try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "gone", takenAt: Self.taken, coordinate: nil))
        try store.deleteLibraryPhoto(id: gone)
        #expect(try store.libraryPhoto(id: gone) == nil)
        #expect(try store.libraryPhoto(id: keep) != nil)
        #expect(try store.context.fetchCount(FetchDescriptor<LibraryPhotoRecord>()) == 1)
        // Deleting an unknown id is a no-op.
        try store.deleteLibraryPhoto(id: UUID())
        #expect(try store.context.fetchCount(FetchDescriptor<LibraryPhotoRecord>()) == 1)
        // A deleted asset can be imported again.
        #expect(try store.importLibraryPhoto(jpeg: jpeg, assetIdentifier: "gone", takenAt: Self.taken, coordinate: nil) != nil)
    }

    @Test func dayStoryRoundTripsAndReplaces() throws {
        let store = try Self.store()
        #expect(try store.dayStory(dayKey: "2026-10-28") == nil)
        let first = Self.story()
        try store.saveDayStory(first)
        #expect(try store.dayStory(dayKey: "2026-10-28") == first)
        let second = Self.story(summary: "A better day.", captions: ["capture:B": "Only"])
        try store.saveDayStory(second)
        #expect(try store.dayStory(dayKey: "2026-10-28") == second)
        #expect(try store.context.fetchCount(FetchDescriptor<DayStoryRecord>()) == 1)
        // Another day is separate.
        try store.saveDayStory(Self.story(dayKey: "2026-10-27"))
        #expect(try store.context.fetchCount(FetchDescriptor<DayStoryRecord>()) == 2)
        #expect(try store.dayStory(dayKey: "2026-10-28") == second)
    }

    @Test func corruptDayStoryThrows() throws {
        let store = try Self.store()
        store.context.insert(DayStoryRecord(dayKey: "2026-01-01", createdAt: Self.taken, language: "nb", summary: "s",
                                            captionsJSON: Data("nope".utf8), photoIDs: [], totalPhotos: 0))
        store.context.insert(DayStoryRecord(dayKey: "2026-01-02", createdAt: Self.taken, language: "xx", summary: "s",
                                            captionsJSON: Data("{}".utf8), photoIDs: [], totalPhotos: 0))
        try store.context.save()
        #expect(throws: MemoryError.corruptRecord) { try store.dayStory(dayKey: "2026-01-01") }
        #expect(throws: MemoryError.corruptRecord) { try store.dayStory(dayKey: "2026-01-02") }
    }

    /// Version 2's own plan, ending at V2, so the file written with it is stamped V2 (the real plan ends at V3).
    enum V2OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [MemorySchemaV1.self, MemorySchemaV2.self] }
        static var stages: [MigrationStage] {
            [.lightweight(fromVersion: MemorySchemaV1.self, toVersion: MemorySchemaV2.self)]
        }
    }

    @Test func v2StoreOpensAsV3() throws {
        try MigrationTests.withStoreURL { url in
            let s = MigrationTests.session
            let id = UUID()
            let tripID = UUID()
            let buzz = WalkMemoryTests.buzz("osm:node/1")
            do {
                let v2 = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self),
                                            migrationPlan: V2OnlyPlan.self,
                                            configurations: ModelConfiguration(url: url))
                let store = MemoryStore(context: v2.mainContext)
                try store.save(s)
                try store.saveWalkStory(WalkMemoryTests.stopStory(north: 20, levels: ["stop"], id: id), tripID: tripID)
                _ = try store.touchTrip(now: Date(timeIntervalSince1970: 1_000), city: "Wien")
                try store.recordBuzz(buzz, tripID: tripID, at: Self.taken)
                try store.appendTrack([TrackSample(at: Self.taken, coordinate: Coordinate(latitude: 48.2, longitude: 16.36))],
                                      tripID: tripID)
            }
            let v3 = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                        migrationPlan: MemoryMigrationPlan.self,
                                        configurations: ModelConfiguration(url: url))
            let store = MemoryStore(context: v3.mainContext)
            let captures = try store.context.fetch(FetchDescriptor<CaptureRecord>())
            #expect(captures.count == 1)
            #expect(try store.session(for: try #require(captures.first)) == s)
            #expect(try store.walkStory(id: id)?.levels == ["stop"])
            #expect(try store.context.fetchCount(FetchDescriptor<TripRecord>()) == 1)
            #expect(try store.buzzLog().map(\.id) == [buzz.id])
            #expect(try store.context.fetchCount(FetchDescriptor<TrackPoint>()) == 1)
            let photoID = try #require(try store.importLibraryPhoto(
                jpeg: TestImages.jpeg(width: 50, height: 50), assetIdentifier: "a", takenAt: Self.taken, coordinate: nil))
            #expect(try store.libraryPhoto(id: photoID) != nil)
            try store.saveDayStory(Self.story())
            #expect(try store.dayStory(dayKey: "2026-10-28") != nil)
        }
    }
}
