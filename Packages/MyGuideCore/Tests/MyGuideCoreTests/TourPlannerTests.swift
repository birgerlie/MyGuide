import Foundation
import Testing
@testable import MyGuideCore

/// Coordinates come from `.at(north:east:)` on the equator, where a metre north or east is a metre by haversine (see
/// Support/Metres.swift). A leg's estimate is straight × 1.3 / 1.3 m/s, so its seconds equal its straight metres; each
/// stop adds 240 s of dwell.
@Suite struct TourPlannerTests {
    static let origin = Coordinate.at()
    /// Leg seconds equal metres up to floating point (× 1.3 / 1.3); diagonal legs are haversine, not Euclidean, but
    /// within a few hundred metres of the equator the two agree to far below a millisecond.
    static let tolerance = 1e-3

    static func candidate(_ id: String, north: Double = 0, east: Double = 0, score: Double = 2,
                          tier: PlaceTier = .good) -> TourCandidate {
        TourCandidate(place: WalkingPlace(candidate: Candidate(id: id, name: "Name \(id)", coordinate: .at(north: north, east: east),
                                                               kind: "historic=yes"),
                                          tier: tier),
                      score: score)
    }

    static func stop(_ id: String, north: Double = 0, east: Double = 0, score: Double = 2) -> TourStop {
        TourStop(id: id, name: id, coordinate: .at(north: north, east: east), tier: .good, score: score)
    }

    // MARK: - Constants and leg estimate

    @Test func constantsFollowTheGlobalConstraints() {
        #expect(TourPlanner.walkingSpeed == TourArea.walkingSpeed)
        #expect(TourPlanner.walkingSpeed == 1.3)
        #expect(TourPlanner.detourFactor == 1.3)
        #expect(TourPlanner.dwellSeconds == 240)
        #expect(TourPlanner.overrunAllowance == 0.10)
        #expect(TourPlanner.minimumDirectMetres == 200)
        #expect(TourPlanner.aToBBudgetFactor == 1.25)
    }

    @Test func legEstimateIsStraightTimesDetourOverSpeed() {
        // 1000 m north: 1000 × 1.3 / 1.3 = 1000 s.
        #expect(abs(TourPlanner.estimatedLegSeconds(from: Self.origin, to: .at(north: 1000)) - 1000) < Self.tolerance)
        // 300 m east, 400 m north: √(300² + 400²) = √250 000 = 500 m → 500 × 1.3 / 1.3 = 500 s.
        #expect(abs(TourPlanner.estimatedLegSeconds(from: Self.origin, to: .at(north: 400, east: 300)) - 500) < Self.tolerance)
        // The same point: 0 s.
        #expect(TourPlanner.estimatedLegSeconds(from: Self.origin, to: Self.origin) == 0)
    }

    // MARK: - Loop insertion

