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
        // 20/h: second buzz no sooner than 180 s after the first
        var e = Self.engine()
        let a = Self.place("a", .good, north: 40), b = Self.place("b", .good, north: 50)
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
        // 20/h. t0: "a" (top, 5 m) buzzes and spends the budget. t0+10: castle due, closest 30 m.
        // t0+60 at 125 m north: castle 95 m away (≥ 90, > 30 + 10), budget 60/180 = 0.33 → override.
        // t0+180: budget 180/180 = 1.0 (the override spent nothing) → "g" (good, 50 m) buzzes normally.
        var e = Self.engine()
        let a = Self.place("a", .top, north: 5), castle = Self.place("castle", .top, north: 30)
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
        // t0: "a" (top, 5 m) buzzes. t0+10: p1 due (closest 30). t0+60 at 125 N: p1 95 m, passing → override #1.
        // t0+500 at 1000 N: p2 due (closest 30). t0+600 at 1125 N: p2 95 m, passing, but 540 s since override #1 → nil.
        // t0+660: 600 s since override #1 → override #2 (budget 660/720 = 0.92, so it is an override).
        var e = Self.engine(perHour: 5)
        let a = Self.place("a", .top, north: 5)
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
        let a = Self.place("a", .good, north: 40), b = Self.place("b", .good, north: 50)
        #expect(e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0).buzz?.place == a)
        // 20/h → 3600 / 20 = 180 s spacing; 179 s < 180 s, so the budget is spent. b is good tier: no override.
        let d = e.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + 179)
        guard case .quiet(.budget, let due) = d else { Issue.record("expected budget, got \(d)"); return }
        // Tier then distance: both good, a at 40 m before b at 50 m.
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
        let a = Self.place("a", .good, north: 40), b = Self.place("b", .top, north: 50)
        // t0: both buzz b (top); t0+179: budget spent for both; t0+180: a.
        for dt in [0.0, 179, 180] {
            let x = viaEvaluate.evaluate(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + dt)
            let y = viaDecide.decide(places: [a, b], position: .at(), accuracy: 5, course: 0, now: Self.t0 + dt).buzz
            #expect(x?.place == y?.place && x?.detail == y?.detail && x?.usedOverride == y?.usedOverride)
        }
    }
}
