import Foundation
import Testing
@testable import MyGuideCore

@Suite struct BuzzEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    /// 25 sitelinks, so a good place waits 30 s after a buzz (spec 20.3.1), not more than the 180 s the budget
    /// spaces buzzes at 20/h in these tests.
    static func place(_ id: String, _ tier: PlaceTier, north: Double = 0, east: Double = 0) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                          sitelinks: 25),
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
        // A good place: 60 m (a top place has 80 or 100 m, spec 20.2).
        var e = Self.engine()
        let castle = Self.place("castle", .good, north: 70)
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
    @Test func staysTrackedUntilDropRadiusButBuzzesOnlyWithinItsDueRadius() {
        // Spend the budget on "a" at t0; "late" (55 m) is due but must wait. At t0+180 the walker has moved
        // 55 m south: late is 110 m behind, still tracked (≤ 120 m) but beyond its 60 m → no late buzz (spec 20.2;
        // it used to buzz "110 m behind you"). Quiet noneDue lists it. a sits 5 m south, 60 m from late (beyond the
        // 55 m complex radius).
        var e = Self.engine()
        let a = Self.place("a", .top, north: -5), late = Self.place("late", .good, north: 55)
        #expect(e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, late], position: .at(north: -55), accuracy: 5, course: 180, now: Self.t0 + 180)
        guard case .quiet(.noneDue, let due) = d else { Issue.record("expected noneDue, got \(d)"); return }
        #expect(due.map(\.id) == ["a", "late"])
        #expect(abs((due.last?.distance ?? 0) - 110) < 0.01)
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
        // Later at 45 m south it is 55 + 45 = 100 m away (> 60, ≤ 120) → still tracked and listed, but beyond its
        // due radius it no longer buzzes (spec 20.2).
        var e = Self.engine()
        let p = Self.place("p", .good, north: 55)
        e.isBusy = true
        #expect(e.evaluate(places: [p], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
        e.isBusy = false
        let d = e.decide(places: [p], position: .at(north: -45), accuracy: 5, course: 0, now: Self.t0 + 5)
        guard case .quiet(.noneDue, let due) = d else { Issue.record("expected noneDue, got \(d)"); return }
        #expect(due.map(\.id) == ["p"])
        // Control: without the busy evaluation the place was never tracked, and 100 m is outside the due radius.
        var f = Self.engine()
        #expect(f.decide(places: [p], position: .at(north: -45), accuracy: 5, course: 0, now: Self.t0 + 5)
                == .quiet(.noneDue, due: []))
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
        // Review Focus 3: a place that entered at 59 m stays tracked at 61 m (no flapping at the 60 m edge); since
        // spec 20.2 it buzzes only back within 60 m.
        // 5/h: "a" spends the budget at t0; at t0+720 the budget is 1.0: at 61 m the castle is listed but quiet, at
        // 59 m it buzzes.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .good, north: 1), castle = Self.place("castle", .good, north: 59)
        _ = e.evaluate(places: [a, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)    // a buzzes, castle due
        let d = e.decide(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 5)
        guard case .quiet(_, let due) = d else { Issue.record("expected quiet, got \(d)"); return }
        #expect(due.map(\.id) == ["castle"])                                                           // 61 m: tracked
        #expect(e.evaluate(places: [castle], position: .at(north: -2), accuracy: 5, course: 0, now: Self.t0 + 720) == nil)
        #expect(e.evaluate(places: [castle], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 721)?.place == castle)
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
        // b is 56 − 30 = 26 m from a (> 25): not the same spot, and it ranks as a does (top, no sitelinks), so the
        // 40 m complex rule leaves it too. It waits for the budget: at t0+179 (179/180 < 1) quiet with b not
        // excluded, at t0+180 it buzzes.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 30), b = Self.place("b", .top, north: 56)
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let waiting = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179)
        guard case .quiet(.budget, let due) = waiting else { Issue.record("expected budget, got \(waiting)"); return }
        #expect(due.map(\.excluded) == [true, false])
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }
    @Test func sameSpotCoversPlacesNotYetDue() {
        // a (good, 55 m) buzzes; b (good) is 80 m from the walker (not due) but 80 − 55 = 25 m from a → excluded
        // anyway. t0+180 at 60 m north: b is 20 m away and due, a 5 m: both excluded.
        var e = Self.engine()
        let a = Self.place("a", .good, north: 55), b = Self.place("b", .good, north: 80)
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
        // Same as above but 56 − 30 = 26 m away (> 25) and ranked as a (both top): it buzzes once the budget allows
        // (t0+180).
        var e = Self.engine()
        let a = Self.place("a", .top, north: 30), b = Self.place("b", .top, north: 56)
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
        // 10 m (25 m on the other side) too, one at 9 m (26 m) is not; the stop itself is excluded by id.
        var e = Self.engine()
        let stop = Candidate(id: "stop", name: "Stop", coordinate: .at(north: 35), kind: "x")
        e.excludeSpot(of: stop)
        let far = Self.place("far", .top, north: 60), near = Self.place("near", .top, north: 10)
        let free = Self.place("free", .good, north: 9)
        let again = WalkingPlace(candidate: stop, tier: .top)
        let d = e.decide(places: [far, near, again], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [far, near, free], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == free)
        // The reset forgets the stop's spot too.
        var f = Self.engine()
        f.excludeSpot(of: stop)
        f.clearExclusions()
        #expect(f.evaluate(places: [far], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == far)
    }

    // MARK: - Same Wikidata id (spec 19.4)

    static func place(_ id: String, _ tier: PlaceTier, north: Double = 0, wikidata: String?) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north), kind: "x", wikidata: wikidata),
                     tier: tier)
    }

    @Test func twinWithTheSameWikidataIdIsExcludedBeyondTheSpot() {
        // Palazzo Venezia buzzes as wiki:it/1 (Q1) at 0 m. A later list carries it as osm:way/1 with the OSM centre
        // 60 m away (60 > 25: not the spot), same Q1 → excluded at t0+180 although the budget is 1 again.
        var e = Self.engine()
        let wiki = Self.place("wiki:it/1", .top, north: 0, wikidata: "Q1")
        let osm = Self.place("osm:way/1", .top, north: 60, wikidata: "Q1")
        #expect(e.evaluate(places: [wiki], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == wiki)
        let d = e.decide(places: [osm], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 180)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.map(\.id) == ["osm:way/1"] && due.map(\.excluded) == [true])
    }

    @Test func placeWithAnotherWikidataIdSixtyMetresAwayCanBuzz() {
        // As above, but Q2: neither the spot (60 > 25) nor the id matches → buzzes at t0+180 (budget 180/180 = 1).
        var e = Self.engine()
        let wiki = Self.place("wiki:it/1", .top, north: 0, wikidata: "Q1")
        let other = Self.place("osm:way/2", .top, north: 60, wikidata: "Q2")
        #expect(e.evaluate(places: [wiki], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == wiki)
        #expect(e.evaluate(places: [other], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 180)?.place
                == other)
    }

    @Test func placesWithoutWikidataIdAreNotTwins() {
        // A buzzed place without a Wikidata id must not exclude other places without one (nil is no id).
        var e = Self.engine()
        let a = Self.place("a", .top, north: 0, wikidata: nil), b = Self.place("b", .top, north: 60, wikidata: nil)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        #expect(e.evaluate(places: [b], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == b)
    }

    @Test func excludeSpotOfATourStopCoversItsWikidataTwin() {
        // A tour stop (Q7) at 0 m; its twin osm:way/7 has the OSM centre 60 m away → excluded; a Q8 place there is not.
        var e = Self.engine()
        e.excludeSpot(of: Candidate(id: "wiki:en/7", name: "Stop", coordinate: .at(), kind: "x", wikidata: "Q7"))
        let twin = Self.place("osm:way/7", .top, north: 60, wikidata: "Q7")
        let other = Self.place("osm:way/8", .good, north: 60, wikidata: "Q8")
        #expect(e.evaluate(places: [twin, other], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)?.place
                == other)
    }

    @Test func clearExclusionsForgetsBuzzedWikidataIds() {
        // wiki:it/1 (Q1) buzzes at t0; after the reset its 60 m twin buzzes at t0+180 (budget 1 again).
        var e = Self.engine()
        let wiki = Self.place("wiki:it/1", .top, north: 0, wikidata: "Q1")
        let osm = Self.place("osm:way/1", .top, north: 60, wikidata: "Q1")
        #expect(e.evaluate(places: [wiki], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == wiki)
        e.clearExclusions()
        #expect(e.evaluate(places: [osm], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 180)?.place == osm)
    }

    @Test func heardPlaceExcludesItsSpotAndWikidataTwin() {
        // A place heard or chosen on the map (spec 19.4) at 35 m: excludeSpot(of:) excludes it by id, a place 25 m
        // away (60 m), and its Q3 twin 65 m away (30 > 25 from the heard place, same Q3). A Q4 place at 65 m is free.
        var e = Self.engine()
        let heard = Candidate(id: "wiki:it/3", name: "Il Gesù", coordinate: .at(north: 35), kind: "x", wikidata: "Q3")
        e.excludeSpot(of: heard)
        // Spec 20.2.2: the 25 m rule excludes only equal or lower ranks; the heard page is Wiki-only, so is `same`.
        let same = Self.place("same", .wikiOnly, north: 60, wikidata: nil)
        let twin = Self.place("osm:way/3", .top, north: 65, wikidata: "Q3")
        let free = Self.place("free", .good, north: 65, wikidata: "Q4")
        let d = e.decide(places: [WalkingPlace(candidate: heard, tier: .top), same, twin, free], position: .at(north: 30),
                         accuracy: 5, course: 0, now: Self.t0)
        guard case .buzz(let b) = d else { Issue.record("expected a buzz, got \(d)"); return }
        #expect(b.place == free)
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

// MARK: - Spec 20: due radius by importance, hold for a better place, complexes, cadence

@Suite struct BuzzEngineTuningTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    /// 25 sitelinks unless given, so a good place waits 30 s after a buzz (spec 20.3.1).
    static func place(_ id: String, _ tier: PlaceTier, north: Double, east: Double = 0, sitelinks: Int? = 25,
                      wikidata: String? = nil) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                          wikidata: wikidata, sitelinks: sitelinks),
                     tier: tier)
    }
    static func engine(perHour: Int = 20) -> BuzzEngine {
        BuzzEngine(perHour: perHour, now: t0, excluded: [])
    }

    // MARK: Due radius (20.2)

    @Test func dueRadiusGrowsWithImportance() {
        // Top with ≥ 40 sitelinks 100 m, other top 80 m, the rest 60 m (sitelinks do not matter below top).
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .top, north: 0, sitelinks: 40)) == 100)
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .top, north: 0, sitelinks: 148)) == 100)
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .top, north: 0, sitelinks: 39)) == 80)
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .top, north: 0, sitelinks: nil)) == 80)
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .good, north: 0, sitelinks: 500)) == 60)
        #expect(BuzzEngine.dueRadius(for: Self.place("a", .wikiOnly, north: 0, sitelinks: 344)) == 60)
        #expect(BuzzEngine.dropRadius == 120 && BuzzEngine.famousSitelinks == 40)
    }
    @Test func famousTopIsTrackedFromOneHundredMetres() {
        // The Colosseum (148 sitelinks) at 99 m is tracked (beyond 60 m it waits for its closest approach, spec
        // 20.2.3); at 101 m it is not tracked (fresh engines each time).
        var e = Self.engine(), f = Self.engine()
        let near = Self.place("colosseum", .top, north: 99, sitelinks: 148)
        let far = Self.place("colosseum", .top, north: 101, sitelinks: 148)
        let d = e.decide(places: [near], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.noneDue, let due) = d else { Issue.record("expected noneDue, got \(d)"); return }
        #expect(due.map(\.id) == ["colosseum"])
        #expect(f.decide(places: [far], position: .at(), accuracy: 5, course: 0, now: Self.t0) == .quiet(.noneDue, due: []))
    }
    @Test func otherTopIsTrackedFromEightyMetresAndGoodBuzzesFromSixty() {
        var e = Self.engine(), f = Self.engine(), g = Self.engine(), h = Self.engine()
        let top79 = Self.place("t", .top, north: 79, sitelinks: 32), top81 = Self.place("t", .top, north: 81, sitelinks: 32)
        let good59 = Self.place("g", .good, north: 59, sitelinks: 90), good61 = Self.place("g", .good, north: 61, sitelinks: 90)
        let tracked = e.decide(places: [top79], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.noneDue, let due) = tracked else { Issue.record("expected noneDue, got \(tracked)"); return }
        #expect(due.map(\.id) == ["t"])
        #expect(f.decide(places: [top81], position: .at(), accuracy: 5, course: 0, now: Self.t0) == .quiet(.noneDue, due: []))
        #expect(g.evaluate(places: [good59], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == good59)
        #expect(h.evaluate(places: [good61], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
    }
    @Test func aTrackedPlaceOutsideItsRadiusDoesNotBuzzLate() {
        // 20/h. a (good, 5 m) buzzes at t0 and spends the budget; late (good, 55 m) enters the due set.
        // t0+180 (budget 180/180 = 1) the walker is 40 m south: late is 95 m away, tracked (≤ 120) but outside its
        // 60 m → no buzz, quiet noneDue with late listed. Coming back to 10 m south (65 m)… still outside; at the
        // origin (55 m) it buzzes.
        var e = Self.engine()
        let a = Self.place("a", .good, north: -5), late = Self.place("late", .good, north: 55)
        #expect(e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 180, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, late], position: .at(north: -40), accuracy: 5, course: 180, now: Self.t0 + 180)
        guard case .quiet(.noneDue, let due) = d else { Issue.record("expected noneDue, got \(d)"); return }
        #expect(due.map(\.id) == ["a", "late"])
        #expect(abs((due.last?.distance ?? 0) - 95) < 0.01)
        #expect(e.evaluate(places: [a, late], position: .at(north: -10), accuracy: 5, course: 0, now: Self.t0 + 200) == nil)
        #expect(e.evaluate(places: [a, late], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 220)?.place == late)
    }

    // MARK: Hold for a better place just ahead (20.3)

    /// A (good, 100 m north) and B (top, 150 m north: 50 m beyond A, radius 80 m). The walker walks north.
    static let holdA = place("A", .good, north: 100), holdB = place("B", .top, north: 150)

    @Test func duePlaceWaitsForABetterOneApproaching() {
        // t0 at 30 N: A 70 m (not due), B 120 m. t0+10 at 45 N: A 55 m due; B 105 m (> 80, not due) and closer than
        // 120 → A is held. t0+20 at 65 N: B 85 m, still held. t0+30 at 92 N: B 58 m ≤ 60 → B (top) buzzes (20 s
        // into the hold).
        var e = Self.engine()
        let places = [Self.holdA, Self.holdB]
        #expect(e.decide(places: places, position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
                == .quiet(.noneDue, due: []))
        let held = e.decide(places: places, position: .at(north: 45), accuracy: 5, course: 0, now: Self.t0 + 10)
        guard case .quiet(.held, let due) = held else { Issue.record("expected held, got \(held)"); return }
        #expect(due.map(\.id) == ["A"])
        #expect(e.decide(places: places, position: .at(north: 65), accuracy: 5, course: 0, now: Self.t0 + 20).buzz == nil)
        #expect(e.evaluate(places: places, position: .at(north: 92), accuracy: 5, course: 0, now: Self.t0 + 30)?.place
                == Self.holdB)
    }
    @Test func holdLastsAtMostThirtySeconds() {
        // The walker creeps north, so B stays beyond its 80 m while approaching.
        // t0 at 39 N: A 61 m (not due), B 111 m.
        var e = Self.engine()
        let places = [Self.holdA, Self.holdB]
        #expect(e.evaluate(places: places, position: .at(north: 39), accuracy: 5, course: 0, now: Self.t0) == nil)
        // Walker at 46 N: A 54 m due, B 104 m approaching (111 → 104) → held, the hold starts at t0+10.
        guard case .quiet(.held, _) = e.decide(places: places, position: .at(north: 46), accuracy: 5, course: 0,
                                               now: Self.t0 + 10) else { Issue.record("expected held"); return }
        // t0+39 at 47 N: B 103 m, approaching; 39 − 10 = 29 s < 30 s → still held.
        guard case .quiet(.held, _) = e.decide(places: places, position: .at(north: 47), accuracy: 5, course: 0,
                                               now: Self.t0 + 39) else { Issue.record("expected held"); return }
        // t0+40 at 48 N: B 102 m, still approaching, but 40 − 10 = 30 s since the hold began → A buzzes.
        #expect(e.evaluate(places: places, position: .at(north: 48), accuracy: 5, course: 0, now: Self.t0 + 40)?.place
                == Self.holdA)
    }
    @Test func noHoldWhenTheBetterPlaceRecedesOrHasNoPreviousFix() {
        // First fix at 45 N: B has no previous distance → not approaching → A (55 m) buzzes at once.
        var e = Self.engine()
        #expect(e.evaluate(places: [Self.holdA, Self.holdB], position: .at(north: 45), accuracy: 5, course: 0,
                           now: Self.t0)?.place == Self.holdA)
        // t0 at 30 N: A 70 m, B 120 m. t0+5 at 50 N: A 50 m due, B 100 m approaching → held. t0+10 the walker
        // turned back to 45 N: B 105 m, receding (100 → 105) → A buzzes.
        var f = Self.engine()
        let places = [Self.holdA, Self.holdB]
        _ = f.decide(places: places, position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.held, _) = f.decide(places: places, position: .at(north: 50), accuracy: 5, course: 0,
                                               now: Self.t0 + 5) else { Issue.record("expected held"); return }
        #expect(f.evaluate(places: places, position: .at(north: 45), accuracy: 5, course: 180, now: Self.t0 + 10)?.place
                == Self.holdA)
    }
    @Test func noHoldForALowerRankedOrFarOrExcludedPlace() {
        // Lower ranked: A good with 10 sitelinks, B good with 5 (50 m beyond) → A buzzes at once.
        var e = Self.engine()
        let a = Self.place("A", .good, north: 100, sitelinks: 10), lower = Self.place("B", .good, north: 150, sitelinks: 5)
        _ = e.decide(places: [a, lower], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        #expect(e.evaluate(places: [a, lower], position: .at(north: 45), accuracy: 5, course: 0, now: Self.t0 + 10)?.place == a)
        // Better within the tier by sitelinks (B good with 50 sitelinks, A 10): held.
        var f = Self.engine()
        let better = Self.place("B", .good, north: 150, sitelinks: 50)
        _ = f.decide(places: [a, better], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.held, _) = f.decide(places: [a, better], position: .at(north: 45), accuracy: 5, course: 0,
                                               now: Self.t0 + 10) else { Issue.record("expected held"); return }
        // Too far: B top 61 m beyond A (161 N) → A buzzes.
        var g = Self.engine()
        let far = Self.place("B", .top, north: 161)
        _ = g.decide(places: [Self.holdA, far], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        #expect(g.evaluate(places: [Self.holdA, far], position: .at(north: 45), accuracy: 5, course: 0, now: Self.t0 + 10)?.place
                == Self.holdA)
        // Excluded: B already heard → A buzzes.
        var h = Self.engine()
        h.exclude("B")
        _ = h.decide(places: [Self.holdA, Self.holdB], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        #expect(h.evaluate(places: [Self.holdA, Self.holdB], position: .at(north: 45), accuracy: 5, course: 0,
                           now: Self.t0 + 10)?.place == Self.holdA)
    }

    // MARK: Complexes (20.4)

    @Test func lowerRankedPlacesWithinFiftyFiveMetresOfABuzzAreExcluded() {
        // Il Gesù (top, 40 sitelinks) at 30 m buzzes. Then, with the budget full again (t0+3600, 3 tokens):
        // Palazzo Altieri (good) 39 m beyond (69 N) is lower-ranked and within 55 m → excluded;
        // a top with 40 sitelinks 39 m beyond on the other side (east 39 from Il Gesù) ranks equal → free;
        // a good 56 m beyond (86 N) → free.
        var e = Self.engine()
        let gesu = Self.place("gesu", .top, north: 30, sitelinks: 40)
        let altieri = Self.place("altieri", .good, north: 69, sitelinks: 3)
        let equal = Self.place("equal", .top, north: 30, east: 39, sitelinks: 40)
        let farther = Self.place("farther", .good, north: 86, sitelinks: 3)
        #expect(e.evaluate(places: [gesu], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == gesu)
        let d = e.decide(places: [altieri], position: .at(north: 50), accuracy: 5, course: 0, now: Self.t0 + 3600)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.map(\.excluded) == [true])
        #expect(e.evaluate(places: [equal], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 3600)?.place
                == equal)
        var f = Self.engine()
        _ = f.evaluate(places: [gesu], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        #expect(f.evaluate(places: [farther], position: .at(north: 50), accuracy: 5, course: 0, now: Self.t0 + 3600)?.place
                == farther)
        #expect(BuzzEngine.complexRadius == 55)
    }
    @Test func aBetterRankedPlaceNearABuzzIsNotExcluded() {
        // small (good, 20 m) buzzes with only itself in the list. big (top, 55 m) arrives in a later list, 35 m from
        // small (> 25 m, ≤ 40 m) but better ranked → not excluded: it buzzes once the budget allows (t0+3600).
        var e = Self.engine()
        let small = Self.place("small", .good, north: 20, sitelinks: 2)
        let big = Self.place("big", .top, north: 55, sitelinks: 2)
        #expect(e.evaluate(places: [small], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == small)
        #expect(e.evaluate(places: [small, big], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 3600)?.place == big)
    }
    @Test func complexRuleAppliesToAHeardPlace() {
        // Heard: a Wikipedia-only place item with 50 sitelinks (top by facts) at 30 m. A good place 35 m beyond
        // is excluded with it; a top with 60 sitelinks there is not.
        var e = Self.engine()
        let heard = Candidate(id: "wiki:it/1", name: "Heard", coordinate: .at(north: 30), kind: "wikipedia",
                              summary: "S.", wikipediaTitle: "it:Heard", wikidata: "Q1", sitelinks: 50, placeClass: .place)
        e.excludeSpot(of: heard)
        // 10 sitelinks: since spec 20.4.1 the complex rule takes only places with fewer than 20.
        let good = Self.place("good", .good, north: 65, sitelinks: 10)
        let famous = Self.place("famous", .top, north: 65, sitelinks: 60)
        let d = e.decide(places: [good], position: .at(north: 40), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [good, famous], position: .at(north: 40), accuracy: 5, course: 0, now: Self.t0)?.place
                == famous)
    }

    // MARK: Cadence (20.7)

    @Test func thirtySecondsBeforeATopPlaceWhateverTheBudget() {
        // 60/h: one token per 60 s, at most 3. At t0+120 there are 3 tokens: a buzzes; b (top, 50 m from the walker,
        // 60 m from a) has budget left but must wait 30 s (spec 20.2.1): quiet minGap at +29 s, buzz at +30 s.
        var e = Self.engine(perHour: 60)
        let a = Self.place("a", .top, north: 10), b = Self.place("b", .top, north: -50)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 149)
        guard case .quiet(.minGap, let due) = d else { Issue.record("expected minGap, got \(d)"); return }
        #expect(Set(due.map(\.id)) == ["a", "b"])
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 150)?.place == b)
        #expect(BuzzEngine.topGap == 30 && BuzzEngine.middleGap == 120 && BuzzEngine.otherGap == 240)
    }
    @Test func theGapHoldsBackAnOverrideToo() {
        // 5/h. a (top, 5 m S) buzzes at t0; the castle (top, 30 m N, 35 m from a: equal rank, not excluded) is due,
        // closest 30. t0+10 at 125 N: castle 95 m (≥ 90, > 30 + 10) would override, but 10 s < 30 s → minGap.
        // t0+30: override.
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: -5), castle = Self.place("castle", .top, north: 30)
        #expect(e.evaluate(places: [a, castle], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == a)
        let d = e.decide(places: [a, castle], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 10)
        guard case .quiet(.minGap, _) = d else { Issue.record("expected minGap, got \(d)"); return }
        let o = e.evaluate(places: [a, castle], position: .at(north: 125), accuracy: 5, course: 0, now: Self.t0 + 30)
        #expect(o?.place == castle && o?.usedOverride == true)
    }
    @Test func aClockSetBackDoesNotHoldBuzzesOff() {
        // A buzz at t0+120, then a fix dated t0 (clock set back 120 s): the gap does not count a negative age.
        var e = Self.engine(perHour: 60)
        let a = Self.place("a", .good, north: 10), b = Self.place("b", .good, north: -50)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        // Budget: the accrual point stays at t0+120 with 3 − 1 = 2 tokens → b can spend.
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == b)
    }
}

