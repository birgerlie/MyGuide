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
        // it used to buzz "110 m behind you"). Quiet noneDue lists it.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 10), late = Self.place("late", .good, north: 55)
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
        let same = Self.place("same", .top, north: 60, wikidata: nil)
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
    static func place(_ id: String, _ tier: PlaceTier, north: Double, east: Double = 0, sitelinks: Int? = nil,
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
    @Test func famousTopBuzzesFromOneHundredMetres() {
        // The Colosseum (148 sitelinks) at 99 m buzzes; at 101 m it is not due (fresh engines each time).
        var e = Self.engine(), f = Self.engine()
        let near = Self.place("colosseum", .top, north: 99, sitelinks: 148)
        let far = Self.place("colosseum", .top, north: 101, sitelinks: 148)
        #expect(e.evaluate(places: [near], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == near)
        #expect(f.decide(places: [far], position: .at(), accuracy: 5, course: 0, now: Self.t0) == .quiet(.noneDue, due: []))
    }
    @Test func otherTopBuzzesFromEightyMetresAndGoodFromSixty() {
        var e = Self.engine(), f = Self.engine(), g = Self.engine(), h = Self.engine()
        let top79 = Self.place("t", .top, north: 79, sitelinks: 32), top81 = Self.place("t", .top, north: 81, sitelinks: 32)
        let good59 = Self.place("g", .good, north: 59, sitelinks: 90), good61 = Self.place("g", .good, north: 61, sitelinks: 90)
        #expect(e.evaluate(places: [top79], position: .at(), accuracy: 5, course: 0, now: Self.t0)?.place == top79)
        #expect(f.evaluate(places: [top81], position: .at(), accuracy: 5, course: 0, now: Self.t0) == nil)
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
        // 120 → A is held. t0+20 at 65 N: B 85 m, still held. t0+30 at 75 N: B 75 m ≤ 80 → B (top) buzzes.
        var e = Self.engine()
        let places = [Self.holdA, Self.holdB]
        #expect(e.decide(places: places, position: .at(north: 30), accuracy: 5, course: 0, now: Self.t0)
                == .quiet(.noneDue, due: []))
        let held = e.decide(places: places, position: .at(north: 45), accuracy: 5, course: 0, now: Self.t0 + 10)
        guard case .quiet(.held, let due) = held else { Issue.record("expected held, got \(held)"); return }
        #expect(due.map(\.id) == ["A"])
        #expect(e.decide(places: places, position: .at(north: 65), accuracy: 5, course: 0, now: Self.t0 + 20).buzz == nil)
        #expect(e.evaluate(places: places, position: .at(north: 75), accuracy: 5, course: 0, now: Self.t0 + 30)?.place
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

    @Test func lowerRankedPlacesWithinFortyMetresOfABuzzAreExcluded() {
        // Il Gesù (top, 40 sitelinks) at 30 m buzzes. Then, with the budget full again (t0+3600, 3 tokens):
        // Palazzo Altieri (good) 39 m beyond (69 N) is lower-ranked and within 40 m → excluded;
        // a top with 40 sitelinks 39 m beyond on the other side (east 39 from Il Gesù) ranks equal → free;
        // a good 41 m beyond (71 N) → free.
        var e = Self.engine()
        let gesu = Self.place("gesu", .top, north: 30, sitelinks: 40)
        let altieri = Self.place("altieri", .good, north: 69, sitelinks: 3)
        let equal = Self.place("equal", .top, north: 30, east: 39, sitelinks: 40)
        let farther = Self.place("farther", .good, north: 71, sitelinks: 3)
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
        #expect(BuzzEngine.complexRadius == 40)
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
        let good = Self.place("good", .good, north: 65), famous = Self.place("famous", .top, north: 65, sitelinks: 60)
        let d = e.decide(places: [good], position: .at(north: 40), accuracy: 5, course: 0, now: Self.t0)
        guard case .quiet(.allExcluded, _) = d else { Issue.record("expected allExcluded, got \(d)"); return }
        #expect(e.evaluate(places: [good, famous], position: .at(north: 40), accuracy: 5, course: 0, now: Self.t0)?.place
                == famous)
    }

    // MARK: Cadence (20.7)

    @Test func thirtySecondsBetweenTwoBuzzesWhateverTheBudget() {
        // 60/h: one token per 60 s, at most 3. At t0+120 there are 3 tokens: a buzzes; b (100 m away, 50 m from the
        // walker) has budget left but must wait: quiet minGap at +29 s, buzz at +30 s.
        var e = Self.engine(perHour: 60)
        let a = Self.place("a", .good, north: 10), b = Self.place("b", .good, north: -50)
        #expect(e.evaluate(places: [a], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 120)?.place == a)
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 149)
        guard case .quiet(.minGap, let due) = d else { Issue.record("expected minGap, got \(d)"); return }
        #expect(Set(due.map(\.id)) == ["a", "b"])
        #expect(e.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 150)?.place == b)
        #expect(BuzzEngine.minimumGap == 30)
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
