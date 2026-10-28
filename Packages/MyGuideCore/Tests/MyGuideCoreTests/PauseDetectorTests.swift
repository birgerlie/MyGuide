import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PauseDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func make(motion: Bool = true) -> PauseDetector { PauseDetector(now: t0, motionAvailable: motion) }

    /// A detector paused at t0+180 (motion available) after an optional anchor fix at t0+10.
    static func paused(anchorFix: Bool) -> PauseDetector {
        var d = make()
        if anchorFix { _ = d.fix(position: .at(), accuracy: 5, at: t0 + 10) }
        _ = d.tick(now: t0 + 180)
        return d
    }

    @Test func pausesAfter180sStill() {
        // Hand: stretch starts at t0; 179 − 0 = 179 < 180 → nil; 180 − 0 = 180 ≥ 180 → pause.
        var d = Self.make()
        #expect(d.tick(now: Self.t0 + 179) == nil)
        #expect(!d.isPaused)
        #expect(d.tick(now: Self.t0 + 180) == .pause(.motion, anchor: nil))
        #expect(d.isPaused)
        #expect(d.pausedSince == Self.t0 + 180)
    }

    @Test func steadyWalkingAfterOneReportNeverPauses() {
        // Review Focus 1. Hand: walkingSince = t0+1 stays set (no further report), so walkingSince != nil for every tick
        // up to t0+3600 (3 585 s after the report, far beyond 180) and the pause rule never applies.
        var d = Self.make()
        #expect(d.motion(isWalking: true, at: Self.t0 + 1) == nil)
        var t = 15.0
        while t <= 3600 {
            #expect(d.tick(now: Self.t0 + t) == nil)
            t += 15
        }
        #expect(!d.isPaused)
    }

    @Test func walkingThenStoppingRestartsStretch() {
        // Hand: stop reported at t0+100 sets stillStart = 100; 279 − 100 = 179 < 180; 280 − 100 = 180 → pause.
        var d = Self.make()
        #expect(d.motion(isWalking: true, at: Self.t0 + 10) == nil)
        #expect(d.motion(isWalking: false, at: Self.t0 + 100) == nil)
        #expect(d.tick(now: Self.t0 + 279) == nil)
        #expect(d.tick(now: Self.t0 + 280) == .pause(.motion, anchor: nil))
    }

    @Test func gpsOnlyTriggerIsGps() {
        // Hand: 180 − 0 = 180 ≥ 180 → pause, trigger gps because motion is unavailable.
        var d = Self.make(motion: false)
        #expect(d.tick(now: Self.t0 + 180) == .pause(.gps, anchor: nil))
    }

    @Test func fixWithin30mKeepsStretch() {
        // Hand: anchor = origin at t0+10; north 29 ≤ max(30, 5) = 30 → no move, stillStart stays t0; 180 − 0 = 180 → pause.
        var d = Self.make()
        #expect(d.fix(position: .at(), accuracy: 5, at: Self.t0 + 10) == nil)
        #expect(d.fix(position: .at(north: 29), accuracy: 5, at: Self.t0 + 100) == nil)
        #expect(d.tick(now: Self.t0 + 179) == nil)
        #expect(d.tick(now: Self.t0 + 180) == .pause(.motion, anchor: .at()))
    }

    @Test func fixBeyond30mMovesAnchorAndRestarts() {
        // Hand: 31 > max(30, 5) = 30 → anchor = north 31, stillStart = 100; 279 − 100 = 179 < 180; 280 − 100 = 180 → pause.
        var d = Self.make()
        #expect(d.fix(position: .at(), accuracy: 5, at: Self.t0 + 10) == nil)
        #expect(d.fix(position: .at(north: 31), accuracy: 5, at: Self.t0 + 100) == nil)
        #expect(d.tick(now: Self.t0 + 279) == nil)
        #expect(d.tick(now: Self.t0 + 280) == .pause(.motion, anchor: .at(north: 31)))
    }

    @Test func poorAccuracyWidensRadius() {
        // Hand: 40 ≤ max(30, 45) = 45 → no move, stretch still starts at t0, pause at 180 − 0 = 180 with the first anchor.
        var d = Self.make()
        #expect(d.fix(position: .at(), accuracy: 5, at: Self.t0 + 10) == nil)
        #expect(d.fix(position: .at(north: 40), accuracy: 45, at: Self.t0 + 20) == nil)
        // Accuracy 60 > 50 is unusable: ignored although 1 000 > max(30, 60) would otherwise move the anchor.
        #expect(d.fix(position: .at(north: 1000), accuracy: 60, at: Self.t0 + 30) == nil)
        #expect(d.tick(now: Self.t0 + 180) == .pause(.motion, anchor: .at()))
    }

    @Test func negativeAccuracyFixIsIgnored() {
        // Hand: accuracy −1 < 0 is invalid → ignored, so no anchor is set and the pause carries nil at 180 − 0 = 180.
        var d = Self.make()
        #expect(d.fix(position: .at(), accuracy: -1, at: Self.t0 + 10) == nil)
        #expect(d.tick(now: Self.t0 + 180) == .pause(.motion, anchor: nil))
    }

    @Test func resumesAfterMoreThan60sWalking() {
        // Hand: walkingSince = 200; 260 − 200 = 60 is not > 60; 261 − 200 = 61 > 60 → resume.
        var d = Self.paused(anchorFix: false)
        #expect(d.motion(isWalking: true, at: Self.t0 + 200) == nil)
        #expect(d.tick(now: Self.t0 + 260) == nil)
        #expect(d.tick(now: Self.t0 + 261) == .resume(.motion))
        #expect(!d.isPaused)
        #expect(d.pausedSince == nil)
    }

    @Test func walkingInterruptedDoesNotResume() {
        // Hand: walking restarts at 240; 300 − 240 = 60 is not > 60; 301 − 240 = 61 > 60 → resume.
        var d = Self.paused(anchorFix: false)
        #expect(d.motion(isWalking: true, at: Self.t0 + 200) == nil)
        #expect(d.motion(isWalking: false, at: Self.t0 + 230) == nil)
        #expect(d.motion(isWalking: true, at: Self.t0 + 240) == nil)
        #expect(d.tick(now: Self.t0 + 300) == nil)
        #expect(d.tick(now: Self.t0 + 301) == .resume(.motion))
    }

    @Test func motionReportCanResumeWhenWalkingSinceIsOld() {
        // Hand: walking reported at 200 while paused; a repeated walking report at 261 keeps walkingSince = 200,
        // and 261 − 200 = 61 > 60 → the motion call itself returns the resume.
        var d = Self.paused(anchorFix: false)
        #expect(d.motion(isWalking: true, at: Self.t0 + 200) == nil)
        #expect(d.motion(isWalking: true, at: Self.t0 + 261) == .resume(.motion))
    }

    @Test func gpsResumeNeedsDistanceMinusAccuracyOver100() {
        // Haversine at exactly 110 m returns 110.00000000000001, so the exact boundary is not testable in floating point;
        // the test brackets it by 0.1 m instead.
        // Hand: 109.9 − 10 = 99.9 ≤ 100 → nil; 110.1 − 10 = 100.1 > 100 → resume.
        var d = Self.paused(anchorFix: true)
        #expect(d.fix(position: .at(north: 109.9), accuracy: 10, at: Self.t0 + 200) == nil)
        #expect(d.isPaused)
        #expect(d.fix(position: .at(north: 110.1), accuracy: 10, at: Self.t0 + 210) == .resume(.gps))
        #expect(!d.isPaused)
    }

    @Test func inaccurateFarFixDoesNotResume() {
        // Review Focus 4. Hand: 120 − 65 = 55 ≤ 100 → nil. Accuracy 101 > 100 is ignored (would be 500 − 101 = 399 > 100).
        var d = Self.paused(anchorFix: true)
        #expect(d.fix(position: .at(north: 120), accuracy: 65, at: Self.t0 + 200) == nil)
        #expect(d.fix(position: .at(north: 500), accuracy: 101, at: Self.t0 + 210) == nil)
        #expect(d.isPaused)
    }

    @Test func pausedWithoutAnchorTakesFirstFix() {
        // Hand: first fix (500, acc 50) becomes the pause anchor → nil. Second: 651 − 500 = 151; 151 − 50 = 101 > 100 → resume.
        var d = Self.paused(anchorFix: false)
        #expect(d.fix(position: .at(north: 500), accuracy: 50, at: Self.t0 + 200) == nil)
        #expect(d.fix(position: .at(north: 651), accuracy: 50, at: Self.t0 + 210) == .resume(.gps))
    }

    @Test func afterResumeStretchRestarts() {
        // Hand: walking stops at 262 → stillStart = 262; 441 − 262 = 179 < 180; 442 − 262 = 180 → pause.
        var d = Self.paused(anchorFix: false)
        #expect(d.motion(isWalking: true, at: Self.t0 + 200) == nil)
        #expect(d.tick(now: Self.t0 + 261) == .resume(.motion))
        #expect(d.motion(isWalking: false, at: Self.t0 + 262) == nil)
        #expect(d.tick(now: Self.t0 + 441) == nil)
        #expect(d.tick(now: Self.t0 + 442) == .pause(.motion, anchor: nil))
        #expect(d.pausedSince == Self.t0 + 442)
    }

    @Test func gpsResumeRestartsStretchAtResumeTime() {
        // Hand: GPS resume at t0+300 sets stillStart = 300 and clears the anchor; 479 − 300 = 179 < 180; 480 − 300 = 180 → pause,
        // with anchor nil because the first usable fix after resume has not arrived.
        var d = Self.paused(anchorFix: true)
        #expect(d.fix(position: .at(north: 200), accuracy: 5, at: Self.t0 + 300) == .resume(.gps))
        #expect(d.tick(now: Self.t0 + 479) == nil)
        #expect(d.tick(now: Self.t0 + 480) == .pause(.motion, anchor: nil))
    }

    @Test func isWalkingConfidence() {
        let at = Self.t0
        #expect(!MotionReading(activity: .walking, confidence: .low, at: at).isWalking)
        #expect(MotionReading(activity: .walking, confidence: .medium, at: at).isWalking)
        #expect(MotionReading(activity: .running, confidence: .high, at: at).isWalking)
        #expect(!MotionReading(activity: .automotive, confidence: .high, at: at).isWalking)
        #expect(!MotionReading(activity: .stationary, confidence: .high, at: at).isWalking)
    }
}
