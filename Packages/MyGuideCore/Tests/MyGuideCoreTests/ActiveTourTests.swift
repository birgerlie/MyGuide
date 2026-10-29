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
        // 439.9 m north: 500 − 439.9 = 60.1 m from a > 60, and 560.1 m from b → nothing.
        let arrival1 = tour.arrive(at: Self.north(439.9), now: Self.t0)
        #expect(arrival1 == nil)
        // 1060.1 m north: 60.1 m past b, 439.9 m before c → nothing.
        let arrival2 = tour.arrive(at: Self.north(1060.1), now: Self.t0)
        #expect(arrival2 == nil)
        #expect(tour.visited.isEmpty)
        #expect(tour.next == Self.a)
    }

    @Test func aStopPassedOutOfOrderIsVisitedAndNextStays() {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        // At a (500 m): a.
        #expect(tour.arrive(at: Self.north(500), now: Self.t0) == Self.a)
        // 1450 m north: 50 m from c ≤ 60, 450 m from b → c, though b is next; b stays next.
        let third = tour.arrive(at: Self.north(1450), now: Self.t0 + 600)
        #expect(third == Self.c)
        #expect(tour.visited == ["a", "c"])
        #expect(tour.next == Self.b)
        #expect(tour.progress == (done: 2, total: 3))
        // c again: already visited, nothing.
        #expect(tour.arrive(at: Self.north(1500), now: Self.t0 + 610) == nil)
        // Back at b (1000 m): b, and every stop is done.
        #expect(tour.arrive(at: Self.north(1000), now: Self.t0 + 1200) == Self.b)
        #expect(tour.visited == ["a", "c", "b"])
        #expect(tour.next == nil)
    }

    @Test func twoUndoneStopsAheadOfNextAreTakenOnePerCallInPlanOrder() {
        // b at 1000 m and d at 1040 m, both after a. At 1020 m the walker is 20 m from b and from d, 520 m from a.
        let d = Self.stop("d", Self.north(1040))
        var tour = Self.tour([Self.a, Self.b, d])
        #expect(tour.arrive(at: Self.north(1020), now: Self.t0) == Self.b)
        #expect(tour.visited == ["b"])
        #expect(tour.next == Self.a)
        #expect(tour.arrive(at: Self.north(1020), now: Self.t0 + 5) == d)
        #expect(tour.visited == ["b", "d"])
        #expect(tour.arrive(at: Self.north(1020), now: Self.t0 + 10) == nil)
        #expect(tour.next == Self.a)
    }

    // MARK: - Reopen

    @Test func aReopenedStopIsUndoneAndCanBeArrivedAtAgain() {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        _ = tour.arrive(at: Self.north(500), now: Self.t0)
        _ = tour.arrive(at: Self.north(1000), now: Self.t0 + 600)
        #expect(tour.next == Self.c)
        tour.reopen(["a"])
        #expect(tour.visited == ["b"])
        #expect(tour.next == Self.a)
        #expect(tour.progress == (done: 1, total: 3))
        #expect(tour.arrive(at: Self.north(500), now: Self.t0 + 900) == Self.a)
        #expect(tour.visited == ["b", "a"])
    }

    @Test func reopenIgnoresIdsNotVisitedAndLeavesSkipsAlone() {
        var tour = Self.tour([Self.a, Self.b, Self.c])
        tour.skipNext()
        _ = tour.arrive(at: Self.north(1000), now: Self.t0)
        tour.reopen(["a", "c", "zzz"])
        #expect(tour.skipped == ["a"])
        #expect(tour.visited == ["b"])
        tour.reopen([])
        #expect(tour.visited == ["b"])
    }

    @Test func nothingIsReopenedAfterTheFinish() {
        var tour = Self.tour([Self.a])
        _ = tour.arrive(at: Self.north(500), now: Self.t0)
        let finished = tour.reachEnd(at: Self.origin, now: Self.t0 + 900)
        #expect(finished)
        tour.reopen(["a"])
        #expect(tour.visited == ["a"])
        #expect(tour.next == nil)
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
        // A skipped stop is never arrived at: 0 m from a, and b is 500 m on.
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
        // 5460 s after the start, no breaks: 5460 s walking.
        #expect(tour.walkingSeconds == 5460)
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

    @Test func walkingTimeIsNilUntilFinishedAndNeverNegative() {
        var tour = Self.tour([])
        #expect(tour.walkingSeconds == nil)
        // A clock that stepped back: finished 50 s before the start → −50 → 0.
        tour.finishedAt = Self.t0 - 50
        #expect(tour.walkingSeconds == 0)
    }

    @Test func breaksAreLeftOutOfTheWalkingTime() {
        var tour = Self.tour([Self.a])
        // Break 1: t0+600 … t0+900 = 300 s. Break 2: t0+2000 … t0+2100 = 100 s.
        tour.pause(at: Self.t0 + 600)
        // A second pause while one is open keeps the first start.
        tour.pause(at: Self.t0 + 700)
        tour.resume(at: Self.t0 + 900)
        tour.pause(at: Self.t0 + 2000)
        tour.resume(at: Self.t0 + 2100)
        // A resume without a break changes nothing.
        tour.resume(at: Self.t0 + 2500)
        #expect(tour.pausedSeconds == 400)
        #expect(tour.pausedSince == nil)
        tour.skipNext()
        let ended = tour.reachEnd(at: Self.origin, now: Self.t0 + 5860)
        #expect(ended)
        // 5860 − 400 = 5460 s walking.
        #expect(tour.walkingSeconds == 5460)
    }

    @Test func anOpenBreakCountsUpToTheFinish() {
        var tour = Self.tour([])
        tour.pause(at: Self.t0 + 1000)
        tour.finishedAt = Self.t0 + 1600
        // 1600 − 0 − (1600 − 1000) = 1000 s.
        #expect(tour.walkingSeconds == 1000)
        // A break that "ends" before it began (clock back) adds nothing: 1000 − 1000 → max(0, −10) = 0.
        var back = Self.tour([])
        back.pause(at: Self.t0 + 1000)
        back.resume(at: Self.t0 + 990)
        #expect(back.pausedSeconds == 0)
    }

    @Test func noBreakStartsAfterTheFinish() {
        var tour = Self.tour([])
        tour.finishedAt = Self.t0 + 100
        tour.pause(at: Self.t0 + 200)
        #expect(tour.pausedSince == nil)
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
        tour.pausedSeconds = 120
        tour.pausedSince = Self.t0 + 3900
        let decoded = try JSONDecoder().decode(ActiveTour.self, from: JSONEncoder().encode(tour))
        #expect(decoded == tour)
    }

    @Test func decodesWithoutTheOptionalFields() throws {
        let tour = Self.tour([Self.a])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tour)) as? [String: Any])
        object["visited"] = nil
        object["skipped"] = nil
        object["finishedAt"] = nil
        object["pausedSeconds"] = nil
        object["pausedSince"] = nil
        let decoded = try JSONDecoder().decode(ActiveTour.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == tour)
        #expect(decoded.visited.isEmpty)
        #expect(decoded.finishedAt == nil)
        #expect(decoded.pausedSeconds == 0)
        #expect(decoded.pausedSince == nil)
    }

    @Test func aStopsCandidateIsKeptAndOptional() throws {
        let place = Candidate(id: "a", name: "A", coordinate: Self.a.coordinate, kind: "historic=monument",
                              summary: "A monument.", wikipediaTitle: "en:A", tags: ["historic": "monument"])
        var stop = Self.a
        stop.candidate = place
        let decoded = try JSONDecoder().decode(TourStop.self, from: JSONEncoder().encode(stop))
        #expect(decoded.candidate == place)
        // A stop stored before the field existed decodes with none.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) as? [String: Any])
        object["candidate"] = nil
        let old = try JSONDecoder().decode(TourStop.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.candidate == nil)
        #expect(old.id == "a")
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


@Suite struct TourStopDeliveryTests {
    static let t0 = Date(timeIntervalSince1970: 3_000_000)
    static func stop(_ id: String) -> TourStop {
        TourStop(id: id, name: id, coordinate: Coordinate(latitude: 0, longitude: 0), tier: .good, score: 2)
    }

    @Test func deliversAtOnceWhenFree() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        let taken = delivery.take(now: Self.t0, busy: false)
        #expect(taken.deliver == Self.stop("a"))
        #expect(taken.dropped.isEmpty)
        #expect(delivery.isEmpty)
        #expect(delivery.lastDeliveredAt == Self.t0)
        // Nothing held: nothing to hand out.
        #expect(delivery.take(now: Self.t0 + 60, busy: false).deliver == nil)
    }

    @Test func waitsWhileBusy() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        #expect(delivery.take(now: Self.t0 + 10, busy: true).deliver == nil)
        #expect(!delivery.isEmpty)
        // Free again 100 s after arriving: delivered.
        #expect(delivery.take(now: Self.t0 + 100, busy: false).deliver == Self.stop("a"))
    }

    @Test func theHoldTimerStartsWhenTheEngineIsFreeNotAtArrival() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        // Busy for 10 min (a long story): never dropped while busy.
        #expect(delivery.take(now: Self.t0 + 10, busy: true) == (nil, []))
        #expect(delivery.take(now: Self.t0 + 600, busy: true).dropped.isEmpty)
        #expect(delivery.held.first?.freeSince == nil)
        // Free at t0+601: 601 s after arriving, but 0 s free ≤ 180 → delivered, not dropped.
        let taken = delivery.take(now: Self.t0 + 601, busy: false)
        #expect(taken.deliver == Self.stop("a"))
        #expect(taken.dropped.isEmpty)
    }

    @Test func dropsAfterThreeMinutesFree() {
        // a and b arrive at t0; a goes at once, b's timer starts free at t0. No take runs until later (paused).
        func twoStops() -> TourStopDelivery {
            var delivery = TourStopDelivery()
            delivery.arrive(Self.stop("a"), at: Self.t0)
            delivery.arrive(Self.stop("b"), at: Self.t0)
            _ = delivery.take(now: Self.t0, busy: false)
            return delivery
        }
        // t0+180: free 180 s, not more than 180 → kept, and 180 ≥ 30 s since a → delivered.
        var kept = twoStops()
        #expect(kept.take(now: Self.t0 + 180, busy: false) == (Self.stop("b"), []))
        // t0+181: free 181 s > 180 → dropped, nothing delivered.
        var late = twoStops()
        let taken = late.take(now: Self.t0 + 181, busy: false)
        #expect(taken.deliver == nil)
        #expect(taken.dropped.map(\.stop) == [Self.stop("b")])
        #expect(taken.dropped.first?.since == Self.t0)
        #expect(taken.dropped.first?.freeSince == Self.t0)
        #expect(late.isEmpty)
    }

    @Test func aBusyTakeStartsTheTimerAgain() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        delivery.arrive(Self.stop("b"), at: Self.t0)
        _ = delivery.take(now: Self.t0, busy: false)
        // b free since t0; busy at t0+100 stops its timer.
        _ = delivery.take(now: Self.t0 + 100, busy: true)
        // Free again at t0+290: 290 s since arrival, 0 s on the new timer → delivered.
        #expect(delivery.take(now: Self.t0 + 290, busy: false) == (Self.stop("b"), []))
    }

    @Test func removeAllHandsBackTheHeldStopsInArrivalOrder() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        _ = delivery.take(now: Self.t0, busy: false)
        delivery.arrive(Self.stop("b"), at: Self.t0 + 5)
        delivery.arrive(Self.stop("c"), at: Self.t0 + 6)
        let unsent = delivery.removeAll()
        #expect(unsent.map(\.stop) == [Self.stop("b"), Self.stop("c")])
        #expect(unsent.map(\.since) == [Self.t0 + 5, Self.t0 + 6])
        #expect(delivery.isEmpty)
        #expect(delivery.lastDeliveredAt == Self.t0)
        #expect(delivery.removeAll().isEmpty)
    }

    // MARK: - With the tour (the controller's rule: a stop whose buzz never went out is undone again)

    @Test func aDroppedStopIsUndoneAndBuzzesWhenReachedAgain() throws {
        let a = ActiveTourTests.a, b = ActiveTourTests.b
        var tour = ActiveTourTests.tour([a, b])
        var delivery = TourStopDelivery()
        let t0 = ActiveTourTests.t0
        // Arrive at a and b (one per fix); a goes at once, b waits for the 30 s gap, then walking mode is paused.
        let atA = tour.arrive(at: ActiveTourTests.north(500), now: t0)
        delivery.arrive(try #require(atA), at: t0)
        #expect(delivery.take(now: t0, busy: false).deliver == a)
        let atB = tour.arrive(at: ActiveTourTests.north(1000), now: t0 + 1)
        delivery.arrive(try #require(atB), at: t0 + 1)
        #expect(delivery.take(now: t0 + 1, busy: false).deliver == nil)
        #expect(tour.next == nil)
        // Taken again 181 s after b's timer started (t0+1 → t0+182): dropped, and undone in the tour.
        let taken = delivery.take(now: t0 + 182, busy: false)
        #expect(taken.dropped.map(\.stop) == [b])
        tour.reopen(taken.dropped.map(\.stop.id))
        #expect(tour.visited == ["a"])
        #expect(tour.next == b)
        // Reached again: arrives and is held once more.
        let again = tour.arrive(at: ActiveTourTests.north(1000), now: t0 + 600)
        #expect(again == b)
    }

    @Test func stoppingKeepsHeldStopsUnvisited() throws {
        let a = ActiveTourTests.a, b = ActiveTourTests.b
        var tour = ActiveTourTests.tour([a, b])
        var delivery = TourStopDelivery()
        let t0 = ActiveTourTests.t0
        let atA = tour.arrive(at: ActiveTourTests.north(500), now: t0)
        delivery.arrive(try #require(atA), at: t0)
        // Busy (a story plays) when walking mode stops: a never buzzed.
        #expect(delivery.take(now: t0 + 10, busy: true).deliver == nil)
        tour.reopen(delivery.removeAll().map(\.stop.id))
        #expect(tour.visited.isEmpty)
        #expect(tour.next == a)
        #expect(delivery.isEmpty)
    }

    @Test func thirtySecondsBetweenTwoStops() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        delivery.arrive(Self.stop("b"), at: Self.t0 + 5)
        #expect(delivery.take(now: Self.t0 + 5, busy: false).deliver == Self.stop("a"))
        // 29 s after a's buzz (t0+5 → t0+34): b waits; 30 s (t0+35): b goes.
        #expect(delivery.take(now: Self.t0 + 34, busy: false).deliver == nil)
        #expect(delivery.take(now: Self.t0 + 35, busy: false).deliver == Self.stop("b"))
    }

    @Test func oneStopPerTake() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        delivery.arrive(Self.stop("b"), at: Self.t0)
        #expect(delivery.take(now: Self.t0, busy: false).deliver == Self.stop("a"))
        #expect(delivery.held.map(\.stop) == [Self.stop("b")])
    }

    @Test func aClockSetBackDoesNotHoldTheNextStop() {
        var delivery = TourStopDelivery()
        delivery.arrive(Self.stop("a"), at: Self.t0)
        _ = delivery.take(now: Self.t0, busy: false)
        delivery.arrive(Self.stop("b"), at: Self.t0 - 100)
        #expect(delivery.take(now: Self.t0 - 100, busy: false).deliver == Self.stop("b"))
    }

    @Test func limits() {
        #expect(TourStopDelivery.minimumGap == 30)
        #expect(TourStopDelivery.maxHold == 180)
    }
}

