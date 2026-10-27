import Foundation
import Testing
@testable import MyGuideCore

@Suite struct StopDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firesAfterSixtySecondsWithJitter() {
        // Review Focus 3: fixes jitter up to ±10 m around the anchor; fires at t0+60, not t0+59
        var d = StopDetector(previousStops: [])
        let jitter: [(Double, Double)] = [(0, 0), (8, -3), (-6, 9), (10, 0), (-9, -5), (4, 7)]
        for (i, (n, e)) in jitter.enumerated() {
            #expect(d.update(position: .at(north: n, east: e), accuracy: 8, speed: 0.2, now: Self.t0 + Double(i) * 10) == nil)
        }   // last fix at t0+50
        #expect(d.update(position: .at(north: 3), accuracy: 8, speed: 0.1, now: Self.t0 + 59) == nil)
        #expect(d.update(position: .at(north: -2), accuracy: 8, speed: 0.1, now: Self.t0 + 60) == .at())
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

    @Test func within25MetresKeepsAnchor() {
        // Hand: 24 m < 25 m → no re-anchor, so the anchor stays at t0 and t0+60 fires at the origin.
        // A 26 m fix would re-anchor (see below), which is the other side of the boundary.
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        _ = d.update(position: .at(north: 24), accuracy: 5, speed: 0, now: Self.t0 + 30)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at())
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

    @Test func firedStopIsRememberedForLaterTrips() {
        // Hand: fires at the origin at t0+60 and is recorded. Moving to 200 m (reanchor at t0+70);
        // t0+130 − t0+70 = 60 → fires at 200 m: 200 m from the recorded origin > 100 m, so not suppressed.
        // A stop at 50 m from the origin afterwards would be suppressed (50 < 100).
        var d = StopDetector(previousStops: [])
        _ = d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0)
        #expect(d.update(position: .at(), accuracy: 5, speed: 0, now: Self.t0 + 60) == .at())
        _ = d.update(position: .at(north: 200), accuracy: 5, speed: 0, now: Self.t0 + 70)
        #expect(d.update(position: .at(north: 200), accuracy: 5, speed: 0, now: Self.t0 + 130) == .at(north: 200))
        _ = d.update(position: .at(north: 50), accuracy: 5, speed: 0, now: Self.t0 + 140)
        #expect(d.update(position: .at(north: 50), accuracy: 5, speed: 0, now: Self.t0 + 200) == nil)
    }
}