// MARK: - Spec 20.2: gap by rank, exclusion by rank, closest approach, 55 m complexes

@Suite struct BuzzEngineIteration2Tests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func place(_ id: String, _ tier: PlaceTier, north: Double, east: Double = 0, sitelinks: Int? = nil,
                      wikidata: String? = nil, placeClass: PlaceClass? = nil) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                          wikidata: wikidata, sitelinks: sitelinks, placeClass: placeClass),
                     tier: tier)
    }
    static func engine(perHour: Int = 60) -> BuzzEngine {
        BuzzEngine(perHour: perHour, now: t0, excluded: [])
    }

    // MARK: Gap by rank (20.2.1)

    @Test func gapDependsOnTheNextPlacesRank() {
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .top, north: 0)) == 30)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .top, north: 0, sitelinks: 148)) == 30)
        // Spec 20.3.1 replaced the 90 s for good with ≥ 10 sitelinks: 10 and 9 both wait 240 s.
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 10)) == 240)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 9)) == 240)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: nil)) == 240)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .wikiOnly, north: 0, sitelinks: 344)) == 240)
    }
    /// 60/h: at t0+120 the budget holds 3 tokens. a (good, 12 sitelinks, 10 m N) buzzes; then `next` (50 m S, 60 m
    /// from a: beyond 55 m) waits `gap` seconds: quiet minGap one second before, a buzz at the gap.
    func expectGap(_ next: WalkingPlace, gap: TimeInterval) {
        var e = Self.engine()
        let a = Self.place("a", .good, north: 10, sitelinks: 12)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        let d = e.decide(places: [a, next], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120 + gap - 1)
        guard case .quiet(.minGap, _) = d else { Issue.record("expected minGap for \(next.candidate.id), got \(d)"); return }
        #expect(e.evaluate(places: [a, next], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120 + gap)?.place
                == next)
    }
    @Test func topWaitsThirtySeconds() {
        expectGap(Self.place("top", .top, north: -50, sitelinks: 32), gap: 30)
    }
    @Test func goodWithTenSitelinksWaitsFourMinutes() {
        // Spec 20.3.1 (was 90 s in 20.2.1).
        expectGap(Self.place("good", .good, north: -50, sitelinks: 10), gap: 240)
    }
    @Test func minorPlacesWaitFourMinutes() {
        expectGap(Self.place("minor", .good, north: -50, sitelinks: 9), gap: 240)
        expectGap(Self.place("wiki", .wikiOnly, north: -50, sitelinks: 59), gap: 240)
    }
    @Test func aTopPlaceBuzzesWhileAMinorOneStillWaits() {
        // After a's buzz at t0+120: at +60 the minor place (40 m S) still waits 240 s, the top place (50 m S, 30 m
        // E: sqrt(50² + 30²) = 58.3 m away) only 30 s → the top place buzzes.
        var e = Self.engine()
        let a = Self.place("a", .good, north: 10, sitelinks: 12)
        let minor = Self.place("minor", .wikiOnly, north: -40), top = Self.place("top", .top, north: -50, east: 30)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        #expect(e.evaluate(places: [a, minor, top], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 180)?.place
                == top)
    }

    // MARK: Exclusion by rank (20.2.2)

    @Test func sameSpotExcludesOnlyEqualOrLowerRanks() {
        // g (good, 20 sitelinks) buzzes at 30 m. Within 10 m of it: a top place (better) may still buzz after its
        // 30 s gap; a good place with 20 sitelinks (equal) and a Wiki-only place (lower) are excluded.
        var e = Self.engine()
        let g = Self.place("g", .good, north: 30, sitelinks: 20)
        let better = Self.place("better", .top, north: 40, sitelinks: 32)
        let equal = Self.place("equal", .good, north: 20, sitelinks: 20)
        let lower = Self.place("lower", .wikiOnly, north: 35, sitelinks: 50)
        #expect(e.evaluate(places: [g], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == g)
        let d = e.decide(places: [g, equal, lower], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 600)
        guard case .quiet(.allExcluded, let due) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(due.allSatisfy { $0.excluded })
        #expect(e.evaluate(places: [g, equal, lower, better], position: .at(), accuracy: 5, course: 0,
                           now: Self.t0 + 600)?.place == better)
    }
    @Test func sameWikidataIdAlwaysExcludes() {
        // A buzzed Wiki-only page of Q5; a top OSM twin of Q5 100 m away is excluded although it ranks higher.
        var e = Self.engine()
        let page = Self.place("wiki:en/5", .wikiOnly, north: 20, sitelinks: 3, wikidata: "Q5")
        let twin = Self.place("osm:way/5", .top, north: -50, sitelinks: 3, wikidata: "Q5")
        #expect(e.evaluate(places: [page], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == page)
        let d = e.decide(places: [twin], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 600)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
    }
    @Test func hillsAndIslandsExcludeNoOtherPlace() {
        // Capitoline Hill (natural, good 68) buzzes at 30 m (t0+120). A Wiki-only place 5 m from it buzzes after its
        // 240 s gap (t0+360), then the Capitoline Museums (good 46, 20 m from the hill) after its 30 s (t0+450); only
        // the hill's own Wikidata id stays excluded.
        var e = Self.engine()
        let hill = Self.place("hill", .good, north: 30, sitelinks: 68, wikidata: "Q34925", placeClass: .natural)
        let museum = Self.place("museum", .good, north: 50, sitelinks: 46)
        let minor = Self.place("minor", .wikiOnly, north: 35, sitelinks: 3)
        let twin = Self.place("twin", .good, north: 31, sitelinks: 68, wikidata: "Q34925")
        #expect(e.evaluate(places: [hill], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == hill)
        #expect(e.evaluate(places: [hill, twin, minor], position: .at(), accuracy: 5, course: 0,
                           now: Self.t0 + 360)?.place == minor)
        // The museum ranks above the Wiki-only place, so that buzz does not exclude it either.
        #expect(e.evaluate(places: [hill, twin, museum, minor], position: .at(), accuracy: 5, course: 0,
                           now: Self.t0 + 450)?.place == museum)
        let d = e.decide(places: [hill, twin], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 3_600)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
    }
    @Test func aHeardHillExcludesNoNeighbourEither() {
        var e = Self.engine()
        let hill = Candidate(id: "wiki:no/1", name: "Kapitolhøyden", coordinate: .at(north: 30), kind: "wikipedia",
                             wikidata: "Q34925", sitelinks: 68, placeClass: .natural)
        e.excludeSpot(of: hill)
        let museum = Self.place("museum", .good, north: 40, sitelinks: 46)
        #expect(e.evaluate(places: [museum], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == museum)
    }

    // MARK: Complex radius 55 m (20.2.5)

    @Test func complexRadiusIsFiftyFiveMetresForLowerRanks() {
        // Top (40 sitelinks) at 30 m buzzes. A good place (19 sitelinks: the rule takes only fewer than 20 since spec
        // 20.4.1) 54 m from it (84 N) is excluded, one 56 m from it (86 N) is free; an equal top 54 m away (30 N, 54 E)
        // is free too (the complex rule takes strictly lower ranks).
        #expect(BuzzEngine.complexRadius == 55)
        let gesu = Self.place("gesu", .top, north: 30, sitelinks: 40)
        var e = Self.engine(), f = Self.engine(), g = Self.engine()
        #expect(e.evaluate(places: [gesu], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == gesu)
        let near = Self.place("near", .good, north: 84, sitelinks: 19)
        let d = e.decide(places: [near], position: .at(north: 60), accuracy: 5, course: 0, now: Self.t0 + 3_600)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        _ = f.evaluate(places: [gesu], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        let far = Self.place("far", .good, north: 86, sitelinks: 19)
        #expect(f.evaluate(places: [far], position: .at(north: 60), accuracy: 5, course: 0, now: Self.t0 + 3_600)?.place
                == far)
        _ = g.evaluate(places: [gesu], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        let equal = Self.place("equal", .top, north: 30, east: 54, sitelinks: 40)
        #expect(g.evaluate(places: [equal], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0 + 3_600)?.place
                == equal)
    }

    // MARK: Closest approach beyond 60 m (20.2.3)

    @Test func beyondSixtyMetresAPlaceBuzzesOncePassed() {
        // Trevi (top, 68 sitelinks, radius 100) at 200 N, 70 E; the walker walks north along east 0.
        // y 130: sqrt(70² + 70²) = 99.0 m → tracked, closest 99, not grown → quiet.
        // y 170: sqrt(30² + 70²) = 76.2 m; y 200: 70.0 m (closest 70); y 205: sqrt(5² + 70²) = 70.2 m (< 70 + 5).
        // y 230: sqrt(30² + 70²) = 76.2 m ≥ 70 + 5 → buzz, "behind".
        var e = Self.engine()
        let trevi = Self.place("trevi", .top, north: 200, east: 70, sitelinks: 68)
        for (y, dt) in [(130.0, 0.0), (170, 30), (200, 50), (205, 55)] {
            let d = e.decide(places: [trevi], position: .at(north: y), accuracy: 5, course: 0, now: Self.t0 + dt)
            guard case .quiet(.noneDue, let due) = d else { Issue.record("expected noneDue at \(y), got \(d)"); return }
            #expect(due.map(\.id) == ["trevi"])
        }
        #expect(e.evaluate(places: [trevi], position: .at(north: 230), accuracy: 5, course: 0, now: Self.t0 + 75)?.place
                == trevi)
        #expect(BuzzEngine.passedMargin == 5)
    }
    @Test func withinSixtyMetresAPlaceBuzzesAtOnce() {
        // The same walk past a place 50 m east: at y 170 it is sqrt(30² + 50²) = 58.3 m ≤ 60 → buzz while approaching.
        var e = Self.engine()
        let near = Self.place("near", .top, north: 200, east: 50, sitelinks: 68)
        #expect(e.evaluate(places: [near], position: .at(north: 130), accuracy: 5, course: 0, now: Self.t0) == nil)
        #expect(e.evaluate(places: [near], position: .at(north: 170), accuracy: 5, course: 0, now: Self.t0 + 30)?.place
                == near)
    }
    @Test func anApproachingWidePlaceIsNotDueAndHoldsALowerOne() {
        // A (good, 12 sitelinks) at 100 N; B (top, 32 sitelinks, radius 80) at 150 N. t0 at 30 N: A 70, B 120.
        // t0+10 at 45 N: A 55 m may buzz; B 105 m approaching → A held. t0+20 at 75 N: B 75 m, inside 80 m but
        // still approaching (not passed) → still held. t0+28 at 92 N: B 58 m ≤ 60 → B buzzes.
        var e = Self.engine()
        let a = Self.place("A", .good, north: 100, sitelinks: 12), b = Self.place("B", .top, north: 150, sitelinks: 32)
        _ = e.decide(places: [a, b], position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
        for (y, dt) in [(45.0, 10.0), (75, 20)] {
            let d = e.decide(places: [a, b], position: .at(north: y), accuracy: 5, course: 0, now: Self.t0 + dt)
            guard case .quiet(.held, _) = d else { Issue.record("expected held at \(y), got \(d)"); return }
        }
        #expect(e.evaluate(places: [a, b], position: .at(north: 92), accuracy: 5, course: 0, now: Self.t0 + 28)?.place == b)
    }
}

