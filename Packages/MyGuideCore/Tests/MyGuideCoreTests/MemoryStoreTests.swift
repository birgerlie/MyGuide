import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

@MainActor @Suite struct MemoryStoreTests {
    let store: MemoryStore
    /// Stamps every story level the suite's store writes; tests about order move it.
    let clock = WalkMemoryTests.Clock(Date(timeIntervalSince1970: 0))
    init() throws {
        store = try WalkMemoryTests.clockedStore(clock)
    }
    // 1 m of latitude = 1/111_195 degree
    static func session(placeID: String?, n metres: Double = 0, levels: [String], at t: TimeInterval = 0) -> StorySession {
        let cand = RankedCandidate(candidate: Candidate(id: placeID ?? "osm:node/x", name: "Gate", coordinate: .init(latitude: 0, longitude: 0),
                                   kind: "historic=yes", summary: nil, wikipediaTitle: nil, wikidata: nil), distance: 10, bearing: 0, inView: true)
        return StorySession(id: UUID(),
            capture: CaptureContext(coordinate: .init(latitude: metres / 111_195, longitude: 0), horizontalAccuracy: 5, heading: nil,
                                    headingAccuracy: nil, horizontalFOV: 55, takenAt: Date(timeIntervalSince1970: t), source: .camera),
            photoJPEG: Data([2]), thumbnailJPEG: Data([1]), language: .english, grounding: Grounding(candidates: [cand], address: nil, failedSources: []),
            identified: IdentifiedStory(subject: "Gate", confidence: .likely, matchedCandidateID: placeID, title: "T", era: "E", story: levels[0]),
            levels: levels)
    }
    static let origin = Coordinate(latitude: 0, longitude: 0)

    // Schema versions and migration: MigrationTests.

