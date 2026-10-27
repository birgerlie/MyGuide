import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

@MainActor @Suite struct WalkMemoryTests {
    let store: MemoryStore
    init() throws {
        let c = try ModelContainer(for: Schema(MemorySchema.models), configurations: .init(isStoredInMemoryOnly: true))
        store = MemoryStore(context: c.mainContext)
    }
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let trip = UUID(), otherTrip = UUID()

    static func candidate(_ id: String, north: Double = 0) -> Candidate {
        Candidate(id: id, name: "Name \(id)", coordinate: .at(north: north), kind: "historic=castle",
                  summary: "A castle.", wikipediaTitle: "de:Burg", wikidata: "Q1", tags: ["historic": "castle"])
    }
    static func buzz(_ placeID: String, tier: PlaceTier = .top, distance: Double = 50, id: UUID = UUID()) -> Buzz {
        Buzz(id: id, place: WalkingPlace(candidate: candidate(placeID), tier: tier), distance: distance, bearing: 270,
             title: "Name \(placeID)", detail: "50 m left", usedOverride: false)
    }
    static func buzzStory(_ placeID: String, levels: [String], id: UUID = UUID(), at t: TimeInterval = 0) -> WalkStory {
        WalkStory(id: id, kind: .buzz, place: candidate(placeID), position: .at(north: 5), course: 87.5,
                  language: .norwegian, title: "Buzz title", levels: levels, createdAt: t0 + t,
                  address: nil, detail: "50 m left")
    }
    static func stopStory(north: Double, levels: [String], id: UUID = UUID(), at t: TimeInterval = 0) -> WalkStory {
        WalkStory(id: id, kind: .stop, place: nil, position: .at(north: north), course: nil, language: .english,
                  title: "Stop title", levels: levels, createdAt: t0 + t,
                  address: Address(line: "Michaelerplatz 1", city: "Wien", country: "Austria"), detail: nil)
    }

    // MARK: - touchTrip

    @Test func touchTripCreatesExtendsAndRollsOver() throws {
        let first = try store.touchTrip(now: Self.t0, city: "Vienna")
        #expect(first.startedAt == Self.t0 && first.lastUsedAt == Self.t0 && first.city == "Vienna")
        let same = try store.touchTrip(now: Self.t0 + 60, city: "Vienna")
        #expect(same.id == first.id && same.lastUsedAt == Self.t0 + 60 && same.startedAt == Self.t0)
        // Last use t0 + 60; one second short of the gap (t0 + 60 + 259 199) stays, the full gap (t0 + 60 + 259 200) rolls over.
        let stillSame = try store.touchTrip(now: Self.t0 + 60 + 259_199, city: "Vienna")
        #expect(stillSame.id == first.id)
        let next = try store.touchTrip(now: Self.t0 + 60 + 259_199 + 259_200, city: "Vienna")
        #expect(next.id != first.id && next.startedAt == Self.t0 + 60 + 259_199 + 259_200)
        #expect(try store.context.fetchCount(FetchDescriptor<TripRecord>()) == 2)
        // The old trip is left as it was.
        #expect(first.lastUsedAt == Self.t0 + 60 + 259_199)
    }
    @Test func touchTripInAnotherCityStartsANewTrip() throws {
        let vienna = try store.touchTrip(now: Self.t0, city: "Vienna")
        let rome = try store.touchTrip(now: Self.t0 + 60, city: "Rome")
        #expect(rome.id != vienna.id && rome.city == "Rome")
        // Back to the newest trip: "rome" matches "Rome" and nil keeps the trip.
        #expect(try store.touchTrip(now: Self.t0 + 120, city: "rome").id == rome.id)
        #expect(try store.touchTrip(now: Self.t0 + 180, city: nil).id == rome.id)
        #expect(rome.city == "Rome")
    }
    @Test func tripWithoutCityAdoptsTheFirstKnownCity() throws {
        let trip = try store.touchTrip(now: Self.t0, city: nil)
        #expect(trip.city == nil)
        let adopted = try store.touchTrip(now: Self.t0 + 60, city: "Rome")
        #expect(adopted.id == trip.id && adopted.city == "Rome")
        #expect(try store.touchTrip(now: Self.t0 + 120, city: "Paris").id != trip.id)
    }
    @Test func touchTripStoresATrimmedCityAndBlankAsNil() throws {
        let trip = try store.touchTrip(now: Self.t0, city: "  ")
        #expect(trip.city == nil)
        #expect(try store.touchTrip(now: Self.t0 + 1, city: " Wien ").city == "Wien")
    }
    @Test func touchTripWithAnEarlierClockKeepsLastUsedAt() throws {
        _ = try store.touchTrip(now: Self.t0, city: "Vienna")
        let trip = try store.touchTrip(now: Self.t0 - 60, city: "Vienna")
        #expect(trip.lastUsedAt == Self.t0)
    }

