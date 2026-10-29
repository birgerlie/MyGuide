import Foundation
import Synchronization
import Testing
@testable import MyGuideCore

/// Coordinates come from `.at(north:east:)` on the equator, where a metre north is a metre by haversine (see
/// Support/Metres.swift). A leg's estimate is straight × 1.3 / 1.3 m/s, so its seconds equal its straight metres; each
/// stop adds 240 s of dwell. An approximate leg walks straight × 1.3 metres.
@Suite struct TourRoutingTests {
    static let origin = Coordinate.at()
    static let a = Coordinate.at(north: 100)
    static let b = Coordinate.at(north: 200)
    static let c = Coordinate.at(north: 300)
    /// Leg seconds equal metres up to floating point (× 1.3 / 1.3 and the degree conversion).
    static let tolerance = 1e-3

    static func stop(_ id: String, _ coordinate: Coordinate, score: Double = 2) -> TourStop {
        TourStop(id: id, name: id, coordinate: coordinate, tier: .good, score: score)
    }

    /// A loop from the origin through `stops` with the given budget; the estimate is recomputed the planner's way.
    static func loop(_ stops: [TourStop], budget: Double) -> TourPlan {
        TourPlan(kind: .loop, start: origin, end: origin, stops: stops,
                 estimatedSeconds: TourPlanner.estimatedSeconds(start: origin, stops: stops, end: origin),
                 budgetSeconds: budget)
    }

    /// Records every request and answers with `answer`.
    final class LegStub: Sendable {
        private let calls = Mutex<[[Coordinate]]>([])
        private let answer: @Sendable (Coordinate, Coordinate) async -> RoutedLeg?

        init(_ answer: @escaping @Sendable (Coordinate, Coordinate) async -> RoutedLeg?) {
            self.answer = answer
        }

        /// Routes every leg at `factor` × its estimate (metres = seconds × 1.3 m/s), through a midpoint so a routed path
        /// differs from a straight one.
        static func scaled(_ factor: Double) -> LegStub {
            LegStub { from, to in
                let seconds = factor * TourPlanner.estimatedLegSeconds(from: from, to: to)
                let mid = Coordinate(latitude: (from.latitude + to.latitude) / 2,
                                     longitude: (from.longitude + to.longitude) / 2 + 1e-5)
                return RoutedLeg(seconds: seconds, metres: seconds * 1.3, path: [from, mid, to], approximate: false)
            }
        }

        var requests: [[Coordinate]] { calls.withLock { $0 } }

        @Sendable func leg(_ from: Coordinate, _ to: Coordinate) async -> RoutedLeg? {
            calls.withLock { $0.append([from, to]) }
            return await answer(from, to)
        }
    }

    static func expectStraight(_ leg: RoutedLeg, from: Coordinate, to: Coordinate, metres straight: Double) {
        #expect(leg.approximate)
        #expect(leg.path == [from, to])
        #expect(abs(leg.seconds - straight) < tolerance)
        #expect(abs(leg.metres - straight * 1.3) < tolerance)
    }

    // MARK: - Totals

    @Test func totalsAreTheLegsPlusTheDwellPerStop() {
        let tour = RoutedTour(plan: Self.loop([Self.stop("a", Self.a)], budget: 1000), legs: [
            RoutedLeg(seconds: 100, metres: 130, path: [Self.origin, Self.a], approximate: false),
            RoutedLeg(seconds: 200, metres: 260, path: [Self.a, Self.origin], approximate: false),
        ])
        // 100 + 200 walking + 1 × 240 dwell = 540 s; 130 + 260 = 390 m.
        #expect(tour.totalSeconds == 540)
        #expect(tour.totalMetres == 390)
    }

    @Test func routedTourRoundTripsThroughCodable() throws {
        let tour = RoutedTour(plan: Self.loop([Self.stop("a", Self.a)], budget: 1000), legs: [
            RoutedLeg(seconds: 100, metres: 130, path: [Self.origin, Self.a], approximate: false),
            RoutedLeg(seconds: 100, metres: 130, path: [Self.a, Self.origin], approximate: true),
        ])
        #expect(tour.approximate)
        let decoded = try JSONDecoder().decode(RoutedTour.self, from: JSONEncoder().encode(tour))
        #expect(decoded == tour)
    }