    @Test func loopInsertsTheBestScorePerSecondFirst() {
        // 20 min loop: budget 20 × 60 = 1200 s.
        // near (good, 2) at 100 m north: added 100 + 100 − 0 walking + 240 dwell = 440 s → 2 / 440 = 0.004545.
        // far  (top, 3)  at 400 m north: added 400 + 400 − 0 + 240 = 1040 s → 3 / 1040 = 0.002885.
        // near goes first (estimate 440). far then costs, at either position, 400 + 300 − 100 = 600 + 240 = 840 s →
        // 440 + 840 = 1280 > 1200, so it does not fit. Picking by score alone would have taken far (1040) and then
        // found no room for near (far + near = the same 1280), so [near] proves the ratio decides.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 20, candidates: [
            Self.candidate("far", north: 400, score: 3, tier: .top),
            Self.candidate("near", north: 100, score: 2),
        ])
        #expect(plan.kind == .loop)
        #expect(plan.start == Self.origin && plan.end == Self.origin)
        #expect(plan.stops.map(\.id) == ["near"])
        #expect(plan.budgetSeconds == 1200)
        #expect(abs(plan.estimatedSeconds - 440) < Self.tolerance)
    }

    @Test func loopInsertsSeveralStopsWhileTheyFit() {
        // 30 min loop: budget 1800 s.
        // top (3) at 100 m east: added 100 + 100 + 240 = 440 s → 3 / 440 = 0.006818.
        // good (2) at 100 m west: added 440 s → 2 / 440 = 0.004545. top goes first.
        // Then good: between origin and top, 100 + 200 − 100 = 200 walking; between top and origin the same 200
        // (ties keep the first position) → added 200 + 240 = 440 s → 440 + 440 = 880 ≤ 1800, it fits too.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [
            Self.candidate("good", east: -100, score: 2),
            Self.candidate("top", east: 100, score: 3, tier: .top),
        ])
        #expect(Set(plan.stops.map(\.id)) == ["top", "good"])
        // Walking origin → good → top → origin or the reverse: 100 + 200 + 100 = 400 m; + 2 × 240 = 880 s.
        #expect(abs(plan.estimatedSeconds - 880) < Self.tolerance)
        #expect(plan.estimatedSeconds <= plan.budgetSeconds)
    }

    @Test func stopCarriesThePlaceAndItsScore() {
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [
            Self.candidate("osm:node/7", north: 100, east: 50, score: 1.5, tier: .top),
        ])
        #expect(plan.stops == [TourStop(id: "osm:node/7", name: "Name osm:node/7", coordinate: .at(north: 100, east: 50),
                                        tier: .top, score: 1.5)])
    }

    // MARK: - Budget

    @Test func aStopThatExactlyFillsTheBudgetFits() {
        // 30 min = 1800 s. A place 780 m north: 780 + 780 walking + 240 dwell = 1800 s = the budget (inclusive).
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [Self.candidate("edge", north: 780)])
        #expect(plan.stops.map(\.id) == ["edge"])
        #expect(abs(plan.estimatedSeconds - 1800) < Self.tolerance)
    }

    @Test func aStopOneSecondOverTheBudgetDoesNotFit() {
        // 781 m north: 781 + 781 + 240 = 1802 s > 1800 s.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [Self.candidate("over", north: 781)])
        #expect(plan.stops.isEmpty)
        #expect(plan.estimatedSeconds == 0)
        #expect(plan.budgetSeconds == 1800)
    }

    @Test func manyCandidatesNeverExceedTheBudget() {
        // A 7 × 7 grid every 150 m from −450 to +450 m in each direction, scores 1, 2, 3 by position.
        var candidates: [TourCandidate] = []
        for row in -3...3 {
            for column in -3...3 where row != 0 || column != 0 {
                let score = Double((row + column + 6) % 3 + 1)
                candidates.append(Self.candidate("p\(row)_\(column)", north: Double(row) * 150, east: Double(column) * 150,
                                                 score: score))
            }
        }
        for minutes in [30, 45, 60] {
            let plan = TourPlanner.loop(from: Self.origin, minutes: minutes, candidates: candidates)
            #expect(!plan.stops.isEmpty)
            #expect(plan.estimatedSeconds <= plan.budgetSeconds + 1e-6)
            #expect(plan.budgetSeconds == Double(minutes * 60))
            // The estimate is the walking legs plus the dwell, recomputed from the stops.
            let points = [plan.start] + plan.stops.map(\.coordinate) + [plan.end]
            let walking = zip(points, points.dropFirst()).map { TourPlanner.estimatedLegSeconds(from: $0, to: $1) }
                .reduce(0, +)
            #expect(abs(plan.estimatedSeconds - (walking + 240 * Double(plan.stops.count))) < 1e-6)
            #expect(Set(plan.stops.map(\.id)).count == plan.stops.count)
            // The planner ends with 2-opt, so another pass finds nothing to shorten.
            #expect(TourPlanner.twoOpt(plan.stops, start: plan.start, end: plan.end) == plan.stops)
        }
    }

    // MARK: - No stops fit (review focus 1: an honest empty plan)

    @Test func noCandidateFitsGivesNoStops() {
        // 30 min = 1800 s; 1000 m north costs 1000 + 1000 + 240 = 2240 s > 1800.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [Self.candidate("far", north: 1000)])
        #expect(plan.stops.isEmpty)
        #expect(plan.estimatedSeconds == 0)
        #expect(plan.budgetSeconds == 1800)
    }

    @Test func noCandidatesGivesNoStops() {
        let plan = TourPlanner.loop(from: Self.origin, minutes: 60, candidates: [])
        #expect(plan.stops.isEmpty)
        #expect(plan.estimatedSeconds == 0)
        #expect(plan.budgetSeconds == 3600)
    }

    @Test func zeroOrNegativeMinutesGiveAZeroBudgetAndNoStops() {
        // 0 min = 0 s and −5 min counts as 0: even a place at the start costs its 240 s dwell.
        for minutes in [0, -5] {
            let plan = TourPlanner.loop(from: Self.origin, minutes: minutes, candidates: [Self.candidate("here")])
            #expect(plan.stops.isEmpty)
            #expect(plan.budgetSeconds == 0)
            #expect(plan.estimatedSeconds == 0)
        }
    }

    @Test func worthlessOrBrokenCandidatesAreSkipped() {
        // Score 0, a negative score, a NaN score and a NaN coordinate are never visited; "ok" at 100 m is (440 s).
        var broken = Self.candidate("nan-place", north: 50)
        broken.place.candidate.coordinate = Coordinate(latitude: .nan, longitude: 0)
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [
            Self.candidate("zero", north: 10, score: 0),
            Self.candidate("negative", north: 10, score: -1),
            Self.candidate("nan-score", north: 10, score: .nan),
            broken,
            Self.candidate("ok", north: 100),
        ])
        #expect(plan.stops.map(\.id) == ["ok"])
        #expect(abs(plan.estimatedSeconds - 440) < Self.tolerance)
    }

    @Test func aRepeatedIdIsVisitedOnce() {
        // The first copy counts: 100 m north (440 s); the second copy (score 3) is ignored.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 30, candidates: [
            Self.candidate("same", north: 100, score: 2),
            Self.candidate("same", north: 200, score: 3),
        ])
        #expect(plan.stops.map(\.id) == ["same"])
        #expect(plan.stops.first?.score == 2)
        #expect(abs(plan.estimatedSeconds - 440) < Self.tolerance)
    }

    // MARK: - Ties

    @Test func equalRatiosAreBrokenByTheSmallerId() {
        // 10 min = 600 s. "a" 100 m west and "b" 100 m east, both score 2: each costs 100 + 100 + 240 = 440 s
        // (2 / 440 each). After one, the other costs 100 + 200 − 100 = 200 + 240 = 440 s → 880 > 600, so only one
        // fits: "a", whatever order the candidates come in.
        let a = Self.candidate("a", east: -100), b = Self.candidate("b", east: 100)
        #expect(TourPlanner.loop(from: Self.origin, minutes: 10, candidates: [a, b]).stops.map(\.id) == ["a"])
        #expect(TourPlanner.loop(from: Self.origin, minutes: 10, candidates: [b, a]).stops.map(\.id) == ["a"])
    }

    @Test func planningIsDeterministicAcrossInputOrders() {
        let candidates: [TourCandidate] = (0..<12).map { (i: Int) -> TourCandidate in
            let north = Double((i * 137) % 600) - 300, east = Double((i * 251) % 600) - 300
            return Self.candidate("c\(i)", north: north, east: east, score: Double(i % 3 + 1))
        }
        let forward = TourPlanner.loop(from: Self.origin, minutes: 45, candidates: candidates)
        let backward = TourPlanner.loop(from: Self.origin, minutes: 45, candidates: candidates.reversed())
        #expect(forward == backward)
    }

    // MARK: - 2-opt

    @Test func twoOptRemovesACrossing() {
        // Start = end = origin. Order A (east 100) → B (north 100) → C (north 100, east 100):
        // origin–A 100, A–B √(100² + 100²) = 141.421, B–C 100, C–origin 141.421 → 482.843 m; A–B and C–origin are the
        // two diagonals of the square and cross in its middle.
        // Reversing [A, B] gives origin–B 100 + B–A 141.421 + A–C 100 + C–origin 141.421 = 482.843, no gain; reversing
        // [A, B, C] gives 141.421 + 100 + 141.421 + 100 = 482.843, no gain; reversing [B, C] gives
        // origin–A 100 + A–C 100 + C–B 100 + B–origin 100 = 400 m, a gain of 82.843 → [A, C, B], the square's edge.
        let a = Self.stop("A", east: 100), b = Self.stop("B", north: 100), c = Self.stop("C", north: 100, east: 100)
        let ordered = TourPlanner.twoOpt([a, b, c], start: Self.origin, end: Self.origin)
        #expect(ordered.map(\.id) == ["A", "C", "B"])
        let points = [Self.origin] + ordered.map(\.coordinate) + [Self.origin]
        let walking = zip(points, points.dropFirst()).map { TourPlanner.estimatedLegSeconds(from: $0, to: $1) }.reduce(0, +)
        #expect(abs(walking - 400) < Self.tolerance)
    }

    @Test func theLoopComesOutShortenedByTwoOpt() {
        // 60 min loop (3600 s) from the origin; (east, north) in metres: p0 (−100, 100) score 1, p1 (−300, −200) score 2,
        // p2 (−300, 200) score 2, p3 (−200, 100) score 3. All four fit. Insertion alone orders them p0, p2, p3, p1
        // (seen with the 2-opt call removed):
        //   origin–p0 √(100² + 100²) = 141.421, p0–p2 √(200² + 100²) = 223.607, p2–p3 √(100² + 100²) = 141.421,
        //   p3–p1 √(100² + 300²) = 316.228, p1–origin √(300² + 200²) = 360.555 → 1183.232 m.
        // Reversing [p2, p3] gives origin–p0 141.421, p0–p3 100, p3–p2 141.421, p2–p1 400, p1–origin 360.555
        //   → 1143.397 m, 39.835 shorter. Estimate 1143.397 + 4 × 240 = 2103.397 s.
        let plan = TourPlanner.loop(from: Self.origin, minutes: 60, candidates: [
            Self.candidate("p0", north: 100, east: -100, score: 1), Self.candidate("p1", north: -200, east: -300, score: 2),
            Self.candidate("p2", north: 200, east: -300, score: 2), Self.candidate("p3", north: 100, east: -200, score: 3),
        ])
        #expect(plan.stops.map(\.id) == ["p0", "p3", "p2", "p1"])
        #expect(abs(plan.estimatedSeconds - 2103.397) < Self.tolerance)
    }

    @Test func twoOptKeepsTheEndpointsOfAnAToB() {
        // A→B from the origin to 300 m north, stops listed far-first: S → s2 (200) → s1 (100) → E (300) walks
        // 200 + 100 + 200 = 500 m. Reversing [s2, s1] walks S → s1 100 + s1 → s2 100 + s2 → E 100 = 300 m.
        let s1 = Self.stop("s1", north: 100), s2 = Self.stop("s2", north: 200)
        let ordered = TourPlanner.twoOpt([s2, s1], start: Self.origin, end: .at(north: 300))
        #expect(ordered.map(\.id) == ["s1", "s2"])
    }

    @Test func twoOptLeavesShortOrdersAlone() {
        #expect(TourPlanner.twoOpt([], start: Self.origin, end: Self.origin).isEmpty)
        let one = [Self.stop("x", north: 100)]
        #expect(TourPlanner.twoOpt(one, start: Self.origin, end: Self.origin) == one)
    }

    // MARK: - A→B

    @Test func aToBWithAThirtyMinuteDirectRouteHasBudgetThirtySevenAndAHalfMinutesPlusDwell() {
        // Origin → 1800 m north: direct 1800 × 1.3 / 1.3 = 1800 s = 30 min → walking budget 1.25 × 1800 = 2250 s = 37.5
        // min. "side" at 900 m north, 300 m east: S–side = side–E = √(900² + 300²) = √900 000 = 948.683 m → walking
        // 1897.367 ≤ 2250, it fits. "wide" at 900 north, 1000 east: 2 × √(810 000 + 1 000 000) = 2 × 1345.362 = 2690.725
        // alone, over 2250; after "side" it costs at best S–wide 1345.362 + wide–side 700 − S–side 948.683 = 1096.679
        // more → 2994.046, over too.
        // Budget 2250 + 240 × 1 stop = 2490 s; estimate 1897.367 + 240 = 2137.367 s.
        let end = Coordinate.at(north: 1800)
        let plan = TourPlanner.aToB(from: Self.origin, to: end, candidates: [
            Self.candidate("wide", north: 900, east: 1000, score: 3),
            Self.candidate("side", north: 900, east: 300, score: 2),
        ])
        #expect(plan.kind == .aToB)
        #expect(plan.start == Self.origin && plan.end == end)
        #expect(plan.stops.map(\.id) == ["side"])
        #expect(abs(plan.budgetSeconds - 2490) < Self.tolerance)
        #expect(abs(plan.estimatedSeconds - 2137.367) < Self.tolerance)
    }

    @Test func aToBWithoutFittingStopsKeepsTheBareBudget() {
        // Same 30 min direct route; only "wide" (2690.725 > 2250) → no stops, budget 1.25 × 1800 = 2250 s = 37.5 min,
        // estimate the direct 1800 s.
        let plan = TourPlanner.aToB(from: Self.origin, to: .at(north: 1800),
                                    candidates: [Self.candidate("wide", north: 900, east: 1000, score: 3)])
        #expect(plan.stops.isEmpty)
        #expect(abs(plan.budgetSeconds - 2250) < Self.tolerance)
        #expect(abs(plan.estimatedSeconds - 1800) < Self.tolerance)
    }

    @Test func aToBDwellDoesNotEatTheWalkingBudget() {
        // Origin → 1000 m north; budget 1.25 × 1000 = 1250 s walking + 240 per stop. Three places on the line (250, 500,
        // 750 m north) add no walking, so all three fit although 1000 + 3 × 240 = 1720 > 1250: the dwell has its own
        // budget. Order along the line; estimate 1000 + 720 = 1720 s, budget 1250 + 720 = 1970 s.
        let plan = TourPlanner.aToB(from: Self.origin, to: .at(north: 1000), candidates: [
            Self.candidate("m750", north: 750), Self.candidate("m250", north: 250), Self.candidate("m500", north: 500),
        ])
        #expect(plan.stops.map(\.id) == ["m250", "m500", "m750"])
        #expect(abs(plan.estimatedSeconds - 1720) < Self.tolerance)
        #expect(abs(plan.budgetSeconds - 1970) < Self.tolerance)
    }

    // MARK: - A→B shorter than 200 m (review focus 4)

    @Test func aDestinationUnder200MetresGivesNoStops() {
        // 199 m direct < 200 m: no stops even for a place on the line that adds no walking.
        // Budget 1.25 × 199 = 248.75 s, estimate 199 s.
        let plan = TourPlanner.aToB(from: Self.origin, to: .at(north: 199), candidates: [Self.candidate("on", north: 100)])
        #expect(plan.stops.isEmpty)
        #expect(abs(plan.budgetSeconds - 248.75) < Self.tolerance)
        #expect(abs(plan.estimatedSeconds - 199) < Self.tolerance)
    }

    @Test func aDestinationOf200MetresMayHaveStops() {
        // Exactly 200 m (haversine gives 200.0 here) is not under 200 m, so a place on the line may join: walking
        // 100 + 100 = 200 ≤ 1.25 × 200 = 250. Estimate 200 + 240 = 440 s, budget 250 + 240 = 490 s.
        let plan = TourPlanner.aToB(from: Self.origin, to: .at(north: 200), candidates: [Self.candidate("on", north: 100)])
        #expect(plan.stops.map(\.id) == ["on"])
        #expect(abs(plan.estimatedSeconds - 440) < Self.tolerance)
        #expect(abs(plan.budgetSeconds - 490) < Self.tolerance)
    }

    @Test func theSameStartAndDestinationGiveNoStops() {
        // 0 m direct: budget 1.25 × 0 = 0, estimate 0.
        let plan = TourPlanner.aToB(from: Self.origin, to: Self.origin, candidates: [Self.candidate("here")])
        #expect(plan.stops.isEmpty)
        #expect(plan.budgetSeconds == 0)
        #expect(plan.estimatedSeconds == 0)
    }

    // MARK: - dropWorst

    /// Loop from the origin through a (100 m north, score 2) and b (200 m north, score 3).
    static func twoStopLoop() -> TourPlan {
        TourPlan(kind: .loop, start: origin, end: origin,
                 stops: [stop("a", north: 100, score: 2), stop("b", north: 200, score: 3)],
                 // Estimate 100 + 100 + 200 + 2 × 240 = 880 s.
                 estimatedSeconds: 880, budgetSeconds: 1800)
    }

    @Test func dropWorstRemovesTheStopWithTheWorstScorePerSavedSecond() {
        // Routed legs: origin→a 150, a→b 150, b→origin 1500 s.
        // Dropping a saves 150 + 150 − origin→b estimate 200 + dwell 240 = 340 s → 2 / 340 = 0.005882.
        // Dropping b saves 150 + 1500 − a→origin estimate 100 + 240 = 1790 s → 3 / 1790 = 0.001676 — the worst, although
        // b has the higher score.
        // Left: origin → a → origin, estimate 100 + 100 + 240 = 440 s; a loop's budget stays 1800.
        let dropped = TourPlanner.dropWorst(Self.twoStopLoop(), legSeconds: [150, 150, 1500])
        #expect(dropped.stops.map(\.id) == ["a"])
        #expect(abs(dropped.estimatedSeconds - 440) < Self.tolerance)
        #expect(dropped.budgetSeconds == 1800)
        #expect(dropped.kind == .loop && dropped.start == Self.origin && dropped.end == Self.origin)
    }

    @Test func dropWorstFallsBackToEstimatesWhenTheLegsDoNotMatch() {
        // No routed legs (count 0 ≠ 3): every leg is its estimate.
        // a saves 100 + 100 − 200 + 240 = 240 s → 2 / 240 = 0.008333; b saves 100 + 200 − 100 + 240 = 440 s →
        // 3 / 440 = 0.006818 → b goes. A NaN, infinite or negative leg counts as its estimate too, so [NaN, ∞, −5] gives the same result; a
        // count that is too long falls back the same way.
        #expect(TourPlanner.dropWorst(Self.twoStopLoop(), legSeconds: []).stops.map(\.id) == ["a"])
        #expect(TourPlanner.dropWorst(Self.twoStopLoop(), legSeconds: [.nan, .infinity, -5]).stops.map(\.id) == ["a"])
        #expect(TourPlanner.dropWorst(Self.twoStopLoop(), legSeconds: [0, 0, 0, 0]).stops.map(\.id) == ["a"])
    }

    @Test func dropWorstRecomputesAnAToBBudget() {
        // A→B origin → 1000 m north through c (500 m north, score 2): direct 1000 s → budget 1.25 × 1000 + 240 = 1490.
        // Dropping the only stop leaves budget 1250 s and the direct estimate 1000 s.
        let plan = TourPlan(kind: .aToB, start: Self.origin, end: .at(north: 1000), stops: [Self.stop("c", north: 500)],
                            estimatedSeconds: 1240, budgetSeconds: 1490)
        let dropped = TourPlanner.dropWorst(plan, legSeconds: [600, 600])
        #expect(dropped.stops.isEmpty)
        #expect(abs(dropped.budgetSeconds - 1250) < Self.tolerance)
        #expect(abs(dropped.estimatedSeconds - 1000) < Self.tolerance)
    }

    @Test func dropWorstOnAPlanWithoutStopsChangesNothing() {
        let plan = TourPlan(kind: .loop, start: Self.origin, end: Self.origin, stops: [], estimatedSeconds: 0,
                            budgetSeconds: 1800)
        #expect(TourPlanner.dropWorst(plan, legSeconds: []) == plan)
    }

    @Test func dropWorstBreaksTiesByDroppingTheLargerId() {
        // Loop through x (100 m west) and y (100 m east), both score 2, routed legs equal to the estimates
        // [100, 200, 100]: each saves 100 + 200 − 100 + 240 = 440 s → 2 / 440 for both → y (the larger id) goes, in
        // either order; insertion would have kept x.
        let x = Self.stop("x", east: -100), y = Self.stop("y", east: 100)
        let xy = TourPlan(kind: .loop, start: Self.origin, end: Self.origin, stops: [x, y], estimatedSeconds: 880,
                          budgetSeconds: 1800)
        let yx = TourPlan(kind: .loop, start: Self.origin, end: Self.origin, stops: [y, x], estimatedSeconds: 880,
                          budgetSeconds: 1800)
        #expect(TourPlanner.dropWorst(xy, legSeconds: [100, 200, 100]).stops.map(\.id) == ["x"])
        #expect(TourPlanner.dropWorst(yx, legSeconds: [100, 200, 100]).stops.map(\.id) == ["x"])
    }

    @Test func dropWorstNeverDropsAStopWhoseRemovalSavesNoTime() {
        // Loop through a (1000 m north, score 2) and b (2000 m north, score 3). Routes can be faster than the
        // estimate: routed legs origin→a 500, a→b 500, b→origin 1540 s.
        // Dropping a saves 500 + 500 − origin→b estimate 2000 + 240 = −760 s: nothing, so it is never the worst
        // (taken as a ratio, 2 / −760 would be the smallest and drop it).
        // Dropping b saves 500 + 1540 − a→origin estimate 1000 + 240 = 1280 s → 3 / 1280 → b goes.
        let plan = TourPlan(kind: .loop, start: Self.origin, end: Self.origin,
                            stops: [Self.stop("a", north: 1000, score: 2), Self.stop("b", north: 2000, score: 3)],
                            estimatedSeconds: 4480, budgetSeconds: 3600)
        #expect(TourPlanner.dropWorst(plan, legSeconds: [500, 500, 1540]).stops.map(\.id) == ["a"])
    }

    @Test func dropWorstDropsByIdWhenNoStopSavesTime() {
        // Same stops, routed legs [500, 100, 100]: a saves 500 + 100 − 2000 + 240 = −1160 s, b saves
        // 100 + 100 − 1000 + 240 = −560 s. Neither saves time, yet one must go (the caller drops until the tour fits or
        // no stops remain): the larger id, b.
        let plan = TourPlan(kind: .loop, start: Self.origin, end: Self.origin,
                            stops: [Self.stop("a", north: 1000, score: 2), Self.stop("b", north: 2000, score: 3)],
                            estimatedSeconds: 4480, budgetSeconds: 3600)
        #expect(TourPlanner.dropWorst(plan, legSeconds: [500, 100, 100]).stops.map(\.id) == ["a"])
    }

    // MARK: - Codable

    @Test func planRoundTripsThroughJSON() throws {
        let plan = TourPlanner.aToB(from: Self.origin, to: .at(north: 1000), candidates: [Self.candidate("m", north: 500)])
        let decoded = try JSONDecoder().decode(TourPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }
}
