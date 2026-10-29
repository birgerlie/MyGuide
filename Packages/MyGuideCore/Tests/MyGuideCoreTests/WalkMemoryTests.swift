import Foundation
import SwiftData
import Testing
@testable import MyGuideCore

@MainActor @Suite struct WalkMemoryTests {
    let store: MemoryStore
    /// Stamps every story level the suite's store writes; starts at `t0`, and tests about order move it.
    let clock = Clock(WalkMemoryTests.t0)
    init() throws {
        store = try Self.clockedStore(clock)
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

    // MARK: - recordBuzz

    @Test func recordBuzzLogsItAndUpsertsThePlace() throws {
        let b = Self.buzz("osm:node/1", tier: .good, distance: 42)
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        #expect(try store.context.fetchCount(FetchDescriptor<BuzzRecord>()) == 1)
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
        // Both buzzes are in the log, one per trip, both for the same place.
        let records = try store.context.fetch(FetchDescriptor<BuzzRecord>())
        #expect(Set(records.map(\.tripID)) == [Self.trip, Self.otherTrip])
        #expect(records.allSatisfy { $0.placeID == "osm:node/1" })
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
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000).isEmpty)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/1"])
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 5)
    }
    @Test func savedButUnplayedBuzzStoryDoesNotRetire() throws {
        // Ruling 9: a buzz story is saved when it is prepared, before the owner taps.
        try store.saveWalkStory(Self.buzzStory("osm:node/2", levels: ["one"]), tripID: Self.trip)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000).isEmpty)
        let place = try #require(try store.place(id: "osm:node/2"))
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.firstSeenAt == Self.t0)
    }
    @Test func heardViaBuzzOutcomeRetiresWithTheGivenTime() throws {
        let b = Self.buzz("osm:node/2")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/2"])
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
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/2"])
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
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/1"])
    }
    @Test func lateSkipOverridesIgnored() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.closePendingBuzzes()
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 30)
        #expect(try store.buzzLog().map(\.outcome) == [.skipped])
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/1"])
        #expect(try #require(try store.place(id: "osm:node/1")).skippedAt == Self.t0 + 30)
    }
    @Test func lateHearingOverridesIgnored() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.closePendingBuzzes()
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 30)
        let entry = try #require(try store.buzzLog().first)
        #expect(entry.outcome == .heard && entry.deepestLevel == 1)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/1"])
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
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000).isEmpty)
    }
    @Test func photographedPlaceCountsAsHeard() throws {
        try store.save(MemoryStoreTests.session(placeID: "osm:node/3", levels: ["one"]))
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/3"])
    }
    @Test func stopStoryRetiresNothing() throws {
        try store.saveWalkStory(Self.stopStory(north: 0, levels: ["here"]), tripID: Self.trip)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000).isEmpty)
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 0)
    }
    // MARK: - The 30-day rest (spec 13.1) and the reset (spec 13.5)

    @Test func retiredWithinThirtyDays() throws {
        // 30 days = 30 × 86 400 = 2 592 000 s. 29 d 23 h = 2 505 600 + 82 800 = 2 588 400 s (inside);
        // 30 d 1 h = 2 592 000 + 3 600 = 2 595 600 s (outside); exactly 30 d is still inside (≥ now − 30 d).
        #expect(MemoryStore.placeRestDays == 30)
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/2"), at: Self.t0)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 2_588_400) == ["osm:node/1", "osm:node/2"])
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 2_592_000) == ["osm:node/1", "osm:node/2"])
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 2_592_001).isEmpty)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 2_595_600).isEmpty)
        // At the moment itself, and with a clock set back before it, the place is used.
        #expect(try store.retiredPlaceIDs(now: Self.t0) == ["osm:node/1", "osm:node/2"])
        #expect(try store.retiredPlaceIDs(now: Self.t0 - 60) == ["osm:node/1", "osm:node/2"])
    }
    @Test func heardWithoutLastHeardAtIsNotRetired() throws {
        // A place heard before lastHeardAt existed: the rest is unknown, and spec 13.8 leans towards more buzzes.
        store.context.insert(PlaceRecord(id: "osm:node/1", name: "Old", latitude: 0, longitude: 0, firstSeenAt: Self.t0,
                                         deepestLevelHeard: 2, lastHeardAt: nil))
        try store.context.save()
        #expect(try store.retiredPlaceIDs(now: Self.t0).isEmpty)
    }
    @Test func lastHeardAtWithoutAHeardLevelIsNotRetired() throws {
        // lastHeardAt alone (deepestLevelHeard 0) never retires: the rule needs a level heard.
        store.context.insert(PlaceRecord(id: "osm:node/1", name: "Odd", latitude: 0, longitude: 0, firstSeenAt: Self.t0,
                                         deepestLevelHeard: 0, lastHeardAt: Self.t0))
        try store.context.save()
        #expect(try store.retiredPlaceIDs(now: Self.t0).isEmpty)
    }
    @Test func eitherRecentReasonRetires() throws {
        // Heard 40 days ago (t0 − 3 456 000) but skipped 1 day ago (t0 − 86 400): the skip keeps it resting, and
        // the other way round.
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0 - 3_456_000)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 - 86_400)
        try store.markSkipped(Self.candidate("osm:node/2"), at: Self.t0 - 3_456_000)
        try store.markHeard(Self.candidate("osm:node/2"), level: 1, at: Self.t0 - 86_400)
        #expect(try store.retiredPlaceIDs(now: Self.t0) == ["osm:node/1", "osm:node/2"])
    }
    // MARK: - heardPlaceIDs (tours spec 4)

    @Test func heardPlaceIDsCountsHearingNotSkipping() throws {
        // node/1 heard, node/2 skipped, node/3 only buzzed, node/4 photographed (a saved photo story level).
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/2"), at: Self.t0)
        try store.recordBuzz(Self.buzz("osm:node/3"), tripID: Self.trip, at: Self.t0)
        try store.save(MemoryStoreTests.session(placeID: "osm:node/4", levels: ["one"]))
        #expect(try store.heardPlaceIDs(since: Self.t0 - 1_000) == ["osm:node/1", "osm:node/4"])
    }
    @Test func heardPlaceIDsCutoffIsInclusive() throws {
        // Heard at t0: counted from a cutoff of t0 (inclusive), not from t0 + 1 s.
        try store.markHeard(Self.candidate("osm:node/1"), level: 2, at: Self.t0)
        #expect(try store.heardPlaceIDs(since: Self.t0) == ["osm:node/1"])
        #expect(try store.heardPlaceIDs(since: Self.t0 + 1).isEmpty)
        #expect(try store.heardPlaceIDs(since: Self.t0 - 60) == ["osm:node/1"])
    }
    @Test func toursHeardWindowIsThirtyDays() throws {
        // 30 days = 30 × 86 400 = 2 592 000 s. Heard at t0, asked at t0 + 2 592 000: cutoff t0 → counted; asked one
        // second later: cutoff t0 + 1 → not counted.
        #expect(TourCandidates.heardWindow == 2_592_000)
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0)
        #expect(try store.heardPlaceIDs(since: Self.t0 + 2_592_000 - TourCandidates.heardWindow) == ["osm:node/1"])
        #expect(try store.heardPlaceIDs(since: Self.t0 + 2_592_001 - TourCandidates.heardWindow).isEmpty)
    }
    @Test func heardPlaceIDsSkipsUnknownOrMissingHearings() throws {
        // Level heard without lastHeardAt (stored before the field existed), and lastHeardAt without a level.
        store.context.insert(PlaceRecord(id: "osm:node/1", name: "Old", latitude: 0, longitude: 0, firstSeenAt: Self.t0,
                                         deepestLevelHeard: 2, lastHeardAt: nil))
        store.context.insert(PlaceRecord(id: "osm:node/2", name: "Odd", latitude: 0, longitude: 0, firstSeenAt: Self.t0,
                                         deepestLevelHeard: 0, lastHeardAt: Self.t0))
        try store.context.save()
        #expect(try store.heardPlaceIDs(since: Self.t0 - 1_000).isEmpty)
    }
    @Test func heardPlaceIDsOnAnEmptyStoreIsEmpty() throws {
        #expect(try store.heardPlaceIDs(since: Self.t0).isEmpty)
    }
    @Test func resetMakesEveryPlaceEligibleAndKeepsHistory() throws {
        let heard = Self.buzz("osm:node/1"), skipped = Self.buzz("osm:node/2")
        try store.recordBuzz(heard, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(skipped, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(heard.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        try store.setBuzzOutcome(skipped.id, .skipped, deepestLevel: 0, at: Self.t0 + 20)
        try store.save(MemoryStoreTests.session(placeID: "osm:node/3", levels: ["one"]))
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["a", "b"]), tripID: Self.trip)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 30) == ["osm:node/1", "osm:node/2", "osm:node/3"])
        let logBefore = try store.buzzLog()

        try store.resetPlaceNotifications()

        #expect(try store.retiredPlaceIDs(now: Self.t0 + 30).isEmpty)
        let one = try #require(try store.place(id: "osm:node/1"))
        let two = try #require(try store.place(id: "osm:node/2"))
        let three = try #require(try store.place(id: "osm:node/3"))
        for place in [one, two, three] { #expect(place.lastHeardAt == nil && place.skippedAt == nil) }
        // History stays: levels heard, last buzz, the buzz log, the stories.
        #expect(one.deepestLevelHeard == 2 && two.deepestLevelHeard == 0 && three.deepestLevelHeard == 1)
        #expect(one.lastBuzzedAt == Self.t0 && two.lastBuzzTripID == Self.trip)
        #expect(try store.buzzLog() == logBefore)
        #expect(try store.context.fetchCount(FetchDescriptor<WalkStoryRecord>()) == 1)
        #expect(try store.context.fetchCount(FetchDescriptor<CaptureRecord>()) == 1)
        #expect(try store.context.fetchCount(FetchDescriptor<StoryRecord>()) == 3)
        // A new hearing retires it again.
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0 + 40)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 50) == ["osm:node/1"])
    }
    @Test func readBuzzIsHeardAndNotClosedAsIgnored() throws {
        // The app's markRead for a logged buzz: outcome heard at level 1, then markHeard; ending walking mode keeps it.
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0 + 10)
        try store.closePendingBuzzes()
        let entry = try #require(try store.buzzLog().first)
        #expect(entry.outcome == .heard && entry.deepestLevel == 1)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 20) == ["osm:node/1"])
    }
    @Test func readChosenStoryHasNoBuzzEntryAndOnlyMarkHeardIsUsed() throws {
        // A chosen story's id has no buzz record: setBuzzOutcome would throw corruptRecord, so the app never calls it
        // for one; markHeard alone retires the place and logs nothing.
        let story = Self.chosenStory("osm:node/7", levels: ["One."])
        #expect(throws: MemoryError.corruptRecord) {
            try store.setBuzzOutcome(story.id, .heard, deepestLevel: 1, at: Self.t0)
        }
        try store.markHeard(try #require(story.place), level: 1, at: Self.t0)
        #expect(try store.buzzLog().isEmpty)
        #expect(try store.retiredPlaceIDs(now: Self.t0) == ["osm:node/7"])
    }
    @Test func resetWithNoPlacesDoesNothing() throws {
        try store.resetPlaceNotifications()
        #expect(try store.context.fetchCount(FetchDescriptor<PlaceRecord>()) == 0)
    }

    // MARK: - stopSpots

    @Test func stopSpotsReturnsTheTripsStopStoriesOnly() throws {
        try store.saveWalkStory(Self.stopStory(north: 0, levels: ["a"]), tripID: Self.trip)
        try store.saveWalkStory(Self.stopStory(north: 500, levels: ["b"], at: 600), tripID: Self.trip)
        // Another trip's stop and this trip's buzz story are excluded.
        try store.saveWalkStory(Self.stopStory(north: 900, levels: ["c"]), tripID: Self.otherTrip)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["d"]), tripID: Self.trip)
        let spots = try store.stopSpots(tripID: Self.trip)
        #expect(spots.count == 2)
        #expect(spots.contains(.at(north: 0)) && spots.contains(.at(north: 500)))
        #expect(try store.stopSpots(tripID: Self.otherTrip) == [.at(north: 900)])
    }
    @Test func stopSpotsIsEmptyForATripWithoutStops() throws {
        #expect(try store.stopSpots(tripID: Self.trip).isEmpty)
    }

    @Test func secondSkipStartsTheRestAgain() throws {
        // Spec 13.1: a place rests 30 days after it was skipped, so the latest skip counts; an earlier one never
        // replaces it.
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 50)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 50)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 20)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 50)
    }
    @Test func skipAfterTheRestRetiresThePlaceAgain() throws {
        // Skipped at t0, rested 31 days (t0 + 31 × 86 400 = t0 + 2 678 400), buzzed and skipped again then: retired
        // again until 30 days after the second skip.
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0)
        let later = Self.t0 + 2_678_400
        #expect(try store.retiredPlaceIDs(now: later).isEmpty)
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.otherTrip, at: later)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: later + 10)
        #expect(try store.retiredPlaceIDs(now: later + 20) == ["osm:node/1"])
    }
    @Test func skippingAnUnknownPlaceCreatesAndRetiresIt() throws {
        try store.markSkipped(Self.candidate("osm:node/9", north: 30), at: Self.t0)
        let place = try #require(try store.place(id: "osm:node/9"))
        #expect(place.name == "Name osm:node/9" && place.firstSeenAt == Self.t0 && place.skippedAt == Self.t0)
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.lastBuzzedAt == nil)
        #expect(Coordinate(latitude: place.latitude, longitude: place.longitude) == .at(north: 30))
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/9"])
    }
    @Test func skipViaOutcomeAfterMarkSkippedKeepsTheLatestSkip() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0 + 5)
        try store.setBuzzOutcome(b.id, .skipped, deepestLevel: 0, at: Self.t0 + 9)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0 + 9)
    }

    @Test func markHeardStoresAnUnknownPlaceAndRetiresIt() throws {
        try store.markHeard(Self.candidate("osm:node/9", north: 30), level: 1, at: Self.t0 + 5)
        let place = try #require(try store.place(id: "osm:node/9"))
        #expect(place.deepestLevelHeard == 1 && place.lastHeardAt == Self.t0 + 5 && place.firstSeenAt == Self.t0 + 5)
        #expect(place.skippedAt == nil && place.lastBuzzedAt == nil)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/9"])
    }
    @Test func markHeardNeverLowersTheDeepestLevel() throws {
        try store.markHeard(Self.candidate("osm:node/1"), level: 2, at: Self.t0)
        try store.markHeard(Self.candidate("osm:node/1"), level: 1, at: Self.t0 + 10)
        let place = try #require(try store.place(id: "osm:node/1"))
        #expect(place.deepestLevelHeard == 2 && place.lastHeardAt == Self.t0 + 10 && place.firstSeenAt == Self.t0)
        try store.markHeard(Self.candidate("osm:node/1"), level: 3, at: Self.t0 + 20)
        #expect(place.deepestLevelHeard == 3)
    }

    // MARK: - Deleting a capture

    private func saveCapture(placeID: String?) throws -> CaptureRecord {
        let session = MemoryStoreTests.session(placeID: placeID, levels: ["one"])
        try store.save(session)
        let id = session.id
        return try #require(try store.context.fetch(FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func deletingThePhotoOnlyPlacesLastCaptureRemovesThePlace() throws {
        let first = try saveCapture(placeID: "osm:node/1")
        let second = try saveCapture(placeID: "osm:node/1")
        try store.deleteCapture(first)
        #expect(try store.place(id: "osm:node/1") != nil)   // another capture still refers to it
        try store.deleteCapture(second)
        #expect(try store.place(id: "osm:node/1") == nil)
        #expect(try store.context.fetchCount(FetchDescriptor<CaptureRecord>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<StoryRecord>()) == 0)
    }
    @Test func deletingAnUnidentifiedCaptureLeavesPlacesAlone() throws {
        let other = try saveCapture(placeID: "osm:node/1")
        let unidentified = try saveCapture(placeID: nil)
        try store.deleteCapture(unidentified)
        #expect(try store.place(id: "osm:node/1") != nil)
        #expect(try store.context.fetch(FetchDescriptor<CaptureRecord>()).map(\.id) == [other.id])
    }
    @Test func aSkippedPlaceIsKept() throws {
        let capture = try saveCapture(placeID: "osm:node/1")
        try store.markSkipped(Self.candidate("osm:node/1"), at: Self.t0)
        try store.deleteCapture(capture)
        #expect(try store.place(id: "osm:node/1")?.skippedAt == Self.t0)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/1"])
    }
    @Test func aBuzzedPlaceIsKept() throws {
        let capture = try saveCapture(placeID: "osm:node/1")
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        try store.deleteCapture(capture)
        #expect(try store.place(id: "osm:node/1")?.lastBuzzedAt == Self.t0)
    }
    @Test func aPlaceHeardOrSkippedThroughAWalkBuzzIsKeptEvenWithoutLastBuzzedAt() throws {
        for outcome in [BuzzOutcome.heard, .skipped] {
            let id = "osm:node/\(outcome.rawValue)"
            let capture = try saveCapture(placeID: id)
            let b = Self.buzz(id)
            try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
            try store.setBuzzOutcome(b.id, outcome, deepestLevel: 1, at: Self.t0 + 5)
            // Only the buzz log says the walk touched it.
            let place = try #require(try store.place(id: id))
            place.lastBuzzedAt = nil
            place.skippedAt = nil
            try store.context.save()
            try store.deleteCapture(capture)
            #expect(try store.place(id: id) != nil)
        }
    }
    @Test func anIgnoredBuzzAloneDoesNotKeepThePlace() throws {
        // Boundary of the outcome rule: ignored (never answered) is not walk history worth keeping.
        let capture = try saveCapture(placeID: "osm:node/1")
        try store.recordBuzz(Self.buzz("osm:node/1"), tripID: Self.trip, at: Self.t0)
        try store.closePendingBuzzes()
        try #require(try store.place(id: "osm:node/1")).lastBuzzedAt = nil
        try store.context.save()
        try store.deleteCapture(capture)
        #expect(try store.place(id: "osm:node/1") == nil)
    }
    @Test func aPlaceWithAWalkStoryIsKept() throws {
        let capture = try saveCapture(placeID: "osm:node/1")
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"]), tripID: Self.trip)
        try store.deleteCapture(capture)
        #expect(try store.place(id: "osm:node/1") != nil)
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
        clock.date = Self.t0 + 30
        s.levels.append("L2")
        try store.saveWalkStory(s, tripID: Self.trip)
        clock.date = Self.t0 + 90
        try store.saveWalkStory(s, tripID: Self.trip)
        let stories = try store.context.fetch(FetchDescriptor<StoryRecord>()).sorted { $0.level < $1.level }
        #expect(stories.map(\.level) == [1, 2] && stories.map(\.text) == ["L1", "L2"])
        #expect(stories.allSatisfy { $0.placeID == "osm:node/1" && $0.capture == nil && $0.walkStory?.id == s.id })
        // createdAt = when each level was written: L1 at t0, L2 at t0 + 30; the resave at t0 + 90 rewrites neither.
        #expect(stories.map(\.createdAt) == [Self.t0, Self.t0 + 30])
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
    @Test func failedAddressLookupRoundTripsAsLookedUp() throws {
        // The buzz helper has address nil: a lookup that failed. It reads back as failed, not unknown.
        let s = Self.buzzStory("osm:node/1", levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        let r = try #require(try store.walkStory(id: s.id))
        #expect(r.address == nil && r.addressLookedUp)
        #expect(r == s)
    }
    @Test func storySavedBeforeAddressLookupsReadsAsNeverLookedUp() throws {
        // A record from before this change: no address JSON at all.
        let s = Self.stopStory(north: 0, levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        try #require(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first).addressJSON = nil
        let r = try #require(try store.walkStory(id: s.id))
        #expect(r.address == nil && !r.addressLookedUp)
        // Saved again (a level appended on "More"), it stays unknown.
        var next = r
        next.levels.append("two")
        try store.saveWalkStory(next, tripID: Self.trip)
        let again = try #require(try store.walkStory(id: s.id))
        #expect(again.address == nil && !again.addressLookedUp && again.levels == ["one", "two"])
    }
    @Test func walkStoryWithBadAddressJSONIsCorrupt() throws {
        let s = Self.stopStory(north: 0, levels: ["one"])
        try store.saveWalkStory(s, tripID: Self.trip)
        try #require(try store.context.fetch(FetchDescriptor<WalkStoryRecord>()).first).addressJSON = Data("x".utf8)
        #expect(throws: MemoryError.corruptRecord) { try store.walkStory(id: s.id) }
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
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one", "two"], id: b.id), tripID: Self.trip)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        // The place is 5 km away from `near`: found by place ID, not by distance.
        let p = try store.priorStories(placeIDs: ["osm:node/1"], near: .at(north: 5_000), excludingSession: nil)
        // Both levels written in one save at t0: the level breaks the tie, newest (two) first.
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
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        let s = Self.buzzStory("osm:node/1", levels: ["one"], id: b.id)
        try store.saveWalkStory(s, tripID: Self.trip)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).map(\.text) == ["one"])
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: s.id).isEmpty)
    }
    @Test func preparedButUnheardBuzzStoryIsNotAPrior() throws {
        // Ruling 26: the story is saved when the buzz goes out; nobody has heard it yet.
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"], id: b.id), tripID: Self.trip)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).isEmpty)
        // Ignored (walking mode ended without an answer) is still unheard.
        try store.closePendingBuzzes()
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).isEmpty)
    }
    @Test func onlyTheHeardLevelsOfABuzzStoryArePriors() throws {
        // Two levels stored, level 1 heard: deepestLevel 1, so level 1 ≤ 1 counts and level 2 > 1 does not.
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one", "two"], id: b.id), tripID: Self.trip)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 1, at: Self.t0 + 10)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).map(\.text) == ["one"])
        // Hearing level 2 later makes it count too, newest first.
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 20)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).map(\.text) == ["two", "one"])
    }
    @Test func buzzStoryWithoutABuzzLogEntryIsNotAPrior() throws {
        // recordBuzz failed: there is no log to say anything was heard.
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"]), tripID: Self.trip)
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).isEmpty)
    }
    @Test func unheardBuzzStoriesDoNotCrowdOutPhotoPriors() throws {
        // 12 unheard buzz levels newer than one photo story: filtered before the limit of 12, so the photo remains.
        try store.save(MemoryStoreTests.session(placeID: "osm:node/1", levels: ["photo"], at: 0))
        for i in 0..<12 {
            let b = Self.buzz("osm:node/1")
            try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
            try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["buzz \(i)"], id: b.id, at: Double(i)), tripID: Self.trip)
        }
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).map(\.text) == ["photo"])
    }
    @Test func stopStoryIsStillAPriorWithBuzzStoriesAround() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["buzz"], id: b.id, at: 5), tripID: Self.trip)
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["stop"]), tripID: Self.trip)
        // The stop story has no buzz log entry and counts anyway; the unheard buzz story does not.
        #expect(try store.priorStories(placeIDs: ["osm:node/1"], near: .at(), excludingSession: nil).map(\.text) == ["stop"])
    }
    @Test func photoAndWalkPriorsMixNewestFirst() throws {
        // Photo told at 100 s, 10 m away and unidentified; stop story told at t0 (1 000 000 s), 20 m away.
        clock.date = Date(timeIntervalSince1970: 100)
        try store.save(MemoryStoreTests.session(placeID: nil, n: 10, levels: ["photo"], at: 100))
        clock.date = Self.t0
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["stop"]), tripID: Self.trip)
        let p = try store.priorStories(placeIDs: [], near: .at(), excludingSession: nil)
        #expect(p.map(\.text) == ["stop", "photo"])
    }

    // MARK: - Recent stories

    /// A store whose clock the test sets; `clock.date` stamps every newly stored level.
    final class Clock { var date: Date; init(_ date: Date) { self.date = date } }
    static func clockedStore(_ clock: Clock) throws -> MemoryStore {
        let c = try ModelContainer(for: Schema(MemorySchema.models), configurations: .init(isStoredInMemoryOnly: true))
        return MemoryStore(context: c.mainContext, now: { clock.date })
    }

    @Test func importedPhotoWithAnOldTakenAtIsRecent() throws {
        // A library photo taken in 1970 (takenAt = 100 s) told now (2 000 000 s): the level is stamped 2 000 000,
        // inside the window since 2 000 000 − 10 800 = 1 989 200.
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let store = try Self.clockedStore(clock)
        try store.save(MemoryStoreTests.session(placeID: "osm:node/1", levels: ["photo"], at: 100))
        let r = try store.recentStories(since: clock.date - RecentStories.window, excludingSession: nil)
        #expect(r == [RecentStory(toldAt: clock.date, placeName: "Gate", level: .first, text: "photo", prepared: false)])
    }
    @Test func aLevelAppendedLaterCarriesItsOwnTime() throws {
        // Walk story created at t0; level 1 written at t0 + 100, level 2 at t0 + 400. Before the fix level 2 was
        // stamped createdAt + 1 = t0 + 1.
        let clock = Clock(Self.t0 + 100)
        let store = try Self.clockedStore(clock)
        var s = Self.stopStory(north: 20, levels: ["one"], at: 0)
        try store.saveWalkStory(s, tripID: Self.trip)
        clock.date = Self.t0 + 400
        s.levels.append("two")
        try store.saveWalkStory(s, tripID: Self.trip)
        try store.saveWalkStory(s, tripID: Self.trip)
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        #expect(r.map(\.text) == ["two", "one"])
        #expect(r.map(\.toldAt) == [Self.t0 + 400, Self.t0 + 100])
    }
    @Test func aPhotoLevelAppendedLaterCarriesItsOwnTime() throws {
        // Photo taken at 100 s; level 1 written at 2 000 000, level 2 at 2 000 300; a resave rewrites neither.
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let store = try Self.clockedStore(clock)
        var s = MemoryStoreTests.session(placeID: "osm:node/1", levels: ["one"], at: 100)
        try store.save(s)
        clock.date = Date(timeIntervalSince1970: 2_000_300)
        s.levels.append("two")
        try store.save(s)
        clock.date = Date(timeIntervalSince1970: 2_000_900)
        try store.save(s)
        let r = try store.recentStories(since: Date(timeIntervalSince1970: 1_999_990), excludingSession: nil)
        #expect(r.map(\.text) == ["two", "one"])
        #expect(r.map(\.toldAt) == [Date(timeIntervalSince1970: 2_000_300), Date(timeIntervalSince1970: 2_000_000)])
    }
    @Test func levelsWrittenInOneSaveShareTheTimeAndOrderByLevel() throws {
        // Three levels stored at once (a relaunch catching up): all stamped t0 + 50; level breaks the tie, 3 first.
        let clock = Clock(Self.t0 + 50)
        let store = try Self.clockedStore(clock)
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["one", "two", "three"], at: 0), tripID: Self.trip)
        let r = try store.recentStories(since: Self.t0, excludingSession: nil)
        #expect(r.map(\.text) == ["three", "two", "one"])
        #expect(r.map(\.toldAt) == [Self.t0 + 50, Self.t0 + 50, Self.t0 + 50])
    }

    @Test func pendingBuzzStoryCountsAsPrepared() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one", "two"], id: b.id), tripID: Self.trip)
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        // Only level 1 is prepared; level 2 is not offered yet.
        #expect(r == [RecentStory(toldAt: Self.t0, placeName: "Name osm:node/1", level: .first, text: "one", prepared: true)])
    }
    @Test func heardBuzzStoryListsTheHeardLevelsNotPrepared() throws {
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one", "two", "three"], id: b.id), tripID: Self.trip)
        try store.setBuzzOutcome(b.id, .heard, deepestLevel: 2, at: Self.t0 + 10)
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        // All three written at t0, so the level breaks the tie; level 3 > deepest 2 is left out.
        #expect(r.map(\.text) == ["two", "one"] && r.map(\.prepared) == [false, false])
        #expect(r.map(\.placeName) == ["Name osm:node/1", "Name osm:node/1"])
    }
    @Test func ignoredAndSkippedBuzzStoriesAreNotRecent() throws {
        let ignored = Self.buzz("osm:node/1"), skipped = Self.buzz("osm:node/2")
        try store.recordBuzz(ignored, tripID: Self.trip, at: Self.t0)
        try store.recordBuzz(skipped, tripID: Self.trip, at: Self.t0)
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"], id: ignored.id), tripID: Self.trip)
        try store.saveWalkStory(Self.buzzStory("osm:node/2", levels: ["two"], id: skipped.id), tripID: Self.trip)
        try store.setBuzzOutcome(skipped.id, .skipped, deepestLevel: 0, at: Self.t0 + 5)
        try store.closePendingBuzzes()
        #expect(try store.recentStories(since: Self.t0 - 10, excludingSession: nil).isEmpty)
    }
    @Test func buzzStoryWithoutABuzzLogEntryIsNotRecent() throws {
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"]), tripID: Self.trip)
        #expect(try store.recentStories(since: Self.t0 - 10, excludingSession: nil).isEmpty)
    }
    @Test func stopStoryHasNoPlaceName() throws {
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["stop"]), tripID: Self.trip)
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        #expect(r == [RecentStory(toldAt: Self.t0, placeName: nil, level: .first, text: "stop", prepared: false)])
    }
    @Test func photoSessionUsesTheCaptureSubject() throws {
        clock.date = Date(timeIntervalSince1970: 2_000_000)
        try store.save(MemoryStoreTests.session(placeID: "osm:node/1", levels: ["photo"], at: 2_000_000))
        let r = try store.recentStories(since: Date(timeIntervalSince1970: 1_999_990), excludingSession: nil)
        #expect(r == [RecentStory(toldAt: Date(timeIntervalSince1970: 2_000_000), placeName: "Gate", level: .first,
                                  text: "photo", prepared: false)])
    }
    @Test func storiesBeforeSinceAreExcludedAndSinceItselfIsIncluded() throws {
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["old"], at: 0), tripID: Self.trip)
        clock.date = Self.t0 + 100
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["edge"], at: 100), tripID: Self.trip)
        // since = t0 + 100: "old" (t0) is out, "edge" (exactly t0 + 100) is in.
        #expect(try store.recentStories(since: Self.t0 + 100, excludingSession: nil).map(\.text) == ["edge"])
        #expect(try store.recentStories(since: Self.t0 + 101, excludingSession: nil).isEmpty)
    }
    @Test func atMostTenNewestStoriesAreReturned() throws {
        // 12 stop stories written at t0 + 0 ... 11; the 10 newest are 11 down to 2.
        for i in 0..<12 {
            clock.date = Self.t0 + Double(i)
            try store.saveWalkStory(Self.stopStory(north: 20, levels: ["s\(i)"], at: Double(i)), tripID: Self.trip)
        }
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        #expect(r.count == RecentStories.limit)
        #expect(r.map(\.text) == (2...11).reversed().map { "s\($0)" })
    }
    @Test func excludingSessionDropsThatWalkStoryAndThatCapture() throws {
        // Written at: stop t0 + 5, buzz t0, photo t0 + 50.
        let stop = Self.stopStory(north: 20, levels: ["stop"], at: 5)
        clock.date = Self.t0 + 5
        try store.saveWalkStory(stop, tripID: Self.trip)
        let b = Self.buzz("osm:node/1")
        try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
        clock.date = Self.t0
        try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["one"], id: b.id), tripID: Self.trip)
        let photo = MemoryStoreTests.session(placeID: nil, levels: ["photo"], at: 1_000_050)
        clock.date = Self.t0 + 50
        try store.save(photo)
        let since = Self.t0 - 10
        #expect(try store.recentStories(since: since, excludingSession: nil).count == 3)
        #expect(try store.recentStories(since: since, excludingSession: stop.id).map(\.text) == ["photo", "one"])
        #expect(try store.recentStories(since: since, excludingSession: b.id).map(\.text) == ["photo", "stop"])
        #expect(try store.recentStories(since: since, excludingSession: photo.id).map(\.text) == ["stop", "one"])
    }
    @Test func equalTimeAndLevelAreOrderedByTextWhateverTheInsertionOrder() throws {
        // Two stop stories, both level 1 at t0: the tiebreaker is the text, descending ("b" before "a").
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["a"]), tripID: Self.trip)
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["b"]), tripID: Self.trip)
        #expect(try store.recentStories(since: Self.t0 - 10, excludingSession: nil).map(\.text) == ["b", "a"])
        let other = try WalkMemoryTests()
        try other.store.saveWalkStory(Self.stopStory(north: 20, levels: ["b"]), tripID: Self.trip)
        try other.store.saveWalkStory(Self.stopStory(north: 20, levels: ["a"]), tripID: Self.trip)
        #expect(try other.store.recentStories(since: Self.t0 - 10, excludingSession: nil).map(\.text) == ["b", "a"])
    }
    @Test func unheardBuzzStoriesDoNotCrowdOutTheLimit() throws {
        // 12 ignored buzz stories newer than one stop story: filtered before the limit of 10, so the stop story remains.
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["stop"], at: 0), tripID: Self.trip)
        for i in 0..<12 {
            let b = Self.buzz("osm:node/1")
            try store.recordBuzz(b, tripID: Self.trip, at: Self.t0)
            try store.saveWalkStory(Self.buzzStory("osm:node/1", levels: ["b\(i)"], id: b.id, at: Double(i + 1)), tripID: Self.trip)
            try store.setBuzzOutcome(b.id, .ignored, deepestLevel: 0, at: Self.t0 + 50)
        }
        #expect(try store.recentStories(since: Self.t0 - 10, excludingSession: nil).map(\.text) == ["stop"])
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

    // MARK: - Chosen stories

    static func chosenStory(_ placeID: String, levels: [String], id: UUID = UUID()) -> WalkStory {
        var story = buzzStory(placeID, levels: levels, id: id)
        story.kind = .chosen
        return story
    }

    @Test func savingAChosenStoryStoresItsPlaceUnheardAndPlayingRetiresIt() throws {
        let story = Self.chosenStory("osm:node/7", levels: ["One."])
        try store.saveWalkStory(story, tripID: Self.trip)
        let place = try #require(try store.place(id: "osm:node/7"))
        #expect(place.deepestLevelHeard == 0 && place.lastHeardAt == nil && place.name == "Name osm:node/7")
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000).isEmpty)
        try store.markHeard(try #require(story.place), level: 1, at: Self.t0 + 5)
        #expect(try store.retiredPlaceIDs(now: Self.t0 + 1_000) == ["osm:node/7"])
    }

    @Test func savingAStopStoryStillStoresNoPlace() throws {
        try store.saveWalkStory(Self.stopStory(north: 20, levels: ["Stop."]), tripID: Self.trip)
        #expect(try store.context.fetch(FetchDescriptor<PlaceRecord>()).isEmpty)
    }

    @Test func chosenStoryIsRecentWithItsPlaceNameAtEveryLevel() throws {
        let id = UUID()
        try store.saveWalkStory(Self.chosenStory("osm:node/7", levels: ["One.", "Two."], id: id), tripID: Self.trip)
        let r = try store.recentStories(since: Self.t0 - 10, excludingSession: nil)
        // No buzz record: both levels count as told (not prepared), named after the stored place.
        #expect(r.count == 2)
        #expect(r.allSatisfy { $0.placeName == "Name osm:node/7" && !$0.prepared })
        #expect(Set(r.map(\.text)) == ["One.", "Two."])
        #expect(try store.recentStories(since: Self.t0 - 10, excludingSession: id).isEmpty)
    }

    @Test func priorStoriesByPlaceFindChosenStories() throws {
        try store.saveWalkStory(Self.chosenStory("osm:node/7", levels: ["One."]), tripID: Self.trip)
        let found = try store.priorStories(placeIDs: ["osm:node/7"], near: .at(north: 5_000), excludingSession: nil)
        #expect(found.map(\.text) == ["One."] && found.first?.placeID == "osm:node/7")
        #expect(try store.priorStories(placeIDs: ["osm:node/8"], near: .at(north: 5_000), excludingSession: nil).isEmpty)
    }
}