@Suite struct TourDistanceStepsTests {
    static let t0 = Date(timeIntervalSince1970: 4_000_000)

    @Test func theFirstStepShowsAtOnce() {
        var steps = TourDistanceSteps()
        #expect(steps.update(6, now: Self.t0) == 6)
        #expect(steps.shown == 6)
    }

    @Test func aOneStepChangeWaitsTenSeconds() {
        var steps = TourDistanceSteps()
        _ = steps.update(6, now: Self.t0)
        // 5 from t0+1: held 9 s at t0+10 → still 6; 10 s at t0+11 → 5.
        #expect(steps.update(5, now: Self.t0 + 1) == 6)
        #expect(steps.update(5, now: Self.t0 + 10) == 6)
        #expect(steps.update(5, now: Self.t0 + 11) == 5)
    }

    @Test func flickeringAtAnEdgeStaysPut() {
        var steps = TourDistanceSteps()
        _ = steps.update(6, now: Self.t0)
        // 5, back to 6, 5 again: each return to the shown step restarts the wait.
        #expect(steps.update(5, now: Self.t0 + 1) == 6)
        #expect(steps.update(6, now: Self.t0 + 8) == 6)
        #expect(steps.update(5, now: Self.t0 + 9) == 6)
        // Held from t0+9: at t0+15 only 6 s.
        #expect(steps.update(5, now: Self.t0 + 15) == 6)
        #expect(steps.update(5, now: Self.t0 + 19) == 5)
    }

