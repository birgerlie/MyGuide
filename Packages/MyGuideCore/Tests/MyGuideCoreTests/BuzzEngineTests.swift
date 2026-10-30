import Foundation
import Testing
@testable import MyGuideCore

@Suite struct BuzzEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func place(_ id: String, _ tier: PlaceTier, north: Double = 0, east: Double = 0) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x"),
                     tier: tier)
    }
    static func engine(perHour: Int = 20, excluded: Set<String> = []) -> BuzzEngine {
        BuzzEngine(perHour: perHour, now: t0, excluded: excluded)
    }

    @Test func firstBuzzIsImmediate() {
        var e = Self.engine()
        let b = e.evaluate(places: [Self.place("castle", .top, north: 50)], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        #expect(b?.place.candidate.id == "castle")
        #expect(b?.detail == "50 m ahead")
        #expect(b?.usedOverride == false)
    }
    @Test func notDueBeyondSixtyMetres() {
        var e = Self.engine()
        let castle = Self.place("castle", .top, north: 70)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        #expect(e.evaluate(places: [castle], position: .at(north: 15), accuracy: 5, course: 0, now: Self.t0 + 10)?.place == castle) // 55 m
    }
    @Test func budgetSpacesBuzzes() {
        // 20/h: second buzz no sooner than 180 s after the first. a and b are 59 − 30 = 29 m apart (> 25 m, not the
        // same spot).
        var e = Self.engine()
        let a = Self.place("a", .good, north: 30), b = Self.place("b", .good, north: 59)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179) == nil)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }
    @Test func tierBeatsDistance() {
        var e = Self.engine()
        let church = Self.place("church", .good, north: 20), castle = Self.place("castle", .top, north: 55)
        #expect(e.evaluate(places: [church, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == castle)
        var f = Self.engine()
        let plaque = Self.place("plaque", .wikiOnly, north: 10), museum = Self.place("museum", .good, north: 59)
        #expect(f.evaluate(places: [plaque, museum], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == museum)
    }
    @Test func staysDueUntilDropRadius() {
        // Spend the budget on "a" at t0; "late" (55 m) is due but must wait. At t0+180 the walker has moved
        // 55 m south (late is now 110 m behind) → it still buzzes, "110 m behind you" (course 180 = walking south).
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10), late = Self.place("late", .good, north: 55)
        #expect(e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == a)
        let b = e.evaluate(places: [a, late], position: .at(north: -55), accuracy: 5, course: 180, now: Self.t0 + 180)
        #expect(b?.place == late)
        #expect(b?.detail == "110 m behind you")
    }
    @Test func droppedBeyondDropRadius() {
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10), late = Self.place("late", .good, north: 55)
        _ = e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)
        _ = e.evaluate(places: [a, late], position: .at(north: -70), accuracy: 5, course: 180, now: Self.t0 + 60) // 125 m: dropped
        #expect(e.evaluate(places: [a, late], position: .at(north: -64), accuracy: 5, course: 180, now: Self.t0 + 180) == nil) // 119 m, not due again
    }
    @Test func topTierOverrideWhilePassing() {
        // 20/h. t0: "a" (top, 5 m south; 35 m from the castle, not the same spot) buzzes and spends the budget.
        // t0+10: castle due, closest 30 m.
        // t0+60 at 125 m north: castle 95 m away (≥ 90, > 30 + 10), budget 60/180 = 0.33 → override.
        // t0+180: budget 180/180 = 1.0 (the override spent nothing) → "g" (good, 50 m) buzzes normally.
        var e = Self.engine()
        let a = Self.place("a", .top, north: -5), castle = Self.place("castle", .top, north: 30)
        let g = Self.place("g", .good, north: 300)
        #expect(e.evaluate(places: [a, castle, g], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, castle, g], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10) == nil)
        let o = e.evaluate(places: [a, castle, g], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60)
        #expect(o?.place == castle && o?.usedOverride == true)
        let n = e.evaluate(places: [a, castle, g], position: .at(north: 250), accuracy: 5, course: 0, now: Self.t0 + 180)
        #expect(n?.place == g && n?.usedOverride == false)
    }
    @Test func overrideIntervalIsSixHundredSeconds() {
        // 5/h = 720 s per buzz, so the budget stays below 1 until t0+720.
        // t0: "a" (top, 5 m south, 35 m from p1) buzzes. t0+10: p1 due (closest 30). t0+60 at 125 N: p1 95 m, passing → override #1.
        // t0+500 at 1000 N: p2 due (closest 30). t0+600 at 1125 N: p2 95 m, passing, but 540 s since override #1 → nil.
        // t0+660: 600 s since override #1 → override #2 (budget 660/720 = 0.92, so it is an override).
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: -5)
        let p1 = Self.place("p1", .top, north: 30), p2 = Self.place("p2", .top, north: 1030)
        #expect(e.evaluate(places: [a, p1, p2], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, p1, p2], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10) == nil)
        #expect(e.evaluate(places: [p1, p2], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60)?.usedOverride == true)
        #expect(e.evaluate(places: [p2], position: .at(north: 1000), accuracy: 5, course: 0, now: Self.t0 + 500) == nil)
        #expect(e.evaluate(places: [p2], position: .at(north: 1125), accuracy: 5, course: 0, now: Self.t0 + 600) == nil)
        #expect(e.evaluate(places: [p2], position: .at(north: 1125), accuracy: 5, course: 0, now: Self.t0 + 660)?.usedOverride == true)
    }
    @Test func overrideSkipsANearerTopPlaceThatIsNotPassing() {
        // 5/h: "a" (top, 5 m) buzzes at t0 and spends the budget; B (top, 40 m north) is due, closest 40.
        // A (top) sits 65 m south and 50 m east: at the origin sqrt(65² + 50²) = 82 m (not due).
        // t0+60 at 65 m south: B is 40 + 65 = 105 m away (≥ 90, > 40 + 10); A is sqrt(0² + 50²) = 50 m away, so it
        // is nearer and sorts first, but 50 < 90 → A does not qualify. Budget 60·5/3600 = 0.08 → B overrides.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: 5), b = Self.place("b", .top, north: 40)
        let nearer = Self.place("A", .top, north: -65, east: 50)
        #expect(e.evaluate(places: [a, b, nearer], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let o = e.evaluate(places: [a, b, nearer], position: .at(north: -65), accuracy: 5, course: 0, now: Self.t0 + 60)
        #expect(o?.place == b)
        #expect(o?.usedOverride == true)
    }
    @Test func dueSetIsUpdatedWhileBusy() {
        // Busy at the origin: the place at 55 m enters the due set but nothing buzzes.
        // Later at 45 m south it is 55 + 45 = 100 m away (> 60, ≤ 120) → still due, fresh budget → buzzes.
        var e = Self.engine()
        let p = Self.place("p", .good, north: 55)
        e.isBusy = true
        #expect(e.evaluate(places: [p], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.isBusy = false
        #expect(e.evaluate(places: [p], position: .at(north: -45), accuracy: 5, course: 0, now: Self.t0 + 5)?.place == p)
        // Control: without the busy evaluation the place was never due, and 100 m is outside the due radius.
        var f = Self.engine()
        #expect(f.evaluate(places: [p], position: .at(north: -45), accuracy: 5, course: 0, now: Self.t0 + 5) == nil)
    }
    @Test func noOverrideForGoodTier() {
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 5), church = Self.place("church", .good, north: 30)
        _ = e.evaluate(places: [a, church], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        _ = e.evaluate(places: [a, church], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10)
        #expect(e.evaluate(places: [church], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60) == nil)
    }
    @Test func busyAndSkipQuiet() {
        var e = Self.engine()
        let castle = Self.place("castle", .top, north: 20)
        e.isBusy = true
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.isBusy = false
        e.noteSkip(at: Self.t0 + 1)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 60) == nil)  // 59 s
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 61)?.place == castle)
    }
    @Test func excludedNeverBuzz() {
        var e = Self.engine(excluded: ["castle"])
        #expect(e.evaluate(places: [Self.place("castle", .top, north: 10)], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.exclude("church")
        #expect(e.evaluate(places: [Self.place("church", .good, north: 10)], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
    }
    @Test func clearedExclusionsBuzzAgain() {
        // Spec 13.5: the reset button clears the running engine's exclusions, retired and buzzed this run alike.
        var e = Self.engine(excluded: ["castle"])
        let castle = Self.place("castle", .top, north: 10)
        let before = e.decide(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, _) = before else { Issue.record("expected allExcluded, got \(before)"); return }
        e.clearExclusions()
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 1)?.place == castle)
        // Buzzed now, so excluded again for the rest of the run, even with the budget refilled (3 600 s at 20/h).
        let after = e.decide(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 3_600)
        guard case .quiet(.allExcluded, _) = after else { Issue.record("expected allExcluded, got \(after)"); return }
        e.clearExclusions()
        // 20/h refills one buzz per 180 s; 3 600 s after the last buzz the budget is full, so the castle buzzes again.
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 3_601)?.place == castle)
    }
    @Test func inaccurateFixesChangeNothing() {
        // Review Focus 3: a 51 m fix must not put a place into the due set.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 5), castle = Self.place("castle", .top, north: 50)
        _ = e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0)               // spend
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 51, course: 0, now: Self.t0 + 1) == nil)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: .nan, course: 0, now: Self.t0 + 2) == nil)
        // castle never entered the due set, so at 100 m with the budget refilled (720 s) it does not buzz
        #expect(e.evaluate(places: [castle], position: .at(north: -50), accuracy: 5, course: 0, now: Self.t0 + 800) == nil)
    }
    @Test func jitterDoesNotFlap() {
        // Review Focus 3: a place that entered at 59 m stays due at 61 m (no flapping at the 60 m edge).
        // 5/h: "a" spends the budget at t0; at t0+720 the budget is 1.0 and the castle, still due at 61 m, buzzes.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 1), castle = Self.place("castle", .good, north: 59)
        _ = e.evaluate(places: [a, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)    // a buzzes, castle due
        _ = e.evaluate(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 5)  // 61 m: still due
        #expect(e.evaluate(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 720)?.place == castle)
    }

    // MARK: - decide (quiet reasons, design 4.3)

    @Test func badAccuracyIsQuietWithNoDue() {
        var e = Self.engine()
        // accuracy 51 > 50 m (maxFixAccuracy) → unusable, even with a place 10 m away; due stays empty.
        let d = e.decide(places: [Self.place("a", .good, north: 10)], position: .at(), accuracy: 51, course: 0, now: Self.t0)
        #expect(d == .quiet(.badAccuracy, due: []))
    }
    @Test func noneDueWhenNothingWithin60m() {
        var e = Self.engine()
        // 70 m > 60 m due radius.
        let d = e.decide(places: [Self.place("a", .good, north: 70)], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        #expect(d == .quiet(.noneDue, due: []))
    }
    @Test func busyListsDuePlaces() {
        var e = Self.engine()
        e.isBusy = true
        let d = e.decide(places: [Self.place("a", .good, north: 40)], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.busy, let due) = d, due.count == 1 else { Issue.record("expected busy, got \(d)"); return }
        #expect(due[0].id == "a" && due[0].name == "a" && due[0].tier == .good && !due[0].excluded)
        // `.at(north: 40)` is 40 m by construction (Support/Metres.swift).
        #expect(abs(due[0].distance - 40) < 0.01)
    }
    @Test func skipQuietWithin60s() {
        var e = Self.engine()
        let a = Self.place("a", .good, north: 40), b = Self.place("b", .good, north: 50)
        #expect(e.decide(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0).buzz?.place == a)
        e.noteSkip(at: Self.t0)
        // 59 s since the skip < 60 s skipQuiet.
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 59)
        guard case .quiet(.skipQuiet, let due) = d else { Issue.record("expected skipQuiet, got \(d)"); return }
        #expect(due.map(\.id) == ["a", "b"])
    }
    @Test func allExcludedFlagsExcluded() {
        var e = Self.engine(excluded: ["a"])
        let d = e.decide(places: [Self.place("a", .good, north: 40)], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, let due) = d, due.count == 1 else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due[0].id == "a" && due[0].excluded)
    }
    @Test func budgetWhenSpent() {
        var e = Self.engine(perHour: 20)
        // 59 − 30 = 29 m apart: not the same spot, so b stays buzzable after a.
        let a = Self.place("a", .good, north: 30), b = Self.place("b", .good, north: 59)
        #expect(e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0).buzz?.place == a)
        // 20/h → 3600 / 20 = 180 s spacing; 179 s < 180 s, so the budget is spent. b is good tier: no override.
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179)
        guard case .quiet(.budget, let due) = d else { Issue.record("expected budget, got \(d)"); return }
        // Tier then distance: both good, a at 30 m before b at 59 m.
        #expect(due.map(\.id) == ["a", "b"])
        #expect(due.map(\.excluded) == [true, false])
    }
    @Test func dueOrderedByTierThenDistance() {
        var e = Self.engine()
        e.isBusy = true
        // y is top tier at 50 m, x is good tier at 10 m: tier wins over distance.
        let d = e.decide(places: [Self.place("x", .good, north: 10), Self.place("y", .top, north: 50)],
                         position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.busy, let due) = d else { Issue.record("expected busy, got \(d)"); return }
        #expect(due.map(\.id) == ["y", "x"])
    }
    @Test func evaluateStillMatchesDecide() {
        var viaEvaluate = Self.engine(), viaDecide = Self.engine()
        // 50 − 20 = 30 m apart, so a is not excluded as b's spot.
        let a = Self.place("a", .good, north: 20), b = Self.place("b", .top, north: 50)
        // t0: both buzz b (top); t0+179: budget spent for both; t0+180: a.
        for dt in [0.0, 179, 180] {
            let x = viaEvaluate.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + dt)
            let y = viaDecide.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + dt).buzz
            #expect(x?.place == y?.place && x?.detail == y?.detail && x?.usedOverride == y?.usedOverride)
        }
    }

    // MARK: - Sitelinks order and same spot (spec 19.3, 19.4)

    static func place(_ id: String, _ tier: PlaceTier, north: Double = 0, east: Double = 0,
                      sitelinks: Int?) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                          sitelinks: sitelinks),
                     tier: tier)
    }
    @Test func moreSitelinksBeatDistanceWithinATier() {
        // Both top and due: near at 20 m with 80 sitelinks, far at 50 m with 10. Key (tier, −sitelinks, distance):
        // (top, −80, 20) < (top, −10, 50) → near. Swapped (20 m has 10, 50 m has 80): (top, −80, 50) wins → far.
        var e = Self.engine()
        let far = Self.place("far", .top, north: 50, sitelinks: 10), near = Self.place("near", .top, north: 20, sitelinks: 80)
        #expect(e.evaluate(places: [far, near], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == near)
        var f = Self.engine()
        let famousFar = Self.place("famousFar", .top, north: 50, sitelinks: 80)
        let plainNear = Self.place("plainNear", .top, north: 20, sitelinks: 10)
        #expect(f.evaluate(places: [plainNear, famousFar], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place
                == famousFar)
    }
    @Test func equalSitelinksFallBackToDistance() {
        // (top, −40, 20) < (top, −40, 50) → the 20 m one.
        var e = Self.engine()
        let far = Self.place("far", .top, north: 50, sitelinks: 40), near = Self.place("near", .top, north: 20, sitelinks: 40)
        #expect(e.evaluate(places: [far, near], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == near)
    }
    @Test func missingSitelinksCountAsZero() {
        // nil counts as 0: (good, 0, 10) vs (good, −1, 50) → the 50 m one with 1 sitelink; nil vs 0 → distance.
        var e = Self.engine()
        let none = Self.place("none", .good, north: 10, sitelinks: nil), one = Self.place("one", .good, north: 50, sitelinks: 1)
        #expect(e.evaluate(places: [none, one], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == one)
        var f = Self.engine()
        let zero = Self.place("zero", .good, north: 50, sitelinks: 0)
        #expect(f.evaluate(places: [zero, none], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == none)
    }
    @Test func tierStillBeatsSitelinks() {
        // (top, 0, 55) < (good, −500, 10): tier first.
        var e = Self.engine()
        let famous = Self.place("famous", .good, north: 10, sitelinks: 500), top = Self.place("top", .top, north: 55, sitelinks: nil)
        #expect(e.evaluate(places: [famous, top], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == top)
    }
    @Test func dueListFollowsTheSitelinksOrder() {
        var e = Self.engine()
        e.isBusy = true
        // All good: (−3, 40) < (0, 10) < (0, 30) → c, a, b.
        let d = e.decide(places: [Self.place("a", .good, north: 10, sitelinks: nil),
                                  Self.place("b", .good, north: 30, sitelinks: 0),
                                  Self.place("c", .good, north: 40, sitelinks: 3)],
                         position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.busy, let due) = d else { Issue.record("expected busy, got \(d)"); return }
        #expect(due.map(\.id) == ["c", "a", "b"])
    }
    @Test func sameSpotRadiusIsTwentyFiveMetres() {
        #expect(BuzzEngine.sameSpotRadius == 25)
        // The test coordinates are metres along a meridian: 60 − 35 = 25 m, 56 − 30 = 26 m. Haversine rounding varies
        // by pair (30 → 55 gives 25.000000000000007), so the boundary tests use 35 → 60, which gives exactly 25.0.
        #expect(GeoMath.distance(.at(north: 35), .at(north: 60)) == 25)
        #expect(GeoMath.distance(.at(north: 30), .at(north: 56)) > 25)
    }
    @Test func placeTwentyFiveMetresFromABuzzIsExcludedWithIt() {
        // a (top, 35 m) buzzes at t0 and spends the budget. b (good, 60 m, due) is 60 − 35 = 25 m from a (≤ 25,
        // inclusive): excluded too. t0+180: budget 180/180 = 1 again, but b is excluded → allExcluded, b listed as excluded.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 35), b = Self.place("b", .good, north: 60)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.map(\.id) == ["a", "b"])
        #expect(due.map(\.excluded) == [true, true])
    }
    @Test func placeTwentySixMetresFromABuzzCanStillBuzz() {
        // b is 56 − 30 = 26 m from a (> 25): not the same spot. It waits for the budget: at t0+179 (179/180 < 1) quiet
        // with b not excluded, at t0+180 it buzzes.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 30), b = Self.place("b", .good, north: 56)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let waiting = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179)
        guard case .quiet(.budget, let due) = waiting else { Issue.record("expected budget, got \(waiting)"); return }
        #expect(due.map(\.excluded) == [true, false])
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }
    @Test func sameSpotCoversPlacesNotYetDue() {
        // a (good, 55 m) buzzes; b is 80 m from the walker (not due) but 80 − 55 = 25 m from a → excluded anyway.
        // t0+180 at 60 m north: b is 20 m away and due, a 5 m: both excluded.
        var e = Self.engine()
        let a = Self.place("a", .good, north: 55), b = Self.place("b", .top, north: 80)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, b], position: .at(north: 60), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(Set(due.map(\.id)) == ["a", "b"])
    }
    @Test func placeArrivingInALaterListAtABuzzedSpotIsExcluded() {
        // a (30 m) buzzes with only itself in the list. b, 40 − 30 = 10 m from a, first appears in a later list:
        // at t0+180 the budget is 1 again, but b stands at a's spot → allExcluded, b listed as excluded.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 30), b = Self.place("b", .good, north: 40)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.first { $0.id == "b" }?.excluded == true)
    }
    @Test func idFlipAfterOSMArrivesDoesNotBuzzTheSpotAgain() {
        // Il Gesù buzzes as a Wikipedia-only place; the next list (OSM answered, merged) names it osm:way/1 at the
        // same coordinate (0 m ≤ 25) → not buzzed again.
        var e = Self.engine()
        let wiki = Self.place("wiki:it/1", .top, north: 30)
        let osm = Self.place("osm:way/1", .top, north: 30)
        #expect(e.evaluate(places: [wiki], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == wiki)
        let d = e.decide(places: [osm], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.map(\.id) == ["osm:way/1"] && due.map(\.excluded) == [true])
    }
    @Test func laterPlaceTwentySixMetresFromABuzzedSpotCanBuzz() {
        // Same as above but 56 − 30 = 26 m away (> 25): it buzzes once the budget allows (t0+180).
        var e = Self.engine()
        let a = Self.place("a", .top, north: 30), b = Self.place("b", .good, north: 56)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }
    @Test func clearExclusionsLetsSameSpotNeighboursBuzzAgain() {
        // a (35 m) buzzes at t0; b (60 m) is 60 − 35 = 25 m from it → excluded. After the reset a, the top place,
        // buzzes again first once the budget allows (t0+180: 180/180 = 1); after a second reset b buzzes at t0+360.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 35), b = Self.place("b", .good, north: 60)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        e.clearExclusions()
        // a is top, so it comes first again after the reset.
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == a)
        e.clearExclusions()
        #expect(e.evaluate(places: [b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 360)?.place == b)
    }
    @Test func excludeSpotCoversPlacesAtATourStop() {
        // A tour stop buzzed outside the engine at 35 m north: a place at 60 m (25 m from it) is excluded, one at
        // 10 m (25 m on the other side) too, one at 9 m (26 m) is not.
        var e = Self.engine()
        e.excludeSpot(.at(north: 35))
        let far = Self.place("far", .top, north: 60), near = Self.place("near", .top, north: 10)
        let free = Self.place("free", .good, north: 9)
        let d = e.decide(places: [far, near], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [far, near, free], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == free)
        // The reset forgets the stop's spot too.
        var f = Self.engine()
        f.excludeSpot(.at(north: 35))
        f.clearExclusions()
        #expect(f.evaluate(places: [far], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == far)
    }
    @Test func overrideBuzzExcludesItsSpotToo() {
        // As topTierOverrideWhilePassing: "a" (5 m south) buzzes at t0; the castle (30 m) is due from t0, closest
        // 30. "twin" (good) sits 20 m beyond the castle (50 m north; 20 ≤ 25 → same spot), 55 m from a.
        // t0+60 at 125 m: castle 95 m (≥ 90, > 30 + 10) → override; twin 75 m is still due (closest 50 ≤ 120 drop).
        // t0+180 at 125 m: budget 1 again, but twin is excluded with the castle → allExcluded.
        var e = Self.engine()
        let a = Self.place("a", .top, north: -5), castle = Self.place("castle", .top, north: 30)
        let twin = Self.place("twin", .good, north: 50)
        #expect(e.evaluate(places: [a, castle, twin], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [a, castle, twin], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10) == nil)
        let o = e.evaluate(places: [a, castle, twin], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 60)
        #expect(o?.place == castle && o?.usedOverride == true)
        let d = e.decide(places: [a, castle, twin], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.first { $0.id == "twin" }?.excluded == true)
    }
    @Test func overrideChoosesByTheSitelinksOrder() {
        // Walker at the origin. a (top, 10 m south), p (top, 40 m north, 5 sitelinks), q (top, 40 m north and 30 m
        // east: sqrt(40² + 30²) = 50 m away, 90 sitelinks; 30 m from p, so not p's spot).
        // With a full budget the order alone decides: (top, −90, 50) < (top, −5, 40) < (top, 0, 10) → q.
        // Override: 5/h; a alone buzzes at t0 and spends the budget; t0+10 p and q are due, closest 40 and 50
        // (both < 90 m, no override). t0+60 at 60 m south: p is 100 m (≥ 90, > 40 + 10) and q is
        // sqrt(100² + 30²) = 104.4 m (≥ 90, > 50 + 10); both qualify, q comes first by sitelinks although p is nearer.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: -10, sitelinks: nil)
        let p = Self.place("p", .top, north: 40, sitelinks: 5), q = Self.place("q", .top, north: 40, east: 30, sitelinks: 90)
        #expect(e.evaluate(places: [a, p, q], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == q)
        var f = Self.engine(perHour: 5)
        #expect(f.evaluate(places: [a], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == a)
        #expect(f.evaluate(places: [a, p, q], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 10) == nil)
        let o = f.evaluate(places: [a, p, q], position: .at(north: -60), accuracy: 5, course: 180, now: Self.t0 + 60)
        #expect(o?.place == q && o?.usedOverride == true)
    }
}