    // MARK: - recordBuzz and placeIDsBuzzed

    @Test func recordBuzzLogsItAndUpsertsThePlace() throws {
        let b = Self.buzz("osm:node/1", tier: .good, distance: 42)
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        #expect(try store.placeIDsBuzzed(tripID: Self.trip) == ["osm:node/1"])
        #expect(try store.placeIDsBuzzed(tripID: Self.otherTrip).isEmpty)
        let rec = try #require(try store.context.fetch(FetchDescriptor<BuzzRecord>()).first)
        #expect(rec.id == b.id && rec.at == Self.t0 && rec.tripID == Self.trip && rec.placeID == "osm:node/1")
        #expect(rec.placeName == "Name osm:node/1" && rec.kind == "historic=castle" && rec.tier == 2)
        #expect(rec.distance == 42 && rec.outcome == "pending" && rec.deepestLevel == 0)
        let place = try #require(try store.place(id: "osm:node/1"))
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.skippedAt == nil)
        #expect(place.lastBuzzedAt == Self.t0 && place.lastBuzzTripID == Self.trip && place.firstSeenAt == Self.t0)
    }
    @Test func recordBuzzOnAKnownPlaceKeepsItsHistory() throws {
        try store.save(MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one", "two"], at: 10))
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        let place = try #require(try store.place(id: "osm:node/1"))
        #expect(place.deepestLevelHeard == 2 && place.lastHeardAt != nil)
        #expect(place.firstSeenAt == Date(timeIntervalSince1970: 10))   // earlier than t0, so kept
        #expect(place.lastBuzzedAt == Self.t0 && place.lastBuzzTripID == Self.trip)
        // A second buzz in a later trip moves the last-buzz fields on.
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.otherTrip, at: Self.t0 + 100)
        #expect(place.lastBuzzedAt == Self.t0 + 100 && place.lastBuzzTripID == Self.otherTrip)
        #expect(try store.placeIDsBuzzed(tripID: Self.trip) == ["osm:node/1"])
        #expect(try store.placeIDsBuzzed(tripID: Self.otherTrip) == ["osm:node/1"])
    }
    @Test func recordingTheSameBuzzTwiceKeepsOneEntry() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0 + 5)
        #expect(try store.context.fetchCount(FetchDescriptor<BuzzRecord>()) == 1)
        #expect(try store.buzzLog().first?.outcome == .heard)
        #expect(try store.buzzLog().first?.at == Self.t0)
    }

    // MARK: - retiredPlaceIDs

    @Test func buzzedOnlyIsNotRetiredSkippedIs() throws {
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        #expect(try store.retiredPlaceIDs().isEmpty)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 5)
    }
    @Test func savedButUnplayedBuzzStoryDoesNotRetire() throws {
        // Ruling 9: a buzz story is saved when it is prepared, before the owner taps.
        try store.saveWalkStory(Self.buzzStory("osm:node/2", levels: ["one"]), tripID: Self.trip)
        #expect(try store.retiredPlaceIDs().isEmpty)
        let place = try #require(try store.place(id: "osm:node/2"))
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.firstSeenAt == Self.t0)
    }
    @Test func heardViaBuzzOutcomeRetiresWithTheGivenTime() throws {
        let b = Self.buzz("osm:node/2")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        #expect(try store.retiredPlaceIDs() == ["osm:node/2"])
        let place = try #require(try store.place(id: "osm:node/2"))
        #expect(place.deepestLevelHeard == 1 && place.lastHeardAt == Self.t0 + 30 && place.skippedAt == nil)
        // Deeper: level 2 at t0 + 90.
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 90)
        #expect(place.deepestLevelHeard == 2 && place.lastHeardAt == Self.t0 + 90)
        // Not deeper (2 again, then 1): refused, the place keeps level 2 heard at t0 + 90.
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 120)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 150)
        #expect(place.deepestLevelHeard == 2 && place.lastHeardAt == Self.t0 + 90)
    }
    @Test func heardBuzzNeverLowersAPhotographedPlace() throws {
        try store.save(MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one", "two", "three"]))
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        let place = try #require(try store.place(id: "osm:node/1"))
        #expect(place.deepestLevelHeard == 3 && place.lastHeardAt == Self.t0 + 30)
    }
    @Test func skippedViaBuzzOutcomeRetires() throws {
        let b = Self.buzz("osm:node/2")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 20)
        #expect(try store.retiredPlaceIDs() == ["osm:node/2"])
        let place = try #require(try store.place(id: "osm:node/2"))
        #expect(place.skippedAt == Self.t0 + 20 && place.deepestLevelHeard == 0 && place.lastHeardAt == nil)
    }
    @Test func refusedOutcomeLeavesThePlaceAlone() throws {
        let skipped = Self.buzz("osm:node/1"), ignored = Self.buzz("osm:node/2")
        try store.recordBuzz(skipped, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(ignored, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(skipped.id, .skipped, deepestLevel: 0, at: Self.t0 + 20)
        try store.closePendingBuzzes()
        try store.setBuzzOutcome(skipped.id, .heard, deepestLevel: 2, at: Self.t0 + 40)
        let s = try #require(try store.place(id: "osm:node/1")), i = try #require(try store.place(id: "osm:node/2"))
        #expect(s.skippedAt == Self.t0 + 20 && s.deepestLevelHeard == 0 && s.lastHeardAt == nil)
        #expect(i.skippedAt == nil && i.deepestLevelHeard == 0 && i.lastHeardAt == nil)
        #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
    }
    @Test func lateSkipOverridesIgnored() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.closePendingBuzzes()
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 30)
        #expect(try store.buzzLog().map(\.outcome) == [.skipped])
        #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
        #expect(try #require(try store.place(id: "osm:node/1")).skippedAt == Self.t0 + 30)
    }
    @Test func lateHearingOverridesIgnored() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.closePendingBuzzes()
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        let entry = try #require(try store.buzzLog().first)
        #expect(entry.outcome == .heard && entry.deepestLevel == 1)
        #expect(try store.retiredPlaceIDs() == ["osm:node/1"])
        #expect(try #require(try store.place(id: "osm:node/1")).lastHeardAt == Self.t0 + 30)
    }
    @Test func skippedStaysSkippedWhenHeardLater() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 20)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        #expect(try store.buzzLog().map(\.outcome) == [.skipped])
        #expect(try #require(try store.place(id: "osm:node/1")).lastHeardAt == nil)
    }
    @Test func ignoredBuzzDoesNotRetire() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .ignored, deepestLevel: 0, at: Self.t0 + 20)
        #expect(try store.retiredPlaceIDs().isEmpty)
    }
    @Test func photographedPlaceCountsAsHeard() throws {
        try store.save(MemoryStoreTests.session(placeID: "osm:node/3", levels: ["one"]))
        #expect(try store.retiredPlaceIDs() == ["osm:node/3"])
    }
    @Test func stopStoryRetiresNothing() throws {
        try store.saveWalkStory(Self.stopStory(north: 0, levels: ["here"]), tripID: Self.trip)
        #expect(try store.retiredPlaceIDs().isEmpty)
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 0)
    }
    @Test func secondSkipKeepsTheFirstTime() throws {
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 50)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 5)
    }
    @Test func skippingAnUnknownPlaceCreatesAndRetiresIt() throws {
        try store.markSkipped(Self.candidate("osm:node/9", north: 30), at: Self.t0)
        let place = try #require(try store.place(id: "osm:node/9"))
        #expect(place.name == "Name osm:node/9" && place.firstSeenAt == Self.t0 && place.skippedAt == Self.t0)
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.lastBuzzedAt == nil)
        #expect(Coordinate(latitude: place.latitude, longitude: place.longitude) == .at(north: 30))
        #expect(try store.retiredPlaceIDs() == ["osm:node/9"])
    }
    @Test func skipAndHeardViaOutcomeKeepTheFirstSkip() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 9)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 5)
    }

    // MARK: - setBuzzOutcome and closePendingBuzzes

    @Test func heardDeepensButNeverShallows() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        #expect(try store.buzzLog().map(\.outcome) == [.heard] && store.buzzLog().map(\.deepestLevel) == [1])
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        #expect(try store.buzzLog().map(\.outcome) == [.heard] && store.buzzLog().map(\.deepestLevel) == [2])
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        #expect(try store.buzzLog().map(\.deepestLevel) == [2])
    }
    @Test func finalOutcomesDoNotChange() throws {
        let skipped = Self.buzz("osm:node/1"), ignored = Self.buzz("osm:node/2"), heard = Self.buzz("osm:node/3")
        try store.recordBuzz(skipped, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(ignored, tripID: Self.trip, at: Self.t0 + 1)
        try store.recordBuzz(heard, tripID: Self.trip, at: Self.t0 + 2)
        try store.setBuzzOutcome(skipped.id, .skipped, deepestLevel: 0, at: Self.t0 + 10)
        try store.setBuzzOutcome(skipped.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        try store.setBuzzOutcome(ignored.id, .ignored, deepestLevel: 0, at: Self.t0 + 10)
        try store.setBuzzOutcome(ignored.id, .pending, deepestLevel: 0, at: Self.t0 + 10)
        try store.setBuzzOutcome(heard.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        try store.setBuzzOutcome(heard.id, .skipped, deepestLevel: 3, at: Self.t0 + 10)
        try store.setBuzzOutcome(heard.id, .pending, deepestLevel: 3, at: Self.t0 + 10)
        let log = try store.buzzLog()
        #expect(log.map(\.placeID) == ["osm:node/3", "osm:node/2", "osm:node/1"])
        #expect(log.map(\.outcome) == [.heard, .ignored, .skipped])
        #expect(log.map(\.deepestLevel) == [1, 0, 0])
    }
    @Test func pendingCanBecomeSkippedWithTheLevelReached() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 1, at: Self.t0 + 10)
        let entry = try #require(try store.buzzLog().first)
        #expect(entry.outcome == .skipped && entry.deepestLevel == 1)
    }
    @Test func unknownBuzzOutcomeThrows() {
        #expect(throws: MemoryError.corruptRecord) { try store.setBuzzOutcome(UUID(), .heard, deepestLevel: 1, at: Self.t0) }
    }
    @Test func closePendingTurnsOnlyPendingIntoIgnored() throws {
        let a = Self.buzz("osm:node/1"), b = Self.buzz("osm:node/2"), c = Self.buzz("osm:node/3")
        try store.recordBuzz(a, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0 + 1)
        try store.recordBuzz(c, tripID: Self.trip, at: Self.t0 + 2)
        try store.setBuzzOutcome(a.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 10)
        try store.closePendingBuzzes()
        let log = try store.buzzLog()
        #expect(log.map(\.outcome) == [.ignored, .skipped, .heard])
        #expect(log.map(\.deepestLevel) == [0, 0, 2])
        // Nothing pending: a no-op.
        try store.closePendingBuzzes()
        #expect(try store.buzzLog().map(\.outcome) == [.ignored, .skipped, .heard])
    }

    // MARK: - saveWalkStory and walkStory(id:)

    @Test func savingMoreLevelsAppendsOnlyTheNewOnes() throws {
        var s = Self.buzzStory("osm:node/1", levels: ["L1"])
        try store.saveWalkStory(s, tripID: Self.trip)
        s.levels.append("L2")
        try store.saveWalkStory(s, tripID: Self.trip)
        try store.saveWalkStory(s, tripID: Self.trip)
        let stories = try store.context.fetch(FetchDescriptor<StoryRecord>()).sorted { $0.level < $1.level }
        #expect(stories.map(\.level) == [1, 2] && stories.map(\.text) == ["L1", "L2"])
        #expect(stories.allSatisfy { $0.placeID == "osm:node/1" && $0.capture == nil && $0.walkStory?.id == s.id })
        // createdAt = story createdAt + level index: t0 + 0 and t0 + 1.
        #expect(stories.map(\.createdAt) == [Self.t0, Self.t0 + 1])
        #expect(try store.context.fetchCount(FetchDescriptor<WalkStoryRecord>()) == 1)
        #expect(try store.place(id: "osm:node/1")?.deepestLevelHeard == 0)
    }
    @Test func storedLevelsAreNeverRewritten() throws {
        var s = Self.buzzStory("osm:node/1", levels: ["L1"])
        try store.saveWalkStory(s, tripID: Self.trip)
        s.levels = ["rewritten", "L2"]
        try store.saveWalkStory(s, tripID: Self.otherTrip)
        let restored = try #require(try store.walkStory(id: s.id))
        #expect(restored.levels == ["L1", "L2"])
        // The story stays in the trip it was first saved in.
        #expect(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first?.tripID == Self.trip)
    }
    @Test func buzzStoryRoundTripsEveryField() throws {
        let s = Self.buzzStory("osm:node/1", levels: ["one", "two", "three"], at: 30)
        try store.saveWalkStory(s, tripID: Self.trip)
        let r = try #require(try store.walkStory(id: s.id))
        #expect(r.id == s.id)
        #expect(r.kind == .buzz)
        #expect(r.place == Self.candidate("osm:node/1"))
        #expect(r.place?.tags == ["historic": "castle"] && r.place?.summary == "A castle." && r.place?.wikidata == "Q1")
        #expect(r.position == Coordinate.at(north: 5))
        #expect(r.course == 87.5)
        #expect(r.language == .norwegian)
        #expect(r.title == "Buzz title")
        #expect(r.levels == ["one", "two", "three"])
        #expect(r.createdAt == Self.t0 + 30)
        #expect(r.address == nil)
        #expect(r.detail == "50 m left")
        #expect(r.nextLevel == nil)
        #expect(r == s)
    }
    @Test func stopStoryRoundTripsEveryField() throws {
        let s = Self.stopStory(north: 12, levels: ["here"], at: 7)
        try store.saveWalkStory(s, tripID: Self.trip)
        let r = try #require(try store.walkStory(id: s.id))
        #expect(r.id == s.id)
        #expect(r.kind == .stop)
        #expect(r.place == nil)
        #expect(r.position == Coordinate.at(north: 12))
        #expect(r.course == nil)
        #expect(r.language == .english)
        #expect(r.title == "Stop title")
        #expect(r.levels == ["here"])
        #expect(r.createdAt == Self.t0 + 7)
        #expect(r.address == Address(line: "Michaelerplatz 1", city: "Wien", country: "Austria"))
        #expect(r.detail == nil)
        #expect(r.nextLevel == .more)
        #expect(r == s)
    }
    @Test func unknownWalkStoryIsNil() throws {
        #expect(try store.walkStory(id: UUID()) == nil)
    }
    @Test func walkStoryWithAMissingLevelIsCorrupt() throws {
        let s = Self.stopStory(north: 0, levels: ["one", "two"])
        try store.saveWalkStory(s, tripID: Self.trip)
        let first = try #require(try store.context.fetch(FetchDescriptor<StoryRecord>()).first { $0.level == 1 })
        store.context.delete(first)
        try store.context.save()
        #expect(throws: MemoryError.corruptRecord) { try store.walkStory(id: s.id) }
    }
    @Test func walkStoryWithAnUnknownLanguageIsCorrupt() throws {
        let s = Self.stopStory(north: 0, levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        try #require(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first).language = "xx"
        #expect(throws: MemoryError.corruptRecord) { try store.walkStory(id: s.id) }
    }
    @Test func walkStoryWithBadPlaceJSONIsCorrupt() throws {
        let s = Self.buzzStory("osm:node/1", levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        try #require(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first).placeJSON = Data("x".utf8)
        #expect(throws: MemoryError.corruptRecord) { try store.walkStory(id: s.id) }
    }

    // MARK: - Priors

    @Test func buzzStoryLevelsArePriorsForItsPlace() throws {
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one", "two"]), tripID: Self.trip)
        // The place is 5 km away from `near`: found by place ID, not by distance.
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: .at(north: 5_000), excludingSession: nil)
        // createdAt: two = t0 + 1, one = t0 + 0, newest first.
        #expect(p.map(\.text) == ["two", "one"] && p.map(\.placeID) == ["osm:node/1", "osm:node/1"])
        #expect(try store.priorStories(placeIDs: ["osm:node/2"], near: .at(), excludingSession: nil).isEmpty)
    }
    @Test func stopStoriesArePriorsWithinTheRadius() throws {
        // GeoMath and `.at` share 111 194.93 m per degree: 50 m and 80 m north of the origin; radius 75 m.
        let near = Self.stopStory(north: 50, levels: ["50 m"], at: 1)
        try store.saveWalkStory(near, tripID: Self.trip)
        try store.saveWalkStory(Self.stopStory(north: 80, levels: ["80 m"], at: 2), tripID: Self.trip)
        let p = try store.priorStories(placeIDs: [], near: .at(), excludingSession: nil)
        #expect(p.map(\.text) == ["50 m"] && p.first?.placeID == nil)
        #expect(try store.priorStories(placeIDs: [], near: .at(), excludingSession: near.id).isEmpty)
    }
    @Test func stopStoryRadiusSplitsBetween74And76Metres() throws {
        try store.saveWalkStory(Self.stopStory(north: 74, levels: ["74 m"]), tripID: Self.trip)
        try store.saveWalkStory(Self.stopStory(north: 76, levels: ["76 m"]), tripID: Self.trip)
        #expect(try store.priorStories(placeIDs: [], near: .at(), excludingSession: nil).map(\.text) == ["74 m"])
    }
    @Test func buzzStoriesAreNotPriorsByDistance() throws {
        // The buzz story was told at 5 m north, but it belongs to its place, not to the spot.
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"]), tripID: Self.trip)
        #expect(try store.priorStories(placeIDs: [], near: .at(), excludingSession: nil).isEmpty)
    }
    @Test func excludingAWalkStoryByIDAlsoWorksForBuzzStories() throws {
        let s = Self.buzzStory("osm:node/1", levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: s.id).isEmpty)
    }
    @Test func photoAndWalkPriorsMixNewestFirst() throws {
        // Photo capture at t = 100 s, 10 m away and unidentified; stop story at t0 (1 000 000 s), 20 m away.
        try store.save(MemoryStoreTests.session(placeID: nil, n: 10, levels: ["photo"], at: 100))
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["stop"]), tripID: Self.trip)
        let p = try store.priorStories(placeIDs: [], near: .at(), excludingSession: nil)
        #expect(p.map(\.text) == ["stop", "photo"])
    }

    // MARK: - Track and buzz log

    @Test func appendTrackStoresEverySampleForTheTrip() throws {
        let samples = (0..<3).map { TrackSample(at: Self.t0 + Double($0), coordinate: .at(north: Double($0) * 10)) }
        try store.appendTrack(samples, tripID: Self.trip)
        try store.appendTrack([], tripID: Self.trip)
        let trip = Self.trip
        let points = try store.context.fetch(FetchDescriptor<TrackPoint>(predicate: #Predicate { $0.tripID == trip },
                                                                          sortBy: [SortDescriptor(\.at)]))
        #expect(points.count == 3)
        #expect(points.map(\.at) == [Self.t0, Self.t0 + 1, Self.t0 + 2])
        // 20 m north = 20 / 111 194.93 = 0.00017986°.
        #expect(points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) } == samples.map(\.coordinate))
    }
    @Test func buzzLogIsNewestFirstWithOutcomeAndLevel() throws {
        let early = Self.buzz("osm:node/1", tier: .top, distance: 30), late = Self.buzz("osm:node/2", tier: .wikiOnly, distance: 95)
        try store.recordBuzz(early, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(late, tripID: Self.otherTrip, at: Self.t0 + 60)
        try store.setBuzzOutcome(early.id, .heard, deepestLevel: 3, at: Self.t0 + 10)
        let log = try store.buzzLog()
        #expect(log == [
            BuzzLogEntry(id: late.id, at: Self.t0 + 60, placeID: "osm:node/2", placeName: "Name osm:node/2",
                         kind: "historic=castle", tier: 3, distance: 95, outcome: .pending, deepestLevel: 0),
            BuzzLogEntry(id: early.id, at: Self.t0, placeID: "osm:node/1", placeName: "Name osm:node/1",
                         kind: "historic=castle", tier: 1, distance: 30, outcome: .heard, deepestLevel: 3),
        ])
    }
    @Test func emptyBuzzLog() throws {
        #expect(try store.buzzLog().isEmpty)
    }

    // MARK: - deepestLevelHeard(buzzID:)

    @Test func deepestLevelHeardFollowsTheBuzzRecord() throws {
        let b = Self.buzz("p1")
        #expect(try store.deepestLevelHeard(buzzID: b.id) == nil)          // never logged (stop story, failed record)
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        #expect(try store.deepestLevelHeard(buzzID: b.id) == 0)            // pending, nothing heard
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        #expect(try store.deepestLevelHeard(buzzID: b.id) == 2)
        // A shallower replay never lowers it: max(2, 1) = 2.
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 20)
        #expect(try store.deepestLevelHeard(buzzID: b.id) == 2)
    }
}
