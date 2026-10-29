import Foundation
import Testing
@testable import MyGuideCore

@Suite struct ActiveTourTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let origin = Coordinate(latitude: 41.9, longitude: 12.5)
    /// Metres per degree of latitude: 6 371 000 × π / 180 = 111 194.93. Along a meridian the haversine distance is
    /// exactly R × Δφ, so `north(m)` lies m metres from `origin` (to floating-point rounding).
    static let metresPerDegree = 6_371_000.0 * .pi / 180

    static func north(_ metres: Double) -> Coordinate {
        Coordinate(latitude: origin.latitude + metres / metresPerDegree, longitude: origin.longitude)
    }

    static func stop(_ id: String, _ coordinate: Coordinate) -> TourStop {
        TourStop(id: id, name: id.uppercased(), coordinate: coordinate, tier: .top, score: 3)
    }

    /// A loop from `origin` through `stops`, with straight legs between them.
    static func tour(_ stops: [TourStop], kind: TourPlan.Kind = .loop, end: Coordinate = origin) -> ActiveTour {
        let points = [origin] + stops.map(\.coordinate) + [end]
        let legs = zip(points, points.dropFirst()).map {
            RoutedLeg(seconds: 100, metres: 130, path: [$0.0, $0.1], approximate: false)
        }
        let plan = TourPlan(kind: kind, start: origin, end: end, stops: stops, estimatedSeconds: 0, budgetSeconds: 3600)
        return ActiveTour(routed: RoutedTour(plan: plan, legs: legs), startedAt: t0)
    }

    static let a = stop("a", north(500)), b = stop("b", north(1000)), c = stop("c", north(1500))

    // MARK: - Next and progress

    @Test func startsAtTheFirstStop() {
        let tour = Self.tour([Self.a, Self.b, Self.c])
        #expect(tour.next == Self.a)
        #expect(tour.progress == (done: 0, total: 3))
        #expect(tour.visited.isEmpty)
        #expect(tour.skipped.isEmpty)
        #expect(!tour.isFinished)
        #expect(tour.startedAt == Self.t0)
    }

    @Test func nextAfterRestoreWithPartialVisits() throws {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        tour.visited = ["a"]
        let restored = try JSONDecoder().decode(ActiveTour.self, from: JSONEncoder().encode(tour))
        #expect(restored.next == Self.b)
        #expect(restored.progress == (done: 1, total: 3))

        // Visited out of order (b already seen): the first stop neither visited nor skipped is a.
        var outOfOrder = Self.tour([Self.a, Self.b, Self.c])
        outOfOrder.visited = ["b"]
        #expect(outOfOrder.next == Self.a)
        #expect(outOfOrder.progress == (done: 1, total: 3))

        // A visited and a skipped stop: c is next, 2 of 3 done.
        var mixed = Self.tour([Self.a, Self.b, Self.c])
        mixed.visited = ["a"]
        mixed.skipped = ["b"]
        #expect(mixed.next == Self.c)
        #expect(mixed.progress == (done: 2, total: 3))

        // An id that is not a stop of the plan (a changed plan) counts for nothing.
        var stray = Self.tour([Self.a, Self.b, Self.c])
        stray.visited = ["zzz"]
        #expect(stray.next == Self.a)
        #expect(stray.progress == (done: 0, total: 3))
    }

    // MARK: - Arrival

    @Test func arrivesWithin60Metres() {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        // 440.1 m north: 500 − 440.1 = 59.9 m from a ≤ 60 → arrives.
        let arrival1 = tour.arrive(at: Self.north(440.1), now: Self.t0 + 600)
        #expect(arrival1 == Self.a)
        #expect(tour.visited == ["a"])
        #expect(tour.next == Self.b)
        #expect(tour.progress == (done: 1, total: 3))
    }

    @Test func doesNotArriveFartherThan60Metres() {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        // 439.9 m north: 500 − 439.9 = 60.1 m from a > 60 → nothing.
        let arrival1 = tour.arrive(at: Self.north(439.9), now: Self.t0)
        #expect(arrival1 == nil)
        // At b itself (1000 m): b is not next, so nothing either.
        let arrival2 = tour.arrive(at: Self.north(1000), now: Self.t0)
        #expect(arrival2 == nil)
        #expect(tour.visited.isEmpty)
        #expect(tour.next == Self.a)
    }

    @Test func aPositionThatIsNotFiniteNeverArrives() {
        var tour = Self.tour([Self.a])
        let arrival1 = tour.arrive(at: Coordinate(latitude: .nan, longitude: 12.5), now: Self.t0)
        #expect(arrival1 == nil)
        let arrival2 = tour.arrive(at: Coordinate(latitude: 41.9, longitude: .infinity), now: Self.t0)
        #expect(arrival2 == nil)
        #expect(tour.visited.isEmpty)
    }

    @Test func twoStopsCloserThan60MetresAreTakenOnePerCall() {
        // a at 500 m, d at 540 m: 40 m apart. At 520 m the walker is 20 m from both.
        let d = Self.stop("d", Self.north(540))
        var tour = Self.tour([Self.a, d, Self.c])
        let arrival1 = tour.arrive(at: Self.north(520), now: Self.t0)
        #expect(arrival1 == Self.a)
        #expect(tour.visited == ["a"])
        #expect(tour.next == d)
        // The next fix at the same spot takes d.
        let arrival2 = tour.arrive(at: Self.north(520), now: Self.t0 + 5)
        #expect(arrival2 == d)
        #expect(tour.visited == ["a", "d"])
        // c is 980 m away: nothing more.
        let arrival3 = tour.arrive(at: Self.north(520), now: Self.t0 + 10)
        #expect(arrival3 == nil)
    }

    // MARK: - Skip

    @Test func skipMovesToTheNextStop() {
        var tour = Self.tour([Self.a, Self.b])
        tour.skipNext()
        #expect(tour.skipped == ["a"])
        #expect(tour.next == Self.b)
        #expect(tour.progress == (done: 1, total: 2))
        // A skipped stop is never arrived at: 0 m from a, but b (500 m on) is next.
        let arrival1 = tour.arrive(at: Self.a.coordinate, now: Self.t0)
        #expect(arrival1 == nil)
        tour.skipNext()
        #expect(tour.skipped == ["a", "b"])
        #expect(tour.next == nil)
        #expect(tour.progress == (done: 2, total: 2))
        // Nothing left to skip: no change.
        tour.skipNext()
        #expect(tour.skipped == ["a", "b"])
    }

    // MARK: - Finish

    @Test func finishesAtTheEndOnceEveryStopIsDone() {
        var tour = Self.tour([Self.a, Self.b])
        // At the start (the loop's end) with stops left: not finished.
        let ended1 = tour.reachEnd(at: Self.origin, now: Self.t0)
        #expect(!ended1)
        let arrival1 = tour.arrive(at: Self.a.coordinate, now: Self.t0 + 600)
        #expect(arrival1 == Self.a)
        tour.skipNext()
        // 60.1 m from the end: not yet.
        let ended2 = tour.reachEnd(at: Self.north(60.1), now: Self.t0 + 1200)
        #expect(!ended2)
        #expect(!tour.isFinished)
        // 59.9 m from the end: finished.
        let ended3 = tour.reachEnd(at: Self.north(59.9), now: Self.t0 + 5460)
        #expect(ended3)
        #expect(tour.isFinished)
        #expect(tour.finishedAt == Self.t0 + 5460)
        // 5460 s after the start.
        #expect(tour.elapsedSeconds == 5460)
        // Finished once: a second arrival at the end changes nothing.
        let ended4 = tour.reachEnd(at: Self.origin, now: Self.t0 + 6000)
        #expect(!ended4)
        #expect(tour.finishedAt == Self.t0 + 5460)
    }

    @Test func anAToBTourFinishesAtItsDestination() {
        let destination = Self.north(2000)
        var tour = Self.tour([Self.a], kind: .aToB, end: destination)
        tour.visited = ["a"]
        // At the start: 2000 m from the destination.
        let ended1 = tour.reachEnd(at: Self.origin, now: Self.t0)
        #expect(!ended1)
        // 1950 m north: 50 m from the destination.
        let ended2 = tour.reachEnd(at: Self.north(1950), now: Self.t0 + 100)
        #expect(ended2)
        #expect(tour.isFinished)
    }

    @Test func aTourWithoutStopsFinishesAtItsEnd() {
        var tour = Self.tour([], kind: .aToB, end: Self.north(300))
        #expect(tour.next == nil)
        #expect(tour.progress == (done: 0, total: 0))
        let ended1 = tour.reachEnd(at: Self.north(290), now: Self.t0)
        #expect(ended1)
    }

    @Test func nothingArrivesAfterTheFinish() {
        var tour = Self.tour([Self.a])
        tour.skipNext()
        let ended1 = tour.reachEnd(at: Self.origin, now: Self.t0 + 10)
        #expect(ended1)
        // a is skipped and the tour is over.
        let arrival1 = tour.arrive(at: Self.a.coordinate, now: Self.t0 + 20)
        #expect(arrival1 == nil)
        tour.skipNext()
        #expect(tour.skipped == ["a"])
    }

    @Test func elapsedTimeIsNilUntilFinishedAndNeverNegative() {
        var tour = Self.tour([])
        #expect(tour.elapsedSeconds == nil)
        // A clock that stepped back: finished 50 s before the start → 0.
        tour.finishedAt = Self.t0 - 50
        #expect(tour.elapsedSeconds == 0)
    }

    // MARK: - Age

    @Test func staleAfterTwelveHours() {
        let tour = Self.tour([Self.a])
        // 12 h = 43 200 s; stale only when strictly older.
        #expect(!tour.isStale(now: Self.t0 + 43_199))
        #expect(!tour.isStale(now: Self.t0 + 43_200))
        #expect(tour.isStale(now: Self.t0 + 43_201))
        // A clock behind the start is not stale.
        #expect(!tour.isStale(now: Self.t0 - 3600))
    }

    // MARK: - Paths

    @Test func pathsAreSimplifiedWhenTheTourStarts() {
        // A leg with points every 100 m on a straight line: only its two ends are kept.
        let straight = (0...10).map { Self.north(Double($0) * 100) }
        let plan = TourPlan(kind: .aToB, start: Self.origin, end: Self.north(1000), stops: [], estimatedSeconds: 0,
                            budgetSeconds: 3600)
        let routed = RoutedTour(plan: plan, legs: [RoutedLeg(seconds: 770, metres: 1000, path: straight,
                                                             approximate: false)])
        let tour = ActiveTour(routed: routed, startedAt: Self.t0)
        #expect(tour.routed.legs[0].path == [Self.origin, Self.north(1000)])
        // Everything else of the leg and plan is kept.
        #expect(tour.routed.legs[0].seconds == 770)
        #expect(tour.routed.legs[0].metres == 1000)
        #expect(tour.routed.plan == plan)
    }

    // MARK: - Codable

    @Test func roundTripsThroughCodable() throws {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        tour.visited = ["a"]
        tour.skipped = ["b"]
        tour.finishedAt = Self.t0 + 4000
        let decoded = try JSONDecoder().decode(ActiveTour.self, from: JSONEncoder().encode(tour))
        #expect(decoded == tour)
    }

    @Test func decodesWithoutTheOptionalFields() throws {
        let tour = Self.tour([Self.a])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tour)) as? [String: Any])
        object["visited"] = nil
        object["skipped"] = nil
        object["finishedAt"] = nil
        let decoded = try JSONDecoder().decode(ActiveTour.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == tour)
        #expect(decoded.visited.isEmpty)
        #expect(decoded.finishedAt == nil)
    }

    @Test func aStoreWithoutTheRouteDoesNotDecode() throws {
        let tour = Self.tour([Self.a])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tour)) as? [String: Any])
        object["routed"] = nil
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ActiveTour.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}

@Suite struct TourBuzzCadenceTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func allowsTheFirstBuzz() {
        #expect(TourBuzzCadence().allows(at: Self.t0))
    }

    @Test func oneBuzzPer180Seconds() {
        var cadence = TourBuzzCadence()
        cadence.noteBuzz(at: Self.t0)
        // 179 s < 180 → not yet; 180 s ≥ 180 → allowed (inclusive).
        #expect(!cadence.allows(at: Self.t0 + 179))
        #expect(cadence.allows(at: Self.t0 + 180))
        #expect(!cadence.allows(at: Self.t0))
        // The interval counts from the newest buzz.
        cadence.noteBuzz(at: Self.t0 + 200)
        #expect(!cadence.allows(at: Self.t0 + 379))
        #expect(cadence.allows(at: Self.t0 + 380))
    }

    @Test func aClockThatSteppedBackAllows() {
        var cadence = TourBuzzCadence()
        cadence.noteBuzz(at: Self.t0)
        // Before the last buzz: the clock changed; the rule never holds buzzes back for longer than 180 s of real time.
        #expect(cadence.allows(at: Self.t0 - 1))
    }

    @Test func intervalIsThreeMinutes() {
        #expect(TourBuzzCadence.interval == 180)
    }
}
