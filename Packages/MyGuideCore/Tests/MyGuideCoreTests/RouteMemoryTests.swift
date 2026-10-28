import Foundation
import Testing
@testable import MyGuideCore

@Suite struct RouteMemoryTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    func sample(north: Double = 0, east: Double = 0, t: Double) -> TrackSample {
        TrackSample(at: Self.t0.addingTimeInterval(t), coordinate: .at(north: north, east: east))
    }

    func address(_ line: String) -> Address { Address(line: line, city: "Trondheim") }

    @Test func bearingFrom100mBack() throws {
        // samples every 10 m due north for 150 m: newest at 150 m, the sample 100 m back is at 50 m, due south of it
        // → bearing from 50 m to 150 m is 0 (north).
        var r = RouteMemory()
        for i in 0...15 { r.add(sample(north: Double(i) * 10, t: Double(i) * 7)) }
        let b = try #require(r.walkingBearing)
        #expect(abs(b - 0) < 0.5)
    }

    @Test func bearingUses100mBackNotOldestOnATurn() throws {
        // 100 m east (0…100 east), then 100 m north (to 100 north): newest at path 200; 100 m back is the corner
        // (east 100, north 0) → due north, bearing 0. Using the oldest sample would give atan2(100,100) = 45.
        var r = RouteMemory()
        for i in 0...10 { r.add(sample(east: Double(i) * 10, t: Double(i) * 7)) }
        for i in 1...10 { r.add(sample(north: Double(i) * 10, east: 100, t: 70 + Double(i) * 7)) }
        let b = try #require(r.walkingBearing)
        #expect(abs(b - 0) < 0.5)
    }

    @Test func shortPathUsesOldestSample() throws {
        // 0 → 30 m east: path 30 ≥ 20 → bearing 90
        var r = RouteMemory()
        r.add(sample(east: 0, t: 0)); r.add(sample(east: 30, t: 20))
        let b = try #require(r.walkingBearing)
        #expect(abs(b - 90) < 0.5)
    }

    @Test func exactly20mPathHasBearing() throws {
        // path 20 m = minimumBearingPath (boundary, inclusive): 20 m south → bearing 180
        var r = RouteMemory()
        r.add(sample(north: 20, t: 0)); r.add(sample(north: 0, t: 10))
        let b = try #require(r.walkingBearing)
        #expect(abs(b - 180) < 0.5)
    }

    @Test func under20mHasNoBearing() {
        // path 15 m < 20
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.add(sample(north: 15, t: 10))
        #expect(r.walkingBearing == nil)
        #expect(r.context(address: nil, course: 270, now: Self.t0).bearing == 270)
        #expect(r.context(address: nil, course: -1, now: Self.t0).bearing == nil)
        #expect(r.context(address: nil, course: .nan, now: Self.t0).bearing == nil)
        #expect(r.context(address: nil, course: nil, now: Self.t0).bearing == nil)
        #expect(r.context(address: nil, course: 0, now: Self.t0).bearing == 0)
    }

    @Test func pathBearingWinsOverCourse() throws {
        // 30 m east → path bearing 90, the course 270 is ignored
        var r = RouteMemory()
        r.add(sample(east: 0, t: 0)); r.add(sample(east: 30, t: 20))
        let b = try #require(r.context(address: nil, course: 270, now: Self.t0).bearing)
        #expect(abs(b - 90) < 0.5)
    }

    @Test func emptyMemoryHasNothing() {
        let r = RouteMemory()
        #expect(r.walkingBearing == nil)
        #expect(!r.needsStreetLookup)
        #expect(r.recentAddress(near: .at()) == nil)
        let c = r.context(address: nil, course: nil, now: Self.t0)
        #expect(c == WalkContext(address: nil, bearing: nil, street: nil, cameFrom: nil))
    }

    @Test func lookupEvery100mAndFailuresAreNotRetried() {
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0))
        #expect(r.needsStreetLookup)                    // samples, no lookup yet
        r.recordLookup(nil, at: Self.t0)                // failed lookup still resets spacing
        #expect(!r.needsStreetLookup)                   // path since lookup 0 m
        r.add(sample(north: 60, t: 40))
        #expect(!r.needsStreetLookup)                   // 60 < 100
        r.add(sample(north: 99, t: 70))
        #expect(!r.needsStreetLookup)                   // 99 < 100
        r.add(sample(north: 100, t: 80))
        #expect(r.needsStreetLookup)                    // 100 ≥ 100 (boundary)
        r.recordLookup(address("Kirkegata 3"), at: Self.t0.addingTimeInterval(80))
        #expect(!r.needsStreetLookup)
        r.add(sample(north: 200, t: 160))
        #expect(r.needsStreetLookup)                    // 200 - 100 = 100
    }

    @Test func lookupSpacingUsesPathNotStraightLine() {
        // out 60 m east and back to the start: straight line 0, path 120 ≥ 100
        var r = RouteMemory()
        r.add(sample(east: 0, t: 0))
        r.recordLookup(nil, at: Self.t0)
        r.add(sample(east: 60, t: 40))
        #expect(!r.needsStreetLookup)                   // path 60
        r.add(sample(east: 0, t: 80))
        #expect(r.needsStreetLookup)                    // path 120
    }

    @Test func cameFromOldestStreetInWindowWithAlong() throws {
        // samples every 10 m / 8 s; lookups: "Stortorvet 1" at 0 m (t=0), "Kirkegata 3" at 100 m (t=80),
        // "Kirkegata 15" at 200 m (t=160);
        // now t=180 at 220 m north: came from Stortorvet: path 220 ≤ 300, age 180 ≤ 300; distance 220 m,
        // bearing 180 (south), floor(180/60) = 3 min; along Kirkegata (both newer lookups are Kirkegata).
        var r = RouteMemory()
        for i in 0...22 {
            r.add(sample(north: Double(i) * 10, t: Double(i) * 8))
            if i == 0 { r.recordLookup(address("Stortorvet 1"), at: Self.t0) }
            if i == 10 { r.recordLookup(address("Kirkegata 3"), at: Self.t0.addingTimeInterval(80)) }
            if i == 20 { r.recordLookup(address("Kirkegata 15"), at: Self.t0.addingTimeInterval(160)) }
        }
        let now = Self.t0.addingTimeInterval(180)
        let c = r.context(address: address("Kirkegata 21"), course: nil, now: now)
        let from = try #require(c.cameFrom)
        #expect(from.street == "Stortorvet")
        // age = 180 s → floor(180/60) = 3; with 179 s it would still be 2 — see cameFromMinutesAreFloored
        #expect(from.minutesAgo == 3)
        // newest sample at 220 m north, lookup at 0 m → 220 m
        #expect(abs(from.distance - 220) < 0.5)
        // from 220 m north to the origin is due south → 180
        #expect(abs(from.bearing - 180) < 0.5)
        #expect(from.along == "Kirkegata")
        #expect(c.street == "Kirkegata")
    }

    @Test func cameFromMinutesAreFlooredAndSkewClamped() throws {
        // lookup at t=0 at 0 m, newest at 60 m north (t=30). now t=119 → age 119 → floor(119/60) = 1;
        // now t=120 → 2; now before the lookup (t=-50) → age clamped to 0 → 0.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0))
        r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 60, t: 30))
        #expect(try #require(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(119)).cameFrom).minutesAgo == 1)
        #expect(try #require(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(120)).cameFrom).minutesAgo == 2)
        #expect(try #require(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(-50)).cameFrom).minutesAgo == 0)
    }

    @Test func noAlongWithoutCurrentStreetOrWhenSameStreet() throws {
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0))
        r.recordLookup(address("Kirkegata 1"), at: Self.t0)
        r.add(sample(north: 100, t: 60))
        r.recordLookup(address("Kirkegata 9"), at: Self.t0.addingTimeInterval(60))
        let now = Self.t0.addingTimeInterval(70)
        // current address unknown → no current street, no along
        let none = try #require(r.context(address: nil, course: nil, now: now).cameFrom)
        #expect(none.along == nil)
        // the current street is Kirkegata too: no came-from at all (cameFromSkipsTheCurrentStreet)
        #expect(r.context(address: address("Kirkegata 20"), course: nil, now: now).cameFrom == nil)
    }

    @Test func cameFromSkipsTheCurrentStreet() throws {
        // Kirkegata (0 m) → Munkegata (100 m) → newest at 200 m, now on Kirkegata again. The oldest candidate is the
        // current street, so the next one is the came-from: Munkegata, 200 − 100 = 100 m back, due south (180).
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Kirkegata 1"), at: Self.t0)
        r.add(sample(north: 100, t: 70)); r.recordLookup(address("Munkegata 2"), at: Self.t0.addingTimeInterval(70))
        r.add(sample(north: 200, t: 140))
        let now = Self.t0.addingTimeInterval(140)
        let from = try #require(r.context(address: address("Kirkegata 20"), course: nil, now: now).cameFrom)
        #expect(from.street == "Munkegata")
        #expect(abs(from.distance - 100) < 0.5)
        #expect(abs(from.bearing - 180) < 0.5)
        // No newer successful lookup after Munkegata: no along.
        #expect(from.along == nil)
        // Without a current street nothing is skipped: the oldest, Kirkegata, 200 m back.
        let unknown = try #require(r.context(address: nil, course: nil, now: now).cameFrom)
        #expect(unknown.street == "Kirkegata" && abs(unknown.distance - 200) < 0.5)
        // On Munkegata now: Kirkegata (oldest) is the came-from again.
        #expect(r.context(address: address("Munkegata 9"), course: nil, now: now).cameFrom?.street == "Kirkegata")
    }

    @Test func noAlongWhenAnIntermediateLookupWasAnotherStreet() throws {
        // Stortorvet (0 m) → Munkegata (100 m) → Kirkegata (200 m, current): Munkegata ≠ current → no along
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 100, t: 70)); r.recordLookup(address("Munkegata 2"), at: Self.t0.addingTimeInterval(70))
        r.add(sample(north: 200, t: 140)); r.recordLookup(address("Kirkegata 5"), at: Self.t0.addingTimeInterval(140))
        let from = try #require(r.context(address: address("Kirkegata 5"), course: nil, now: Self.t0.addingTimeInterval(140)).cameFrom)
        #expect(from.street == "Stortorvet")
        #expect(from.along == nil)
    }

    @Test func failedLookupsAreNeverCameFrom() throws {
        // failed lookup at 0 m is skipped; the successful one 100 m back is the came-from
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(nil, at: Self.t0)
        r.add(sample(north: 100, t: 70)); r.recordLookup(address("Munkegata 2"), at: Self.t0.addingTimeInterval(70))
        r.add(sample(north: 200, t: 140))
        let from = try #require(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(140)).cameFrom)
        #expect(from.street == "Munkegata")
        // 100 m back
        #expect(abs(from.distance - 100) < 0.5)
    }

    @Test func lookupAtCurrentSpotIsNotCameFrom() {
        // lookup 29 m back (< 30) → nil; 30 m back → included
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 29, t: 20))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(20)).cameFrom == nil)
        r.add(sample(north: 30, t: 22))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(22)).cameFrom?.street == "Stortorvet")
    }

    @Test func cameFromDropsLookupsOlderThan5Minutes() {
        // lookup at t=0, newest 100 m north. now t=300 → age 300 ≤ 300 kept; now t=301 → dropped.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 100, t: 100))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(300)).cameFrom != nil)
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(301)).cameFrom == nil)
    }

    @Test func cameFromDropsLookupsBeyond300mPath() {
        // lookup at 0 m; walk 30 × 10 m = 300 m → path 300 ≤ 300 kept; one more sample to 310 m → dropped.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        for i in 1...30 { r.add(sample(north: Double(i) * 10, t: Double(i) * 5)) }
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(150)).cameFrom != nil)
        r.add(sample(north: 310, t: 155))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(155)).cameFrom == nil)
    }

    @Test func recentAddressReusedWithin50m() {
        // lookup at 0; position 40 m → address; 60 m → nil; newest successful lookup wins; failed ones are ignored
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        #expect(r.recentAddress(near: .at(north: 40))?.line == "Stortorvet 1")
        #expect(r.recentAddress(near: .at(north: 60)) == nil)
        r.add(sample(north: 30, t: 20)); r.recordLookup(nil, at: Self.t0.addingTimeInterval(20))
        #expect(r.recentAddress(near: .at(north: 40))?.line == "Stortorvet 1")
        r.add(sample(north: 80, t: 60)); r.recordLookup(address("Kirkegata 3"), at: Self.t0.addingTimeInterval(60))
        // 80 m position: Kirkegata at 0 m distance wins over Stortorvet (80 m, too far anyway)
        #expect(r.recentAddress(near: .at(north: 80))?.line == "Kirkegata 3")
        // 40 m: both within 50 (Stortorvet 40, Kirkegata 40) → the newest, Kirkegata
        #expect(r.recentAddress(near: .at(north: 40))?.line == "Kirkegata 3")
    }

    @Test func oldSamplesAreTrimmedButLastLookupSurvives() {
        // 50 samples, 10 m apart, 50 s apart → 490 m path, 2450 s. Trimming keeps ≤ 400 m path and ≤ 600 s.
        // Path since the lookup at 0 m is 490 ≥ 100 → needs a lookup. This only checks that trimming the track does
        // not break bearing or spacing; the keep-exceptions for lookups are pinned by the two standing-still tests.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(nil, at: Self.t0)
        for i in 1...49 { r.add(sample(north: Double(i) * 10, t: Double(i) * 50)) }
        #expect(r.needsStreetLookup)
        // bearing still works on the trimmed track (due north)
        #expect(r.walkingBearing != nil)
        r.recordLookup(address("Kirkegata 3"), at: Self.t0.addingTimeInterval(2450))
        #expect(!r.needsStreetLookup)
        // 5 more metres... still within spacing after trimming
        r.add(sample(north: 495, t: 2500))
        #expect(!r.needsStreetLookup)
    }

    @Test func failedLookupSurvivesStandingStillForOverTenMinutes() {
        // failed lookup at t=0, then samples at the same spot until t=700 (> 600 s keepTime): the lookup is stale
        // by age but is the last one, so spacing still counts from it: path 0 < 100 → no new lookup needed.
        // Without the keep-exception the lookup is dropped and `needsStreetLookup` would be true ("no lookup yet").
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(nil, at: Self.t0)
        for t in stride(from: 100.0, through: 700, by: 100) { r.add(sample(north: 0, t: t)) }
        #expect(!r.needsStreetLookup)
    }

    @Test func successfulLookupSurvivesStandingStillForOverTenMinutes() {
        // successful lookup at t=0, then a failed one at t=100 (so the first is neither the last lookup), then standing
        // still until t=800: the first is stale by age but is the last successful one → still reusable at 0 m < 50 m.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 0, t: 100)); r.recordLookup(nil, at: Self.t0.addingTimeInterval(100))
        for t in stride(from: 200.0, through: 800, by: 100) { r.add(sample(north: 0, t: t)) }
        #expect(r.recentAddress(near: .at())?.line == "Stortorvet 1")
    }

    @Test func alongNeedsASuccessfulNewerLookupOnTheCurrentStreet() throws {
        let now = Self.t0.addingTimeInterval(200)
        // came-from is the newest successful lookup (the one at 0 m; the later one is failed) → no evidence
        var a = RouteMemory()
        a.add(sample(north: 0, t: 0)); a.recordLookup(address("Stortorvet 1"), at: Self.t0)
        a.add(sample(north: 100, t: 70)); a.recordLookup(nil, at: Self.t0.addingTimeInterval(70))
        a.add(sample(north: 200, t: 140))
        #expect(try #require(a.context(address: address("Kirkegata 5"), course: nil, now: now).cameFrom).along == nil)

        // Stortorvet, two failed lookups, current Kirkegata → unknown in between → nil
        var b = RouteMemory()
        b.add(sample(north: 0, t: 0)); b.recordLookup(address("Stortorvet 1"), at: Self.t0)
        b.add(sample(north: 70, t: 50)); b.recordLookup(nil, at: Self.t0.addingTimeInterval(50))
        b.add(sample(north: 140, t: 100)); b.recordLookup(nil, at: Self.t0.addingTimeInterval(100))
        b.add(sample(north: 200, t: 140))
        #expect(try #require(b.context(address: address("Kirkegata 5"), course: nil, now: now).cameFrom).along == nil)

        // Stortorvet, Kirkegata lookup, current Kirkegata → along Kirkegata
        var c = RouteMemory()
        c.add(sample(north: 0, t: 0)); c.recordLookup(address("Stortorvet 1"), at: Self.t0)
        c.add(sample(north: 100, t: 70)); c.recordLookup(address("Kirkegata 3"), at: Self.t0.addingTimeInterval(70))
        c.add(sample(north: 200, t: 140))
        #expect(try #require(c.context(address: address("Kirkegata 5"), course: nil, now: now).cameFrom).along == "Kirkegata")

        // a newer successful lookup without a street name is unknown too → nil
        var d = RouteMemory()
        d.add(sample(north: 0, t: 0)); d.recordLookup(address("Stortorvet 1"), at: Self.t0)
        d.add(sample(north: 100, t: 70)); d.recordLookup(Address(line: nil, city: "Trondheim"), at: Self.t0.addingTimeInterval(70))
        d.add(sample(north: 200, t: 140))
        #expect(try #require(d.context(address: address("Kirkegata 5"), course: nil, now: now).cameFrom).along == nil)
    }

    @Test func loopBackToTheLookupIsNotCameFrom() {
        // lookup at 0 m; out to 100 m north and back to 10 m north: path 190 ≥ 30, but straight line 10 < 30 → nil.
        // At 50 m north on the way back (path 150, straight 50 ≥ 30) it still counts.
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 100, t: 70))
        r.add(sample(north: 50, t: 110))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(110)).cameFrom?.street == "Stortorvet")
        r.add(sample(north: 10, t: 140))
        #expect(r.context(address: nil, course: nil, now: Self.t0.addingTimeInterval(140)).cameFrom == nil)
    }

    @Test func resetClearsEverything() {
        var r = RouteMemory()
        r.add(sample(north: 0, t: 0)); r.recordLookup(address("Stortorvet 1"), at: Self.t0)
        r.add(sample(north: 100, t: 70))
        r.reset()
        #expect(r.walkingBearing == nil)
        #expect(!r.needsStreetLookup)
        #expect(r.recentAddress(near: .at()) == nil)
        #expect(r.context(address: nil, course: nil, now: Self.t0).cameFrom == nil)
        r.add(sample(north: 0, t: 0))
        #expect(r.needsStreetLookup)                    // fresh: samples, no lookup
    }
}