    // MARK: - Fitting

    @Test func fitsOnTheFirstTry() async {
        // Stops a (100 m north) and b (200 m north): estimates O→a 100, a→b 100, b→O 200 s.
        // Routed at 1.2×: 120 + 120 + 240 = 480 s walking + 2 × 240 = 960 s ≤ 1200 × 1.1 = 1320. Nothing is dropped.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub.scaled(1.2)
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)

        // The first legs are routed concurrently, so only the set of requests is fixed.
        #expect(Set(stub.requests) == [[Self.origin, Self.a], [Self.a, Self.b], [Self.b, Self.origin]])
        #expect(stub.requests.count == 3)
        #expect(tour.plan == plan)
        #expect(tour.legs.count == 3)
        #expect(!tour.approximate)
        #expect(tour.legs.allSatisfy { !$0.approximate && $0.path.count == 3 })
        #expect(abs(tour.totalSeconds - 960) < Self.tolerance)
        // Metres = seconds × 1.3: 156 + 156 + 312 = 624 m.
        #expect(abs(tour.totalMetres - 624) < Self.tolerance)
    }

    @Test func overBudgetDropsTheWorstStopAndRoutesOnlyTheJoiningLeg() async {
        // Routed at 3×: O→a 300, a→b 300, b→O 600 → 1200 + 480 = 1680 s > 1200 × 1.1 = 1320.
        // dropWorst: removing a saves 300 + 300 − est(O→b) 200 + 240 = 640 → 2 / 640 = 0.003125;
        //            removing b saves 300 + 600 − est(a→O) 100 + 240 = 1040 → 2 / 1040 = 0.001923 → b goes.
        // The two legs around b (a→b, b→O) give way to one joining leg a→O, routed at 3 × 100 = 300 s; O→a is reused.
        // Then 300 + 300 + 240 = 840 s ≤ 1320.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub.scaled(3)
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)

        #expect(stub.requests.count == 4)
        #expect(Set(stub.requests.prefix(3)) == [[Self.origin, Self.a], [Self.a, Self.b], [Self.b, Self.origin]])
        #expect(stub.requests.last == [Self.a, Self.origin])
        #expect(tour.plan.stops.map(\.id) == ["a"])
        #expect(tour.plan.budgetSeconds == 1200)
        // The estimate is recomputed: 100 + 100 + 240 = 440 s.
        #expect(abs(tour.plan.estimatedSeconds - 440) < Self.tolerance)
        #expect(tour.legs.count == 2)
        #expect(tour.legs.map(\.path.first) == [Self.origin, Self.a])
        #expect(tour.legs.map(\.path.last) == [Self.a, Self.origin])
        #expect(abs(tour.legs[0].seconds - 300) < Self.tolerance)
        #expect(abs(tour.legs[1].seconds - 300) < Self.tolerance)
        #expect(abs(tour.totalSeconds - 840) < Self.tolerance)
        #expect(!tour.approximate)
    }

    @Test func dropsUntilItFitsAndALegToTheSamePointNeedsNoRequest() async {
        // Routed at 10×: 1000 + 1000 + 2000 = 4000 + 480 = 4480 s > 1320.
        // Removing a saves 1000 + 1000 − 200 + 240 = 2040 → 2 / 2040; removing b saves 1000 + 2000 − 100 + 240 = 3140
        // → 2 / 3140, smaller → b goes; a→O is routed at 1000 s. 1000 + 1000 + 240 = 2240 > 1320 → a goes too.
        // Its joining leg is O→O: 0 s and 0 m without a request, and the empty loop fits.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub.scaled(10)
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)

        #expect(stub.requests.count == 4)
        #expect(stub.requests.last == [Self.a, Self.origin])
        #expect(tour.plan.stops.isEmpty)
        #expect(tour.legs == [RoutedLeg(seconds: 0, metres: 0, path: [Self.origin], approximate: false)])
        #expect(tour.totalSeconds == 0)
        #expect(!tour.approximate)
    }

    @Test func aToBStopsDroppingWhenNoStopsRemainAndRecomputesTheBudget() async {
        // A→B from O to 1000 m north through a at 500 m. Direct estimate 1000 s → budget 1.25 × 1000 + 240 = 1490 s.
        // Routed at 2×: 1000 + 1000 + 240 = 2240 > 1490 × 1.1 = 1639 → a goes; the joining leg O→end is 2000 s.
        // The budget is now 1250 (× 1.1 = 1375) and 2000 still exceeds it, but there is nothing left to drop.
        let end = Coordinate.at(north: 1000)
        let stops = [Self.stop("a", .at(north: 500))]
        let plan = TourPlan(kind: .aToB, start: Self.origin, end: end, stops: stops,
                            estimatedSeconds: TourPlanner.estimatedSeconds(start: Self.origin, stops: stops, end: end),
                            budgetSeconds: 1490)
        let stub = LegStub.scaled(2)
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)

        #expect(stub.requests.count == 3)
        #expect(stub.requests.last == [Self.origin, end])
        #expect(tour.plan.stops.isEmpty)
        #expect(abs(tour.plan.budgetSeconds - 1250) < Self.tolerance)
        #expect(tour.legs.count == 1)
        #expect(abs(tour.totalSeconds - 2000) < Self.tolerance)
        #expect(!tour.approximate)
    }

    @Test func aTotalOfExactlyTheAllowanceIsKept() async {
        // One stop a; budget 1000 → limit 1000 × 1.1 = 1100. Legs 430 + 430 + 240 = 1100 ≤ 1100: kept.
        // The limit is exactly 1100 in floating point: 1 + 0.10 rounds to the double nearest 1.1,
        // 1.100000000000000088817841970012523; × 1000 = 1100.0000000000000888, and the doubles next to 1100 are
        // 2.27e-13 apart, so the product rounds to 1100 exactly. The sum 430 + 430 + 240 is exact too.
        let plan = Self.loop([Self.stop("a", Self.a)], budget: 1000)
        let stub = LegStub { from, to in RoutedLeg(seconds: 430, metres: 559, path: [from, to], approximate: false) }
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)
        #expect(tour.plan.stops.map(\.id) == ["a"])
        #expect(tour.totalSeconds == 1100)
        #expect(stub.requests.count == 2)
    }

    @Test func aTotalJustOverTheAllowanceDropsTheStop() async {
        // Legs 430 + 431 + 240 = 1101 > 1100: a goes; the joining leg O→O needs no request.
        let plan = Self.loop([Self.stop("a", Self.a)], budget: 1000)
        let stub = LegStub { from, to in
            RoutedLeg(seconds: from == Self.origin ? 430 : 431, metres: 559, path: [from, to], approximate: false)
        }
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)
        #expect(tour.plan.stops.isEmpty)
        #expect(tour.totalSeconds == 0)
        #expect(stub.requests.count == 2)
    }

    // MARK: - Request cap

    @Test func theRequestCapLeavesTheRestApproximate() async {
        // Three stops (100, 200, 300 m north), four legs, two requests: O→a and a→b are routed at 1× (100 s each);
        // b→c (100 m) and c→O (300 m) become straight legs of 100 s / 130 m and 300 s / 390 m.
        // Total 100 + 100 + 100 + 300 = 600 + 3 × 240 = 1320 s ≤ 1800 × 1.1.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b), Self.stop("c", Self.c)], budget: 1800)
        let stub = LegStub.scaled(1)
        let tour = await TourRouting.fit(plan, maxRequests: 2, leg: stub.leg)

        // Slots go out in leg order, so the first two legs get them whatever order they answer in.
        #expect(Set(stub.requests) == [[Self.origin, Self.a], [Self.a, Self.b]])
        #expect(stub.requests.count == 2)
        #expect(!tour.legs[0].approximate && !tour.legs[1].approximate)
        Self.expectStraight(tour.legs[2], from: Self.b, to: Self.c, metres: 100)
        Self.expectStraight(tour.legs[3], from: Self.c, to: Self.origin, metres: 300)
        #expect(tour.approximate)
        #expect(abs(tour.totalSeconds - 1320) < Self.tolerance)
        // 130 + 130 (routed, seconds × 1.3) + 130 + 390 = 780 m.
        #expect(abs(tour.totalMetres - 780) < Self.tolerance)
        #expect(tour.plan == plan)
    }

    @Test func aJoiningLegPastTheCapIsApproximate() async {
        // As the 3× case: 1680 s > 1320, b goes. The cap of 3 is spent, so a→O is a straight leg: 100 s, 130 m.
        // 300 + 100 + 240 = 640 s.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub.scaled(3)
        let tour = await TourRouting.fit(plan, maxRequests: 3, leg: stub.leg)

        #expect(stub.requests.count == 3)
        #expect(tour.plan.stops.map(\.id) == ["a"])
        #expect(!tour.legs[0].approximate)
        Self.expectStraight(tour.legs[1], from: Self.a, to: Self.origin, metres: 100)
        #expect(tour.approximate)
        #expect(abs(tour.totalSeconds - 640) < Self.tolerance)
    }

    @Test func noRequestsAllowedGivesAStraightTour() async {
        // O→a 100, a→O 100 → 200 + 240 = 440 s, all straight; a cap below zero counts as zero.
        let plan = Self.loop([Self.stop("a", Self.a)], budget: 1200)
        for cap in [0, -3] {
            let stub = LegStub.scaled(1)
            let tour = await TourRouting.fit(plan, maxRequests: cap, leg: stub.leg)
            #expect(stub.requests.isEmpty)
            Self.expectStraight(tour.legs[0], from: Self.origin, to: Self.a, metres: 100)
            Self.expectStraight(tour.legs[1], from: Self.a, to: Self.origin, metres: 100)
            #expect(tour.approximate)
            #expect(abs(tour.totalSeconds - 440) < Self.tolerance)
        }
    }

    // MARK: - Failures

    @Test func aFailingLegBecomesApproximateAndMarksTheTour() async {
        // a→b fails: a straight leg of 100 s / 130 m. O→a 100 and b→O 200 are routed at 1×.
        // 100 + 100 + 200 + 480 = 880 s ≤ 1320.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub { from, to in
            from == Self.a && to == Self.b ? nil : RoutedLeg(seconds: TourPlanner.estimatedLegSeconds(from: from, to: to),
                                                             metres: 1, path: [from, to], approximate: false)
        }
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)

        #expect(stub.requests.count == 3)
        #expect(!tour.legs[0].approximate && !tour.legs[2].approximate)
        Self.expectStraight(tour.legs[1], from: Self.a, to: Self.b, metres: 100)
        #expect(tour.approximate)
        #expect(abs(tour.totalSeconds - 880) < Self.tolerance)
        #expect(tour.plan == plan)
    }

    @Test func everyLegFailingGivesTheStraightTour() async {
        // Routing unavailable: O→a 100, a→b 100, b→O 200 straight; 400 + 480 = 880 s.
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub { _, _ in nil }
        let tour = await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)
        #expect(stub.requests.count == 3)
        #expect(tour.legs.allSatisfy { $0.approximate })
        #expect(tour.approximate)
        #expect(abs(tour.totalSeconds - 880) < Self.tolerance)
        #expect(tour.plan == plan)
    }

    @Test func aNonsenseLegCountsAsFailed() async {
        // Each nonsense answer becomes the straight leg O→a: 100 s, 130 m.
        let nonsense: [RoutedLeg] = [
            RoutedLeg(seconds: .nan, metres: 100, path: [], approximate: false),
            RoutedLeg(seconds: .infinity, metres: 100, path: [], approximate: false),
            RoutedLeg(seconds: -1, metres: 100, path: [], approximate: false),
            RoutedLeg(seconds: 100, metres: .nan, path: [], approximate: false),
            RoutedLeg(seconds: 100, metres: -5, path: [], approximate: false),
        ]
        for answer in nonsense {
            let stub = LegStub { _, _ in answer }
            // An A→B with no stops: one leg, O → a.
            let direct = TourPlan(kind: .aToB, start: Self.origin, end: Self.a, stops: [], estimatedSeconds: 100,
                                  budgetSeconds: 125)
            let tour = await TourRouting.fit(direct, maxRequests: 25, leg: stub.leg)
            #expect(stub.requests.count == 1)
            Self.expectStraight(tour.legs[0], from: Self.origin, to: Self.a, metres: 100)
            #expect(tour.approximate)
        }
    }

    @Test func aRoutedLegWithoutAPathKeepsItsTimeAndGetsTheStraightLine() async {
        let direct = TourPlan(kind: .aToB, start: Self.origin, end: Self.a, stops: [], estimatedSeconds: 100,
                              budgetSeconds: 125)
        let stub = LegStub { _, _ in RoutedLeg(seconds: 110, metres: 140, path: [], approximate: false) }
        let tour = await TourRouting.fit(direct, maxRequests: 25, leg: stub.leg)
        #expect(tour.legs == [RoutedLeg(seconds: 110, metres: 140, path: [Self.origin, Self.a], approximate: false)])
        #expect(!tour.approximate)
    }

    @Test func aLegTheRouterMarksApproximateMarksTheTour() async {
        let direct = TourPlan(kind: .aToB, start: Self.origin, end: Self.a, stops: [], estimatedSeconds: 100,
                              budgetSeconds: 125)
        let stub = LegStub { from, to in RoutedLeg(seconds: 110, metres: 140, path: [from, to], approximate: true) }
        let tour = await TourRouting.fit(direct, maxRequests: 25, leg: stub.leg)
        #expect(tour.legs[0].approximate)
        #expect(tour.approximate)
    }

    // MARK: - Cancellation

    @Test func aCancelledCallerMakesNoRequests() async {
        let plan = Self.loop([Self.stop("a", Self.a), Self.stop("b", Self.b)], budget: 1200)
        let stub = LegStub.scaled(1)
        let tour = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg)
        }.value
        #expect(stub.requests.isEmpty)
        // All straight: 100 + 100 + 200 + 480 = 880 s.
        #expect(tour.legs.allSatisfy { $0.approximate })
        #expect(abs(tour.totalSeconds - 880) < Self.tolerance)
    }

    @Test func cancellationWhileTheFirstLegsAreInFlightStopsEverything() async {
        // Five stops 100…500 m north: six legs. Slots go to legs 0–3 before the parent first waits. The fourth request
        // cancels the tour, and every request answers only once it sees the cancellation, so the parent wakes up
        // cancelled: legs 4 (400 → 500 m, 100 m) and 5 (500 m → O, 500 m) are straight without a request. The total,
        // 4 × 100 + 100 + 500 = 1000 s walking + 5 × 240 = 2200 s, is far over 100 × 1.1 = 110, yet no stop is dropped.
        let stops = (1...5).map { Self.stop("s\($0)", .at(north: Double($0) * 100)) }
        let plan = Self.loop(stops, budget: 100)
        let tourTask = Mutex<Task<RoutedTour, Never>?>(nil)
        let count = Mutex(0)
        let stub = LegStub { from, to in
            if count.withLock({ $0 += 1; return $0 }) == 4 {
                await Self.wait { tourTask.withLock { $0 } != nil }
                tourTask.withLock { $0 }?.cancel()
            }
            await Self.wait { Task.isCancelled }
            return RoutedLeg(seconds: TourPlanner.estimatedLegSeconds(from: from, to: to), metres: 1, path: [from, to],
                             approximate: false)
        }
        let task = Task { await TourRouting.fit(plan, maxRequests: 25, leg: stub.leg) }
        tourTask.withLock { $0 = task }
        let tour = await task.value

        #expect(stub.requests.count == 4)
        #expect(tour.plan.stops.count == 5)
        #expect(tour.legs.count == 6)
        #expect(tour.legs.prefix(4).allSatisfy { !$0.approximate })
        Self.expectStraight(tour.legs[4], from: .at(north: 400), to: .at(north: 500), metres: 100)
        Self.expectStraight(tour.legs[5], from: .at(north: 500), to: Self.origin, metres: 500)
    }

    // MARK: - Concurrency

    /// Waits until `condition` holds, at most about 2 s.
    static func wait(until condition: @Sendable () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Twelve stops 100…1200 m north of the origin: thirteen legs.
    static let twelveStops = (1...12).map { stop("s\($0)", .at(north: Double($0) * 100)) }
    static var twelvePoints: [Coordinate] { [origin] + twelveStops.map(\.coordinate) + [origin] }

    @Test func atMostFourFirstLegsAreInFlight() async {
        // Each request holds until four have been in flight at once (or about 2 s), then a little longer, so an
        // unbounded fan-out would show all thirteen at once and a serial one would never reach four.
        let flight = Mutex((now: 0, peak: 0))
        let stub = LegStub { from, to in
            flight.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            await Self.wait { flight.withLock { $0.peak } >= 4 }
            try? await Task.sleep(for: .milliseconds(5))
            flight.withLock { $0.now -= 1 }
            return RoutedLeg(seconds: TourPlanner.estimatedLegSeconds(from: from, to: to), metres: 1, path: [from, to],
                             approximate: false)
        }
        // A generous budget: nothing is dropped, so every request is a first leg.
        let tour = await TourRouting.fit(Self.loop(Self.twelveStops, budget: 100_000), maxRequests: 25, leg: stub.leg)
        #expect(stub.requests.count == 13)
        #expect(flight.withLock { $0.peak } == TourRouting.maxConcurrentRequests)
        #expect(TourRouting.maxConcurrentRequests == 4)
        #expect(!tour.approximate)
    }

    @Test func answersArrivingOutOfOrderLandInLegOrder() async {
        // Leg i answers after (14 − i) × 2 ms, so later legs answer first; each answer carries its own ends.
        let points = Self.twelvePoints
        let stub = LegStub { from, to in
            let index = points.indices.first { points[$0] == from && points[$0 + 1] == to } ?? 0
            try? await Task.sleep(for: .milliseconds(2 * (14 - index)))
            return RoutedLeg(seconds: Double(index), metres: 1, path: [from, Self.a, to], approximate: false)
        }
        let tour = await TourRouting.fit(Self.loop(Self.twelveStops, budget: 100_000), maxRequests: 25, leg: stub.leg)
        #expect(tour.legs.count == 13)
        for (index, leg) in tour.legs.enumerated() {
            #expect(leg.seconds == Double(index))
            #expect(leg.path == [points[index], Self.a, points[index + 1]])
        }
    }

    @Test func theCapIsExactWhenSmallerThanTheFirstLegs() async {
        // Cap 6 of 13 legs: exactly legs 0–5 are requested; 6–12 are straight.
        let points = Self.twelvePoints
        let stub = LegStub.scaled(1)
        let tour = await TourRouting.fit(Self.loop(Self.twelveStops, budget: 100_000), maxRequests: 6, leg: stub.leg)
        #expect(stub.requests.count == 6)
        #expect(Set(stub.requests) == Set((0..<6).map { [points[$0], points[$0 + 1]] }))
        #expect(tour.legs.prefix(6).allSatisfy { !$0.approximate })
        for index in 6..<13 {
            #expect(tour.legs[index].approximate)
            #expect(tour.legs[index].path == [points[index], points[index + 1]])
        }
    }

    // MARK: - Which leg joins

    /// Three stops a, b, c (100, 200, 300 m north), routed at 3×: O→a 300, a→b 300, b→c 300, c→O 900 →
    /// 1800 + 3 × 240 = 2520 s > 2100 × 1.1 = 2310. Savings (joining estimates O→b, a→c, b→O are 200 each):
    /// a 300 + 300 − 200 + 240 = 640, b 300 + 300 − 200 + 240 = 640, c 300 + 900 − 200 + 240 = 1240.
    static func threeStops(scores: (Double, Double, Double)) -> TourPlan {
        loop([stop("a", a, score: scores.0), stop("b", b, score: scores.1), stop("c", c, score: scores.2)], budget: 2100)
    }

    @Test func droppingAMiddleStopJoinsItsNeighbours() async {
        // Scores 3, 1, 3: ratios a 3/640 = 0.0047, b 1/640 = 0.0016, c 3/1240 = 0.0024 → b goes. The joining leg a→c
        // is routed at 3 × 200 = 600: 300 + 600 + 900 + 2 × 240 = 2280 ≤ 2310.
        let stub = LegStub.scaled(3)
        let tour = await TourRouting.fit(Self.threeStops(scores: (3, 1, 3)), maxRequests: 25, leg: stub.leg)
        #expect(stub.requests.count == 5)
        #expect(stub.requests.last == [Self.a, Self.c])
        #expect(tour.plan.stops.map(\.id) == ["a", "c"])
        #expect(tour.legs.map { [$0.path.first, $0.path.last] } == [[Self.origin, Self.a], [Self.a, Self.c], [Self.c, Self.origin]])
        #expect(abs(tour.totalSeconds - 2280) < Self.tolerance)
    }

    @Test func droppingTheFirstStopJoinsTheStartToTheSecond() async {
        // Scores 1, 3, 3: ratios a 1/640 = 0.0016, b 3/640 = 0.0047, c 3/1240 = 0.0024 → a goes. The joining leg O→b
        // is routed at 3 × 200 = 600: 600 + 300 + 900 + 2 × 240 = 2280 ≤ 2310.
        let stub = LegStub.scaled(3)
        let tour = await TourRouting.fit(Self.threeStops(scores: (1, 3, 3)), maxRequests: 25, leg: stub.leg)
        #expect(stub.requests.count == 5)
        #expect(stub.requests.last == [Self.origin, Self.b])
        #expect(tour.plan.stops.map(\.id) == ["b", "c"])
        #expect(tour.legs.map { [$0.path.first, $0.path.last] } == [[Self.origin, Self.b], [Self.b, Self.c], [Self.c, Self.origin]])
        #expect(abs(tour.totalSeconds - 2280) < Self.tolerance)
    }

    // MARK: - Walked legs

    @Test func aWalkedLegIsTimedAtTheToursWalkingSpeed() {
        // 130 m / 1.3 m/s = 100 s; 650 m / 1.3 = 500 s; 0 m → 0 s.
        let walked = RoutedLeg.walked(metres: 130, path: [Self.origin, Self.a])
        #expect(abs(walked.seconds - 100) < 1e-9)
        #expect(walked.metres == 130)
        #expect(walked.path == [Self.origin, Self.a])
        #expect(!walked.approximate)
        #expect(abs(RoutedLeg.walked(metres: 650, path: []).seconds - 500) < 1e-9)
        #expect(RoutedLeg.walked(metres: 0, path: []).seconds == 0)
    }

    @Test func aWalkedLegWithNonsenseMetresBecomesStraight() async {
        let direct = TourPlan(kind: .aToB, start: Self.origin, end: Self.a, stops: [], estimatedSeconds: 100,
                              budgetSeconds: 125)
        for metres in [Double.nan, .infinity, -1] {
            let stub = LegStub { from, to in RoutedLeg.walked(metres: metres, path: [from, to]) }
            let tour = await TourRouting.fit(direct, maxRequests: 25, leg: stub.leg)
            Self.expectStraight(tour.legs[0], from: Self.origin, to: Self.a, metres: 100)
        }
    }

    // MARK: - Codable

    @Test func aStoredApproximateFieldIsIgnoredWhenDecoding() throws {
        let tour = RoutedTour(plan: Self.loop([], budget: 1000), legs: [
            RoutedLeg(seconds: 0, metres: 0, path: [Self.origin], approximate: true),
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tour)) as? [String: Any])
        #expect(object["approximate"] == nil)
        object["approximate"] = false
        let decoded = try JSONDecoder().decode(RoutedTour.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == tour)
        #expect(decoded.approximate)
    }
}