    @Test func saveAndRestoreRoundTrips() throws {
        let s = Self.session(placeID: "osm:node/1", levels: ["one", "two"])
        try store.save(s)
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        #expect(try store.session(for: rec) == s)
    }
    @Test func saveIsIdempotentAndAppendsNewLevels() throws {
        var s = Self.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s); s.levels.append("two"); try store.save(s); try store.save(s)
        #expect(try store.context.fetch(FetchDescriptor<StoryRecord>()).map(\.level).sorted() == [1, 2])
        #expect(try store.context.fetchCount(FetchDescriptor<CaptureRecord>()) == 1)
        #expect(try store.place(id: "osm:node/1")?.deepestLevelHeard == 2)
    }
    @Test func priorsByPlaceIDAnywhere() throws {
        try store.save(Self.session(placeID: "osm:node/1", n: 5_000, levels: ["far but same place"]))
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: Self.origin, excludingSession: nil)
        #expect(p.map(\.text) == ["far but same place"])
    }
    @Test func unidentifiedPriorsOnlyWithinRadius() throws {
        // 40 m north = 0.0003597°, 200 m = 0.0017986°; radius 75 m
        try store.save(Self.session(placeID: nil, n: 40, levels: ["near unknown"]))
        try store.save(Self.session(placeID: nil, n: 200, levels: ["far unknown"]))
        let p = try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil)
        #expect(p.map(\.text) == ["near unknown"] && p[0].placeID == nil)
    }
    @Test func thenImageRoundTrips() throws {
        let s = Self.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s)
        #expect(try store.thenImage(sessionID: s.id) == nil)
        try store.saveThenImage(Data([9, 9]), sessionID: s.id)
        #expect(try store.thenImage(sessionID: s.id) == Data([9, 9]))
        #expect(try store.thenImage(sessionID: UUID()) == nil)
        // Saving the session again must not drop the image.
        try store.save(s)
        #expect(try store.thenImage(sessionID: s.id) == Data([9, 9]))
    }
    @Test func saveThenImageForUnknownSessionThrowsCorruptRecord() {
        #expect(throws: MemoryError.corruptRecord) { try store.saveThenImage(Data([1]), sessionID: UUID()) }
    }
    @Test func saveWithoutCoordinateThrows() {
        var s = Self.session(placeID: nil, levels: ["x"]); s.capture.coordinate = nil
        #expect(throws: MemoryError.noPosition) { try store.save(s) }
    }
    @Test func excludesCurrentSessionAndCapsNewestTwelve() throws {
        let current = Self.session(placeID: "osm:node/1", levels: ["mine"], at: 999)
        clock.date = Date(timeIntervalSince1970: 999)
        try store.save(current)
        for i in 0..<15 {
            clock.date = Date(timeIntervalSince1970: Double(i))
            try store.save(Self.session(placeID: "osm:node/1", levels: ["s\(i)"], at: Double(i)))
        }
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: Self.origin, excludingSession: current.id)
        #expect(p.count == 12 && p.first?.text == "s14" && !p.contains { $0.text == "mine" })
    }

    // MARK: - Rulings and edge cases beyond the brief

    @Test func corruptGroundingJSONThrowsCorruptRecord() throws {
        try store.save(Self.session(placeID: "osm:node/1", levels: ["one"]))
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        rec.groundingJSON = Data("not json".utf8)
        #expect(throws: MemoryError.corruptRecord) { try store.session(for: rec) }
    }
    @Test func unknownLanguageThrowsCorruptRecord() throws {
        try store.save(Self.session(placeID: "osm:node/1", levels: ["one"]))
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        rec.language = "xx"
        #expect(throws: MemoryError.corruptRecord) { try store.session(for: rec) }
    }
    @Test func resaveRefreshesBlobsButNeverRewritesStoredLevels() throws {
        var s = Self.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s)
        s.identified.title = "New title"
        s.identified.subject = "New subject"
        s.grounding.address = Address(line: "Platz", city: "Wien", country: nil)
        s.levels[0] = "rewritten"
        s.levels.append("two")
        try store.save(s)
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        #expect(rec.title == "New title" && rec.subject == "New subject")
        let restored = try store.session(for: rec)
        #expect(restored.grounding.address?.city == "Wien")
        #expect(restored.identified.title == "New title")
        #expect(restored.levels == ["one", "two"])
    }
    @Test func resaveWithChangedMatchMovesStoriesToTheNewPlace() throws {
        var s = Self.session(placeID: "osm:node/1", levels: ["one"])
        try store.save(s)
        s.identified.matchedCandidateID = nil   // no longer tied to a known place
        try store.save(s)
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        #expect(rec.placeID == nil)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: Coordinate(latitude: 10, longitude: 10), excludingSession: nil).isEmpty)
        #expect(try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil).map(\.text) == ["one"])
    }
    @Test func mixedQueryReturnsEachStoryOnceNewestFirst() throws {
        // Place match far away (5 km), unidentified capture 10 m away, unrelated place 10 m away (not asked for).
        clock.date = Date(timeIntervalSince1970: 100)
        try store.save(Self.session(placeID: "osm:node/1", n: 5_000, levels: ["place a", "place b"], at: 100))
        clock.date = Date(timeIntervalSince1970: 200)
        try store.save(Self.session(placeID: nil, n: 10, levels: ["nearby"], at: 200))
        clock.date = Date(timeIntervalSince1970: 300)
        try store.save(Self.session(placeID: "osm:node/2", n: 10, levels: ["other place"], at: 300))
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: Self.origin, excludingSession: nil)
        // createdAt = written at: nearby = 200 s; place a and b both 100 s (one save), level 2 (b) first.
        #expect(p.map(\.text) == ["nearby", "place b", "place a"])
        #expect(p.map(\.level) == [.first, .more, .first])
        #expect(p.map(\.placeID) == [nil, "osm:node/1", "osm:node/1"])
        #expect(p.map(\.toldAt) == [Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100)])
    }
    @Test func emptyPlaceIDsAndNoNearbyCapturesGiveNoPriors() throws {
        try store.save(Self.session(placeID: "osm:node/1", levels: ["at origin but identified"]))
        #expect(try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil).isEmpty)
        #expect(try store.priorStories(placeIDs: [""], near: Self.origin, excludingSession: nil).isEmpty)
    }
    @Test func nearQueryWorksAtThePole() throws {
        // At 89.9999° a point is 0.0001° · 111_195 = 11.12 m from the pole, so longitudes 0 and 179 are
        // ≈ 2 · 11.12 · sin(179°/2) ≈ 22.24 m apart, inside 75 m. cos φ = 1.745e-6 would give a longitude span of
        // 75 / (111_195 · 1.745e-6) ≈ 386°, clamped to 180°. Latitude 89.9 is 0.0999° · 111_195 ≈ 11.1 km away.
        var near = Self.session(placeID: nil, levels: ["across the pole"])
        near.capture.coordinate = Coordinate(latitude: 89.9999, longitude: 179)
        var far = Self.session(placeID: nil, levels: ["far from pole"])
        far.capture.coordinate = Coordinate(latitude: 89.9, longitude: 0)
        try store.save(near); try store.save(far)
        let poleP = try store.priorStories(placeIDs: [], near: Coordinate(latitude: 89.9999, longitude: 0), excludingSession: nil)
        #expect(poleP.map(\.text) == ["across the pole"])
        let exactPole = try store.priorStories(placeIDs: [], near: Coordinate(latitude: 90, longitude: 0), excludingSession: nil)
        #expect(exactPole.map(\.text) == ["across the pole"])
    }
    @Test func nearQueryWorksAcrossTheAntimeridian() throws {
        // (0, 179.9999) to (0, -179.9999) is 0.0002° of longitude at the equator = 0.0002 · 111_195 = 22.24 m.
        // The box half-width is 75 / 111_195 = 0.000674°, so it reaches 180.00057° and wraps.
        var across = Self.session(placeID: nil, levels: ["across the line"])
        across.capture.coordinate = Coordinate(latitude: 0, longitude: -179.9999)
        var sameLatitudeFar = Self.session(placeID: nil, levels: ["same latitude, far"])
        sameLatitudeFar.capture.coordinate = Coordinate(latitude: 0, longitude: 0)
        try store.save(across); try store.save(sameLatitudeFar)
        let p = try store.priorStories(placeIDs: [], near: Coordinate(latitude: 0, longitude: 179.9999), excludingSession: nil)
        #expect(p.map(\.text) == ["across the line"])
    }
    @Test func radiusSplitsBetween74And76Metres() throws {
        try store.save(Self.session(placeID: nil, n: 74, levels: ["74 m"]))
        try store.save(Self.session(placeID: nil, n: 76, levels: ["76 m"]))
        #expect(try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil).map(\.text) == ["74 m"])
    }
    @Test func boxCornerOutsideTheRadiusIsDropped() throws {
        // 60 m north and 60 m east: each axis is inside the ±75 m box, but √(60² + 60²) = 84.85 m > 75 m.
        // 60 m = 60 / 111_195 = 0.00053959° on both axes at the equator.
        var corner = Self.session(placeID: nil, levels: ["corner"])
        corner.capture.coordinate = Coordinate(latitude: 60 / 111_195, longitude: 60 / 111_195)
        try store.save(corner)
        #expect(try store.priorStories(placeIDs: [], near: Self.origin, excludingSession: nil).isEmpty)
    }
    @Test func missingLevelThrowsCorruptRecord() throws {
        try store.save(Self.session(placeID: "osm:node/1", levels: ["one", "two"]))
        let rec = try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>()).first)
        let first = try #require(rec.stories.first { $0.level == 1 })
        store.context.delete(first)
        try store.context.save()
        #expect(throws: MemoryError.corruptRecord) { try store.session(for: rec) }
    }
    @Test func placeRecordIsUpsertedFromTheMatchedCandidate() throws {
        try store.save(Self.session(placeID: "osm:node/1", levels: ["one", "two", "three"], at: 50))
        try store.save(Self.session(placeID: "osm:node/1", levels: ["once"], at: 20))
        let place = try #require(try store.place(id: "osm:node/1"))
        #expect(place.name == "Gate")
        #expect(place.deepestLevelHeard == 3)   // highest saved level, not the latest session's
        #expect(place.firstSeenAt == Date(timeIntervalSince1970: 20))
        #expect(place.lastHeardAt != nil)
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 1)
    }
    @Test func unidentifiedSessionCreatesNoPlace() throws {
        try store.save(Self.session(placeID: nil, levels: ["x"]))
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 0)
        #expect(try store.place(id: "osm:node/x") == nil)
    }
    @Test func failedSaveWritesNothing() throws {
        var s = Self.session(placeID: "osm:node/1", levels: ["x"]); s.capture.coordinate = nil
        #expect(throws: MemoryError.noPosition) { try store.save(s) }
        #expect(try store.context.fetchCount(FetchDescriptor<CaptureRecord>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 0)
    }

    @Test func usageTotalsByMonth() throws {
        // Oct 3 $0.01 + Oct 20 $0.02 = month $0.03; + Sep 30 $0.05 = all-time $0.08; one unpriced in Oct
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        let table = PriceTable(asOf: "t", prices: ["img": .perImage(0.01)])
        try store.recordUsage([UsageEntry(date: d("2026-10-03T12:00:00Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 1),
                               UsageEntry(date: d("2026-10-20T12:00:00Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 2),
                               UsageEntry(date: d("2026-09-30T23:59:59Z"), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 5),
                               UsageEntry(date: d("2026-10-21T12:00:00Z"), kind: .story, model: "unknown", inputTokens: 9, outputTokens: 9, words: 0, images: 0)],
                              prices: table)
        let u = try store.usageTotals(now: d("2026-10-27T10:00:00Z"), calendar: cal)
        #expect(abs(u.monthUSD - 0.03) < 1e-12 && abs(u.allTimeUSD - 0.08) < 1e-12)
        #expect(u.monthRequests == 3 && u.unpricedRequests == 1)
    }

    @Test func usageTotalsEmptyIsZero() throws {
        let u = try store.usageTotals(now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian))
        #expect(u == UsageTotals(monthUSD: 0, allTimeUSD: 0, monthRequests: 0, unpricedRequests: 0))
    }

    @Test func usageMonthWindowIsHalfOpen() throws {
        // UTC: Oct 31 23:59:59 is October; Nov 1 00:00:00 is November, so month = Oct only (1 request, $0.01).
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        let table = PriceTable(asOf: "t", prices: ["img": .perImage(0.01)])
        func entry(_ s: String) -> UsageEntry {
            UsageEntry(date: d(s), kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 1)
        }
        try store.recordUsage([entry("2026-10-31T23:59:59Z"), entry("2026-11-01T00:00:00Z")], prices: table)
        let oct = try store.usageTotals(now: d("2026-10-15T00:00:00Z"), calendar: cal)
        #expect(oct.monthRequests == 1 && abs(oct.monthUSD - 0.01) < 1e-12 && abs(oct.allTimeUSD - 0.02) < 1e-12)
        let nov = try store.usageTotals(now: d("2026-11-15T00:00:00Z"), calendar: cal)
        #expect(nov.monthRequests == 1 && abs(nov.monthUSD - 0.01) < 1e-12)
        // UTC+2: 2026-10-31T22:30:00Z is Nov 1 00:30 local, so it counts in November, not October.
        var plus2 = cal; plus2.timeZone = TimeZone(secondsFromGMT: 7200)!
        let local = try store.usageTotals(now: d("2026-10-15T00:00:00Z"), calendar: plus2)
        #expect(local.monthRequests == 0)  // neither record (22:30Z is Nov local; 23:59:59Z on Oct 31 is Nov 1 01:59 local)
        let localNov = try store.usageTotals(now: d("2026-11-15T00:00:00Z"), calendar: plus2)
        #expect(localNov.monthRequests == 2)
    }

    @Test func costIsStoredAtRecordTime() throws {
        // Recorded at $0.01/image; a later table at $0.50 must not change stored cost.
        let old = PriceTable(asOf: "old", prices: ["img": .perImage(0.01)])
        let later = PriceTable(asOf: "new", prices: ["img": .perImage(0.50)])
        let now = Date()
        let e = UsageEntry(date: now, kind: .image, model: "img", inputTokens: 0, outputTokens: 0, words: 0, images: 1)
        try store.recordUsage([e], prices: old)
        try store.recordUsage([], prices: later)
        let rec = try #require(try store.context.fetch(FetchDescriptor<UsageRecord>()).first)
        #expect(rec.estimatedUSD == 0.01)
        #expect(abs(try store.usageTotals(now: now, calendar: .current).allTimeUSD - 0.01) < 1e-12)
        #expect(later.estimatedUSD(e) == 0.50)
    }

    @Test func usageMonthUsesTheCallersTimeZone() throws {
        // UTC+2: 2026-10-31T22:30:00Z is 2026-11-01 00:30 local, so in November (1 request) and not October (0).
        func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 7200)!
        let table = PriceTable(asOf: "t", prices: ["img": .perImage(0.01)])
        try store.recordUsage([UsageEntry(date: d("2026-10-31T22:30:00Z"), kind: .image, model: "img", inputTokens: 0,
                                          outputTokens: 0, words: 0, images: 1)], prices: table)
        #expect(try store.usageTotals(now: d("2026-10-15T00:00:00Z"), calendar: cal).monthRequests == 0)
        #expect(try store.usageTotals(now: d("2026-11-15T00:00:00Z"), calendar: cal).monthRequests == 1)
    }
}