// MARK: - Spec 20.3: gap by importance, hold for closest approach, «behind you», famous art

@Suite struct BuzzEngineIteration3Tests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func place(_ id: String, _ tier: PlaceTier, north: Double, east: Double = 0, sitelinks: Int? = nil,
                      wikidata: String? = nil, isArt: Bool? = nil) -> WalkingPlace {
        var candidate = Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                  wikidata: wikidata, sitelinks: sitelinks)
        candidate.isArt = isArt
        return WalkingPlace(candidate: candidate, tier: tier)
    }
    static func engine(perHour: Int = 60) -> BuzzEngine {
        BuzzEngine(perHour: perHour, now: t0, excluded: [])
    }

    // MARK: Gap by importance (20.3.1)

    @Test func gapFollowsSitelinksNotTier() {
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .top, north: 0)) == 30)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 25)) == 30)
        // 20–24 became 90 s in spec 20.4.4.
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 24)) == 90)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 15)) == 120)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: 14)) == 240)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: nil)) == 240)
        // Wiki-only waits 240 s whatever its sitelinks.
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .wikiOnly, north: 0, sitelinks: 59)) == 240)
        #expect(BuzzEngine.topGap == 30 && BuzzEngine.middleGap == 120 && BuzzEngine.otherGap == 240)
        #expect(BuzzEngine.topGapSitelinks == 25 && BuzzEngine.middleGapSitelinks == 15)
    }
    /// 60/h: at t0+120 the budget holds 3 tokens. a (top, 10 m N) buzzes; then `next` (50 m S, 60 m from a, beyond
    /// 55 m) waits `gap`: minGap one second before, a buzz at the gap.
    func expectGap(_ next: WalkingPlace, gap: TimeInterval) {
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10, sitelinks: 40)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        let d = e.decide(places: [a, next], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120 + gap - 1)
        guard case .quiet(.minGap, _) = d else { Issue.record("expected minGap for \(next.candidate.id), got \(d)"); return }
        #expect(e.evaluate(places: [a, next], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120 + gap)?.place
                == next)
    }
    @Test func goodWithTwentyFiveSitelinksWaitsThirtySeconds() {
        // Vespasian's Forum (28) and Pons Fabricius (25) are no longer held back 90 s.
        expectGap(Self.place("forum", .good, north: -50, sitelinks: 25), gap: 30)
    }
    @Test func goodWithFifteenSitelinksWaitsTwoMinutes() {
        expectGap(Self.place("callisto", .good, north: -50, sitelinks: 15), gap: 120)
    }
    @Test func goodWithFourteenSitelinksWaitsFourMinutes() {
        expectGap(Self.place("pigna", .good, north: -50, sitelinks: 14), gap: 240)
    }

    // MARK: Hold for closest approach (20.3.2)

    /// B (top, 40 sitelinks, radius 100) at the origin; A (good, 12) at 40 N 40 E, sqrt(40² + 40²) = 56.6 m from B.
    static let waitingB = place("B", .top, north: 0, sitelinks: 40)
    static let lesserA = place("A", .good, north: 40, east: 40, sitelinks: 12)

    @Test func aLesserPlaceWaitsWhileABetterOneWaitsForItsClosestApproach() {
        // t0 at (−69.28 N, 40 E): B sqrt(69.28² + 40²) = 80.0 m (tracked, closest 80); A 109.3 m.
        // t0+10 at (0 N, 82 E): B 82 m, receding but not passed (82 < 80 + 5) → due and waiting; A
        // sqrt(40² + 42²) = 58.0 m may buzz → held (B is not approaching: the 20.3.2 rule, not 20.1.3).
        // t0+20 same spot: still held. t0+40: 30 s since the hold began → A buzzes.
        var e = Self.engine()
        let places = [Self.lesserA, Self.waitingB]
        _ = e.decide(places: places, position: .at(north: -69.28, east: 40), accuracy: 5, course: 0, now: Self.t0)
        for dt in [10.0, 20, 39] {
            let d = e.decide(places: places, position: .at(east: 82), accuracy: 5, course: 0, now: Self.t0 + dt)
            guard case .quiet(.held, _) = d else { Issue.record("expected held at +\(dt), got \(d)"); return }
        }
        #expect(e.evaluate(places: places, position: .at(east: 82), accuracy: 5, course: 0, now: Self.t0 + 40)?.place
                == Self.lesserA)
    }
    @Test func theBetterPlaceBuzzesOncePassed() {
        // As above; at t0+20 the walker is at (0 N, 86 E): B 86 m ≥ 80 + 5 → passed → B (top) buzzes.
        var e = Self.engine()
        let places = [Self.lesserA, Self.waitingB]
        _ = e.decide(places: places, position: .at(north: -69.28, east: 40), accuracy: 5, course: 0, now: Self.t0)
        _ = e.decide(places: places, position: .at(east: 82), accuracy: 5, course: 0, now: Self.t0 + 10)
        #expect(e.evaluate(places: places, position: .at(east: 86), accuracy: 5, course: 0, now: Self.t0 + 20)?.place
                == Self.waitingB)
    }
    @Test func aWaitingPlaceFartherThanSixtyMetresHoldsNothing() {
        // A moved to 45 N 42 E: sqrt(45² + 42²) = 61.6 m from B (> 60). t0 at (−69.28 N, 40 E): B 80.0 m, A 114.3 m.
        // t0+10 at (5 N, 82 E): B sqrt(5² + 82²) = 82.2 m, due and waiting (< 85); A sqrt(40² + 40²) = 56.6 m → no
        // hold, A buzzes.
        var e = Self.engine()
        let farA = Self.place("A", .good, north: 45, east: 42, sitelinks: 12)
        let places = [farA, Self.waitingB]
        _ = e.decide(places: places, position: .at(north: -69.28, east: 40), accuracy: 5, course: 0, now: Self.t0)
        #expect(e.evaluate(places: places, position: .at(north: 5, east: 82), accuracy: 5, course: 0,
                           now: Self.t0 + 10)?.place == farA)
    }

    // MARK: «Behind you» (20.3.3)

    /// x (top, 40, at 10 S 50 E: 51 m) buzzes at t0. The story runs from t0+1 to t0+10. p (good, 32 sitelinks, 50 m
    /// N, 78 m from x) is due during it (tracked within 60 m at t0+5). The walker is then 40 m S: p 90 m behind. The
    /// engine starts at t0 − 180 at 60/h, so its budget is full (3) at t0.
    static let x = place("x", .top, north: -10, east: 50, sitelinks: 40)
    func storyPassing(_ p: WalkingPlace, end: Date = t0 + 10) -> BuzzEngine {
        var e = BuzzEngine(perHour: 60, now: Self.t0 - 180, excluded: [])
        #expect(e.evaluate(places: [Self.x], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == Self.x)
        e.setBusy(true, at: Self.t0 + 1)
        let d = e.decide(places: [Self.x, p], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 5)
        guard case .quiet(.busy, _) = d else { Issue.record("expected busy, got \(d)"); return e }
        _ = e.decide(places: [Self.x, p], position: .at(north: -40), accuracy: 5, course: 180, now: Self.t0 + 9)
        e.setBusy(false, at: end)
        return e
    }
    static let p32 = place("p", .good, north: 50, sitelinks: 32)

    @Test func aFamousPlacePassedDuringAStoryBuzzesWhenItEnds() {
        // End at t0+10; at t0+10 + 59.9 the walker is 40 m S: p 90 m (> 60, not passed-and-buzzable for good) →
        // «behind you», although only 69.9 s after x's buzz (its 30 s gap is ignored anyway) and p is beyond 60 m.
        var e = storyPassing(Self.p32)
        let b = e.evaluate(places: [Self.x, Self.p32], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 10 + 59.9)
        #expect(b?.place == Self.p32)
        #expect(b?.detail == "90 m behind you")
        #expect(BuzzEngine.behindYouWindow == 60 && BuzzEngine.behindYouSitelinks == 30)
    }
    @Test func behindYouEndsSixtySecondsAfterTheStory() {
        var e = storyPassing(Self.p32)
        let d = e.decide(places: [Self.x, Self.p32], position: .at(north: -40), accuracy: 5, course: 180,
                         now: Self.t0 + 10 + 60)
        #expect(d.buzz == nil)
    }
    @Test func behindYouReachesBeyondTheDropRadius() {
        // −70 → 50 N: exactly 120 m (checked); −71 → 121 m, beyond the 120 m drop radius, still buzzes since the
        // reach is 150 m (spec 20.4.3; the 150/151 m boundary is pinned in BuzzEngineIteration4Tests).
        #expect(GeoMath.distance(.at(north: -70), .at(north: 50)) == 120)
        var e = storyPassing(Self.p32), f = storyPassing(Self.p32)
        #expect(e.evaluate(places: [Self.x, Self.p32], position: .at(north: -70), accuracy: 5, course: 180,
                           now: Self.t0 + 20)?.place == Self.p32)
        #expect(f.evaluate(places: [Self.x, Self.p32], position: .at(north: -71), accuracy: 5, course: 180,
                           now: Self.t0 + 20)?.place == Self.p32)
    }
    @Test func behindYouNeedsThirtySitelinks() {
        let p29 = Self.place("p", .good, north: 50, sitelinks: 29)
        var e = storyPassing(p29)
        #expect(e.evaluate(places: [Self.x, p29], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 20) == nil)
        let p30 = Self.place("p", .good, north: 50, sitelinks: 30)
        var f = storyPassing(p30)
        #expect(f.evaluate(places: [Self.x, p30], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 20)?.place == p30)
    }
    @Test func behindYouSkipsExcludedPlacesAndPlacesNotDueDuringTheStory() {
        var e = storyPassing(Self.p32)
        e.exclude("p")
        #expect(e.evaluate(places: [Self.x, Self.p32], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 20) == nil)
        // q (good, 40 sitelinks, 70 m N) was 70 m away during the story: never due (radius 60) → nothing after.
        let q = Self.place("q", .good, north: 70, sitelinks: 40)
        var f = storyPassing(q)
        #expect(f.evaluate(places: [Self.x, q], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 20) == nil)
    }
    @Test func behindYouHappensOncePerStory() {
        // p and r (good, 35, at 20 N 56 W: 59.5 m from the walker, 63.5 m from p, so its buzz does not exclude p)
        // were both due. The first «behind you» is r (more sitelinks), at sqrt(60² + 56²) = 82 m; p then waits for
        // its normal rules: 90 m away (> 60) → no second buzz, although the window (to t0+70) is still open.
        let r = Self.place("r", .good, north: 20, east: -56, sitelinks: 35)
        var e = BuzzEngine(perHour: 60, now: Self.t0 - 180, excluded: [])
        #expect(e.evaluate(places: [Self.x], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == Self.x)
        e.setBusy(true, at: Self.t0 + 1)
        _ = e.decide(places: [Self.x, Self.p32, r], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 5)
        e.setBusy(false, at: Self.t0 + 10)
        #expect(e.evaluate(places: [Self.x, Self.p32, r], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 15)?.place == r)
        #expect(e.evaluate(places: [Self.x, Self.p32, r], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 50) == nil)
    }
    @Test func busyEndSetThroughThePropertyCountsFromTheNextFix() {
        // isBusy = false without a time: the window starts at the next decision (t0+30) and ends 60 s later.
        var e = Self.engine()
        e.isBusy = true
        _ = e.decide(places: [Self.p32], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 5)
        e.isBusy = false
        _ = e.decide(places: [], position: .at(north: -40), accuracy: 5, course: 180, now: Self.t0 + 30)
        #expect(e.evaluate(places: [Self.p32], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 89.9)?.place == Self.p32)
        var f = Self.engine()
        f.isBusy = true
        _ = f.decide(places: [Self.p32], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 5)
        f.isBusy = false
        _ = f.decide(places: [], position: .at(north: -40), accuracy: 5, course: 180, now: Self.t0 + 30)
        #expect(f.evaluate(places: [Self.p32], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 90) == nil)
    }

    // MARK: Famous art (20.3.5)

    @Test func famousArtIsNotExcludedByTheSquareAroundIt() {
        // Piazza Navona (top, 47) buzzes at 20 m. The Fountain of the Four Rivers (art, 36) stands at the same spot
        // and ranks lower: not excluded, it buzzes after its 30 s gap. Art with 29 sitelinks, or a non-art item with
        // 36, at that spot is excluded; so is art with the square's own Wikidata id.
        var e = Self.engine()
        let navona = Self.place("navona", .top, north: 20, sitelinks: 47, wikidata: "Q1")
        let fountain = Self.place("fountain", .top, north: 20, sitelinks: 36, isArt: true)
        let minorArt = Self.place("minorArt", .good, north: 21, sitelinks: 29, isArt: true)
        let plain = Self.place("plain", .top, north: 22, sitelinks: 36)
        let twin = Self.place("twin", .top, north: 23, sitelinks: 36, wikidata: "Q1", isArt: true)
        #expect(e.evaluate(places: [navona], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == navona)
        let d = e.decide(places: [navona, minorArt, plain, twin], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 600)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [navona, minorArt, plain, twin, fountain], position: .at(), accuracy: 5, course: 0,
                           now: Self.t0 + 600)?.place == fountain)
        #expect(BuzzEngine.famousArtSitelinks == 30)
    }
    @Test func famousArtIsNotExcludedByTheComplexRuleEither() {
        // A church (top, 60) buzzes at 20 m; a fountain (art, 30, good) 40 m from it is lower but not excluded.
        var e = Self.engine()
        let church = Self.place("church", .top, north: 20, sitelinks: 60)
        let fountain = Self.place("fountain", .good, north: -20, sitelinks: 30, isArt: true)
        #expect(e.evaluate(places: [church], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == church)
        #expect(e.evaluate(places: [church, fountain], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 600)?.place
                == fountain)
    }
}