    @Test func aTwoStepJumpShowsAtOnce() {
        var steps = TourDistanceSteps()
        _ = steps.update(6, now: Self.t0)
        // |4 − 6| = 2 ≥ 2.
        #expect(steps.update(4, now: Self.t0 + 1) == 4)
        // |7 − 4| = 3.
        #expect(steps.update(7, now: Self.t0 + 2) == 7)
    }

    @Test func aDifferentCandidateRestartsTheWait() {
        var steps = TourDistanceSteps()
        _ = steps.update(6, now: Self.t0)
        _ = steps.update(5, now: Self.t0)
        // 7 is one step from 6 too, a new candidate from t0+5; 5's wait is lost.
        #expect(steps.update(7, now: Self.t0 + 5) == 6)
        #expect(steps.update(7, now: Self.t0 + 14) == 6)
        #expect(steps.update(7, now: Self.t0 + 15) == 7)
    }

    @Test func noDistanceStartsAfresh() {
        var steps = TourDistanceSteps()
        _ = steps.update(6, now: Self.t0)
        #expect(steps.update(nil, now: Self.t0 + 1) == nil)
        #expect(steps.update(5, now: Self.t0 + 2) == 5)
    }
}

@Suite struct ActiveTourStoreTests {
    static func store() -> ActiveTourStore {
        ActiveTourStore(url: FileManager.default.temporaryDirectory
            .appending(path: "ActiveTourStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "ActiveTour.json"))
    }

    @Test func missingIsNil() throws {
        #expect(try Self.store().load() == nil)
    }

    @Test func roundTrip() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var tour = ActiveTourTests.tour([ActiveTourTests.a, ActiveTourTests.b])
        tour.visited = ["a"]
        try store.save(tour)
        #expect(try store.load() == tour)
        // A second save replaces the first.
        tour.skipped = ["b"]
        try store.save(tour)
        #expect(try store.load() == tour)
    }

    @Test func corruptIsADecodingError() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"nope\": 1}".utf8).write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
    }

    @Test func clearRemovesAndMissingDoesNotThrow() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.clear()
        try store.save(ActiveTourTests.tour([]))
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test func anUnreadableFileIsNotTakenForMissing() throws {
        // A directory where the file should be: reading fails with an error that is not "no such file".
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.load() }
        do {
            _ = try store.load()
        } catch {
            #expect(!(error is DecodingError))
        }
    }
}
