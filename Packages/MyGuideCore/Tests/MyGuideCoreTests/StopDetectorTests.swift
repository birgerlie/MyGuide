import Foundation
import Testing
@testable import MyGuideCore

@Suite struct StopDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firesAfterSixtySecondsWithJitter() throws {
        // Review Focus 3: fixes jitter up to ±10 m around the anchor; fires at t0+60, not t0+59.
        // Hand (running mean of all 8 fixes absorbed by t0+60; every fix is within 25 m of the running mean):
        // north 0+8-6+10-9+4+3-2 = 8, east 0-3+9+0-5+7+0+0 = 8, mean (8/8, 8/8) = (1, 1), 1.41 m from the origin.
        var d = StopDetector(previousStops: [])
        let jitter: [(Double, Double)] = [(0, 0), (8, -3), (-6, 9), (10, 0), (-9, -5), (4, 7)]
        for (i, (n, e)) in jitter.enumerated() {
            #expect(d.update(position: .at(north: n, east: e), accuracy: 8, speed: 0.2, now: Self.t0 + Double(i) * 10) == nil)
        }   // last fix at t0+50
        #expect(d.update(position: .at(north: 3), accuracy: 8, speed: 0.1, now: Self.t0 + 59) == nil)
        let spot = d.update(position: .at(north: -2), accuracy: 8, speed: 0.1, now: Self.t0 + 60)
        let stop = try #require(spot)
        #expect(GeoMath.distance(stop, .at()) < 5)
        #expect(d.update(position: .at(), accuracy: 8, speed: 0, now: Self.t0 + 120) == nil)   // once per anchor
    }

    @Test func walkingNeverFires() {
        // 1.4 m/s for 5 minutes. Hand: 1.4 > 0.5 re-anchors every fix, so elapsed is always 0 < 60 → never fires.
        var d = StopDetector(previousStops: [])
        for s in stride(from: 0.0, through: 300, by: 5) {
            #expect(d.update(position: .at(north: s * 1.4), accuracy: 5, speed: 1.4, now: Self.t0 + s) == nil)
        }
    }

    @Test func movingAwayResets() {
        // moves 30 m at t0+40 → new anchor; fires at t0+100
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 40)
        #expect(d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 99) == nil)
        #expect(d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 100) == .at(north: 30))
    }

    @Test func notAgainWithinOneHundredMetres() {
        // Hand: stop at 0 m. Anchor at 80 m: 80 < 100 → suppressed. Anchor at 120 m: 120 > 100 → fires.
        var near = StopDetector(previousStops: [.at()])
        _ = near.update(position: .at(north: 80), accuracy: 5, speed: 0, now: Self.t0)
        #expect(near.update(position: .at(north: 80), accuracy: 5, speed: 0, now: Self.t0 + 60) == nil)
        var far = StopDetector(previousStops: [.at()])
        _ = far.update(position: .at(north: 120), accuracy: 5, speed: 0, now: Self.t0)
        #expect(far.update(position: .at(north: 120), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at(north: 120))
    }

    @Test func unknownSpeedAndBadFixes() {
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: -1, now: Self.t0)
        #expect(d.update(position: .at(north: 200), accuracy: 60, speed: -1, now: Self.t0 + 30) == nil)  // ignored
        #expect(d.update(position: .at(), accuracy: 5, speed: -1, now: Self.t0 + 60) == .at())
    }

    // MARK: Boundaries and invalid fixes

    @Test func accuracyExactlyFiftyIsUsable() {
        // Hand: anchor at t0 (accuracy 50 accepted); t0+60 − t0 = 60 ≥ 60 → fires at the anchor.
        // If 50 were rejected, no anchor would exist until t0+60 and nothing would fire.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 50, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(), accuracy: 50, speed: 0, now: Self.t0 + 60) == .at())
    }

    @Test func nonFiniteOrNegativeAccuracyIsIgnored() {
        // Hand: NaN fix at t0 ignored; valid fix at t0+10 anchors. t0+69 − (t0+10) = 59 < 60 → nil;
        // t0+70 − (t0+10) = 60 ≥ 60 → fires. A negative-accuracy fix at t0+75 is ignored (no re-anchor).
        var d = StopDetector(previousStops: [])
        #expect(d.update(position: .at(), accuracy: .nan, speed: 0, now: Self.t0) == nil)
        #expect(d.update(position: .at(north: 500), accuracy: 5, speed: 0, now: Self.t0 + 10) == nil)
        #expect(d.update(position: .at(north: 500), accuracy: 5, speed: 0, now: Self.t0 + 69) == nil)
        #expect(d.update(position: .at(north: 500), accuracy: 5, speed: 0, now: Self.t0 + 70) == .at(north: 500))
        #expect(d.update(position: .at(), accuracy: -1, speed: 0, now: Self.t0 + 75) == nil)
    }

    @Test func accuracyJustAboveFiftyIsIgnored() {
        // Hand: fix at t0+30 with accuracy 50.01 at 200 m would re-anchor if it were used; it is ignored,
        // so the anchor stays at t0 and t0+60 − t0 = 60 fires at the origin.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(north: 200), accuracy: 50.01, speed: 0, now: Self.t0 + 30) == nil)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at())
    }

    @Test func within25MetresKeepsAnchor() throws {
        // Hand: 24 m ≤ 25 m → absorbed, no re-anchor. Mean after t0+30: (0+24)/2 = 12 m.
        // At t0+60 the fix at 0 m is 12 m from the mean (≤ 25), absorbed: 12 + (0−12)/3 = 8 m. Fires at 8 m north.
        // (The fix that completes the 60 s is part of the spot.)
        // A 26 m fix would re-anchor (see below), which is the other side of the boundary.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(north: 24), accuracy: 5, speed: 0, now: Self.t0 + 30)
        let result = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60)
        let spot = try #require(result)
        #expect(GeoMath.distance(spot, .at(north: 8)) < 0.01)
    }

    @Test func beyond25MetresReanchors() {
        // Hand: 26 m > 25 m → re-anchor at t0+30 (anchorAt = t0+30). t0+60 − (t0+30) = 30 < 60 → nil;
        // t0+90 − (t0+30) = 60 ≥ 60 → fires at 26 m.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(north: 26), accuracy: 5, speed: 0, now: Self.t0 + 30)
        #expect(d.update(position: .at(north: 26), accuracy: 5, speed: 0, now: Self.t0 + 60) == nil)
        #expect(d.update(position: .at(north: 26), accuracy: 5, speed: 0, now: Self.t0 + 90) == .at(north: 26))
    }

    @Test func speedExactlyHalfMetreSecondDoesNotReanchor() {
        // Hand: speed 0.5 is not > 0.5, so no re-anchor; anchor at t0, t0+60 − t0 = 60 → fires at the origin.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(), accuracy: 5, speed: 0.5, now: Self.t0 + 30)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at())
    }

    @Test func speedJustAboveHalfReanchors() {
        // Hand: speed 0.51 > 0.5 → re-anchor at t0+30 at the same spot. t0+60 − (t0+30) = 30 < 60 → nil;
        // t0+90 − (t0+30) = 60 → fires at the origin, not at t0+60.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(), accuracy: 5, speed: 0.51, now: Self.t0 + 30)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == nil)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 90) == .at())
    }

    @Test func anyPreviousStopWithinOneHundredMetresSuppresses() {
        // Hand: anchor at 0 m. Stops at 500 m (outside 100 m) and 90 m (inside 100 m) → 90 < 100 suppresses → nil.
        var d = StopDetector(previousStops: [.at(north: 500), .at(north: 90)])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == nil)
    }

    @Test func firedStopIsRememberedWithinTheSameTrip() {
        // Hand: fires at the origin at t0+60 and is recorded. Move to 200 m at t0+70 (held back), 200 m again at
        // t0+130 confirms the move: anchor t0+70, t0+130 − t0+70 = 60 → fires at 200 m: 200 m from the recorded
        // origin > 100 m, so not suppressed. Then 50 m at t0+140 (held back), 50 m at t0+200 confirms: anchor t0+140,
        // 60 s, but 50 m from the recorded origin ≤ 100 m → suppressed.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at())
        _ = d.update(position: .at(north: 200), accuracy: 5, speed: 0, now: Self.t0 + 70)
        #expect(d.update(position: .at(north: 200), accuracy: 5, speed: 0, now: Self.t0 + 130) == .at(north: 200))
        _ = d.update(position: .at(north: 50), accuracy: 5, speed: 0, now: Self.t0 + 140)
        #expect(d.update(position: .at(north: 50), accuracy: 5, speed: 0, now: Self.t0 + 200) == nil)
    }

    // MARK: Jitter and persistence

    @Test func standingStillWithTwentyMetreJitterFires() throws {
        // Fixes every 10 s, north +20, −20, 0, 0, +20, −20, 0 m (east 0). Mean after each absorbed fix:
        // t0: 20 (anchor). t10: −20 is 40 m away → held. t20: 0 is 20 m from 20 → absorbs −20 and 0:
        //   20 + (−20−20)/2 = 0, then 0. t30: 0. t40: +20 is 20 m away → 0 + 20/5 = 4.
        // t50: −20 is 24 m from 4 → 4 + (−20−4)/6 = 0. t60: 0 → 0. Elapsed 60 s since t0 → fires at ≈ origin.
        var d = StopDetector(previousStops: [])
        let north: [Double] = [20, -20, 0, 0, 20, -20, 0]
        var spot: Coordinate?
        for (i, n) in north.enumerated() {
            let result = d.update(position: .at(north: n), accuracy: 5, speed: 0, now: Self.t0 + Double(i) * 10)
            if i < north.count - 1 { #expect(result == nil) } else { spot = result }
        }
        #expect(GeoMath.distance(try #require(spot), .at()) < 1)
    }

    @Test func singleOutlierIsAbsorbed() throws {
        // Fixes: 0 at t0 (anchor), 0 at t20, 30 at t30 (held back), 0 at t40, 0 at t50, 0 at t60.
        // Hand: after t20 mean 0 (n=2). t40 absorbs the held 30 then 0: 0 + 30/3 = 10, then 10 + (0−10)/4 = 7.5.
        // t50: 7.5 + (0−7.5)/5 = 6. t60: 6 + (0−6)/6 = 5. The mean of 0,0,30,0,0,0 is 5 m.
        // No reset at t40 (the outlier is absorbed, not a move), so the 60 s run from t0 fires at t0+60, not later.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 20) == nil)
        #expect(d.update(position: .at(north: 30), accuracy: 5, speed: 0, now: Self.t0 + 30) == nil)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 40) == nil)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 50) == nil)
        let result = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60)
        let spot = try #require(result)
        #expect(GeoMath.distance(spot, .at(north: 5)) < 0.01)
    }
}