// MARK: - Spec 20.4: complexes only for minor places, better place first, «behind you» to 150 m, 90 s gap

@Suite struct BuzzEngineIteration4Tests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func place(_ id: String, _ tier: PlaceTier, north: Double, east: Double = 0, sitelinks: Int?) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "x",
                                          sitelinks: sitelinks),
                     tier: tier)
    }
    /// 60/h, started at t0 − 180 so the budget is full (3) at t0.
    static func engine() -> BuzzEngine {
        BuzzEngine(perHour: 60, now: t0 - 180, excluded: [])
    }

    // MARK: Complexes only for minor places (20.4.1)

    @Test func complexRuleTakesOnlyPlacesWithFewerThanTwentySitelinks() {
        // Porticus Octaviae (top, 27) buzzes at 20 m. 46 m from it: the Great Synagogue (good, 22) is not excluded
        // (≥ 20); a good place with 19 sitelinks there is. Within 25 m a lower place with 22 sitelinks is still
        // excluded by the same spot.
        #expect(BuzzEngine.complexMaxSitelinks == 20)
        let porticus = Self.place("porticus", .top, north: 20, sitelinks: 27)
        let synagogue = Self.place("synagogue", .good, north: -26, sitelinks: 22)
        let minor = Self.place("minor", .good, north: -26, east: 1, sitelinks: 19)
        let spot = Self.place("spot", .good, north: 40, sitelinks: 22)
        var e = Self.engine()
        #expect(e.evaluate(places: [porticus], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == porticus)
        let d = e.decide(places: [porticus, minor, spot], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 600)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [porticus, minor, spot, synagogue], position: .at(), accuracy: 5, course: 0,
                           now: Self.t0 + 600)?.place == synagogue)
    }

    // MARK: Better place first (20.4.2)

    @Test func firstDecisionHoldsALesserPlaceForABetterOneWithNoPreviousDistance() {
        // The 18:25 walk: Palazzo Bonaparte (Wiki-only, 9) due at 40 m N; Piazza Venezia (top, 38, radius 100) at
        // 60 N 50 E: sqrt(60² + 50²) = 78.1 m from the walker, inside its radius, no previous distance (first
        // decision of the run), and sqrt(20² + 50²) = 53.9 m from Bonaparte (≤ 60) → Bonaparte is held.
        var e = Self.engine()
        let bonaparte = Self.place("bonaparte", .wikiOnly, north: 40, sitelinks: 9)
        let venezia = Self.place("venezia", .top, north: 60, east: 50, sitelinks: 38)
        let d = e.decide(places: [bonaparte, venezia], position: .at(), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.held, _) = d else { Issue.record("expected held, got \(d)"); return }
    }
    @Test func aPlaceJustAddedToTheListCountsAsApproachingToo() {
        // t0: only Bonaparte is listed, 70 m away (walker at 30 S): not due. t0+10 the walker is at the origin
        // (Bonaparte 40 m, due) and Piazza Venezia appears in the list for the first time → Bonaparte held.
        var e = Self.engine()
        let bonaparte = Self.place("bonaparte", .wikiOnly, north: 40, sitelinks: 9)
        let venezia = Self.place("venezia", .top, north: 60, east: 50, sitelinks: 38)
        _ = e.decide(places: [bonaparte], position: .at(north: -30), accuracy: 5, course: 0, now: Self.t0)
        let d = e.decide(places: [bonaparte, venezia], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 10)
        guard case .quiet(.held, _) = d else { Issue.record("expected held, got \(d)"); return }
    }

    /// x (top, 40) at 10 S 50 E buzzes at t0; the story runs t0+1 … t0+10; at t0+5 (walker at the origin) `behind`
    /// (50 m N) is due; afterwards the walker is 40 m S.
    static let x = place("x", .top, north: -10, east: 50, sitelinks: 40)
    func story(_ behind: WalkingPlace) -> BuzzEngine {
        var e = Self.engine()
        #expect(e.evaluate(places: [Self.x], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == Self.x)
        e.setBusy(true, at: Self.t0 + 1)
        _ = e.decide(places: [Self.x, behind], position: .at(), accuracy: 5, course: 180, now: Self.t0 + 5)
        e.setBusy(false, at: Self.t0 + 10)
        return e
    }
    @Test func behindYouGoesBeforeADuePlaceWithFewerSitelinks() {
        // Piazza Venezia (top, 38) was due during the story and is 90 m behind; Palazzo Venezia (top, 32) at 80 S is
        // due 40 m ahead. 32 < 38 → «behind you» first.
        let piazza = Self.place("piazza", .top, north: 50, sitelinks: 38)
        let palazzo = Self.place("palazzo", .top, north: -80, sitelinks: 32)
        var e = story(piazza)
        #expect(e.evaluate(places: [Self.x, piazza, palazzo], position: .at(north: -40), accuracy: 5, course: 180,
                           now: Self.t0 + 45)?.place == piazza)
    }
    @Test func aDuePlaceWithAsManyOrMoreSitelinksGoesFirst() {
        // Same, but the place ahead has 38 (equal) or 50 (more): it buzzes first; «behind you» stays pending in
        // the window and follows on a later fix (here at t0+50, still within 60 s of the end).
        for sitelinks in [38, 50] {
            let piazza = Self.place("piazza", .top, north: 50, sitelinks: 38)
            let ahead = Self.place("ahead", .top, north: -80, sitelinks: sitelinks)
            var e = story(piazza)
            #expect(e.evaluate(places: [Self.x, piazza, ahead], position: .at(north: -40), accuracy: 5, course: 180,
                               now: Self.t0 + 45)?.place == ahead, "ahead with \(sitelinks)")
            #expect(e.evaluate(places: [Self.x, piazza, ahead], position: .at(north: -40), accuracy: 5, course: 180,
                               now: Self.t0 + 50)?.place == piazza, "then behind with \(sitelinks)")
        }
    }

    // MARK: «Behind you» to 150 m (20.4.3)

    @Test func behindYouReachesOneHundredFiftyMetresInclusive() {
        // −100 → 50 N: exactly 150 m (checked); −101 → 151 m.
        #expect(GeoMath.distance(.at(north: -100), .at(north: 50)) == 150)
        #expect(BuzzEngine.behindYouRadius == 150)
        let p = Self.place("p", .good, north: 50, sitelinks: 32)
        var e = story(p), f = story(p)
        #expect(e.evaluate(places: [Self.x, p], position: .at(north: -100), accuracy: 5, course: 180,
                           now: Self.t0 + 20)?.place == p)
        #expect(f.evaluate(places: [Self.x, p], position: .at(north: -101), accuracy: 5, course: 180,
                           now: Self.t0 + 20) == nil)
    }

    // MARK: Gap (20.4.4)

    @Test func gapIsNinetySecondsForTwentyToTwentyFourSitelinks() {
        // 30 s for top or ≥ 25; 90 s for 20–24; 120 s for 15–19; 240 s for fewer or Wiki-only.
        let gaps = [(25, 30.0), (24, 90), (20, 90), (19, 120), (15, 120), (14, 240)].map { sitelinks, gap in
            (BuzzEngine.minimumGap(for: Self.place("a", .good, north: 0, sitelinks: sitelinks)), gap)
        }
        for (got, want) in gaps { #expect(got == want) }
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .top, north: 0, sitelinks: 3)) == 30)
        #expect(BuzzEngine.minimumGap(for: Self.place("a", .wikiOnly, north: 0, sitelinks: 24)) == 240)
        #expect(BuzzEngine.highGap == 90 && BuzzEngine.highGapSitelinks == 20)
    }
}
