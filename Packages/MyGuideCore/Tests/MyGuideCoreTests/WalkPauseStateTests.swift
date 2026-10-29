import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkPauseStateTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let anchor = Coordinate.at(north: 10)

    /// The effects of entering a pause: the `paused` line between suspending the track and showing the status.
    static func entering(_ reason: WalkPauseReason, at anchor: Coordinate?, source: WalkSource?) -> [WalkPauseEffect] {
        [.suspendTracking, .log(.paused(reason, at: anchor, source: source)), .refreshActivity(clearStop: true)]
    }

    /// The effects of leaving a pause: the route reset before the `resumed` line, then the status.
    static func leaving(_ reason: WalkPauseReason, seconds: Double, source: WalkSource?) -> [WalkPauseEffect] {
        [.resetRoute, .log(.resumed(reason, pausedSeconds: seconds, source: source)), .refreshActivity(clearStop: true)]
    }

    // MARK: - Fresh state

    @Test func freshStateIsActive() {
        let state = WalkPauseState()
        #expect(state.kind == nil)
        #expect(!state.isPaused)
        #expect(state.pausedSince == nil)
        #expect(state.pausedTotal == 0)
    }

    @Test func noDetectorChangeDoesNothing() {
        var state = WalkPauseState()
        #expect(state.apply(nil, now: Self.t0).isEmpty)
        #expect(state == WalkPauseState())
    }

    // MARK: - Auto pause

    @Test func detectorPauseEntersAutoPause() {
        var state = WalkPauseState()
        let effects = state.apply(.pause(.gps, anchor: Self.anchor), now: Self.t0 + 180)
        #expect(effects == Self.entering(.gps, at: Self.anchor, source: nil))
        #expect(state.kind == .auto)
        #expect(state.isPaused)
        #expect(state.pausedSince == Self.t0 + 180)
        #expect(state.pausedTotal == 0)
    }

    @Test func detectorPauseWithoutAnchorLogsNoPosition() {
        var state = WalkPauseState()
        #expect(state.apply(.pause(.motion, anchor: nil), now: Self.t0) == Self.entering(.motion, at: nil, source: nil))
    }

    @Test func detectorPauseWhileAutoPausedDoesNothing() {
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0)
        let before = state
        #expect(state.apply(.pause(.gps, anchor: Self.anchor), now: Self.t0 + 60).isEmpty)
        #expect(state == before)
        #expect(state.pausedSince == Self.t0)
    }

    @Test func detectorResumeEndsAutoPause() {
        // Hand: paused at t0+180, resumed at t0+500 → 500 − 180 = 320 s.
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0 + 180)
        let effects = state.apply(.resume(.gps), now: Self.t0 + 500)
        // The detector's resume trigger, not the pause's, and no source: it was automatic.
        #expect(effects == Self.leaving(.gps, seconds: 320, source: nil))
        #expect(state.kind == nil)
        #expect(state.pausedSince == nil)
        #expect(state.pausedTotal == 320)
    }

    // MARK: - Manual pause

    @Test(arguments: [WalkSource.phone, .watch])
    func manualPauseFromWalking(source: WalkSource) {
        var state = WalkPauseState()
        let effects = state.pause(source: source, anchor: Self.anchor, now: Self.t0 + 40)
        #expect(effects == Self.entering(.manual, at: Self.anchor, source: source) + [.holdDetector])
        #expect(state.kind == .manual)
        #expect(state.pausedSince == Self.t0 + 40)
    }

    @Test func manualPauseWithoutAnchorLogsNoPosition() {
        var state = WalkPauseState()
        #expect(state.pause(source: .phone, anchor: nil, now: Self.t0)
                == Self.entering(.manual, at: nil, source: .phone) + [.holdDetector])
    }

    @Test func manualPauseWhileManualDoesNothing() {
        var state = WalkPauseState()
        _ = state.pause(source: .phone, anchor: nil, now: Self.t0)
        let before = state
        #expect(state.pause(source: .watch, anchor: Self.anchor, now: Self.t0 + 30).isEmpty)
        #expect(state == before)
    }

    @Test func detectorChangesIgnoredDuringManualPause() {
        var state = WalkPauseState()
        _ = state.pause(source: .phone, anchor: nil, now: Self.t0)
        let before = state
        #expect(state.apply(.resume(.motion), now: Self.t0 + 100).isEmpty)
        #expect(state.apply(.pause(.gps, anchor: Self.anchor), now: Self.t0 + 200).isEmpty)
        #expect(state == before)
    }

    @Test(arguments: [WalkSource.phone, .watch])
    func autoPauseTurningManualKeepsPausedSince(source: WalkSource) {
        var state = WalkPauseState()
        _ = state.apply(.pause(.gps, anchor: nil), now: Self.t0 + 180)
        let effects = state.pause(source: source, anchor: Self.anchor, now: Self.t0 + 300)
        // One `paused` line with reason manual; the track is already suspended and a stop story is not cleared again.
        #expect(effects == [.holdDetector, .log(.paused(.manual, at: Self.anchor, source: source)),
                            .refreshActivity(clearStop: false)])
        #expect(state.kind == .manual)
        #expect(state.pausedSince == Self.t0 + 180)
        // Hand: the pause counts from the auto start, t0+180, to t0+400 → 220 s; the reason is manual.
        #expect(state.resume(source: .phone, now: Self.t0 + 400)
                == Self.leaving(.manual, seconds: 220, source: .phone) + [.releaseDetector])
        #expect(state.pausedTotal == 220)
    }

    @Test func detectorResumeIgnoredAfterAutoTurnedManual() {
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0)
        _ = state.pause(source: .watch, anchor: nil, now: Self.t0 + 10)
        #expect(state.apply(.resume(.motion), now: Self.t0 + 20).isEmpty)
        #expect(state.kind == .manual)
    }

    // MARK: - Resume by command

    @Test(arguments: [(PauseTrigger.motion, WalkSource.phone), (.motion, .watch), (.gps, .phone), (.gps, .watch)])
    func resumeByCommandAfterAutoPauseNamesItsTrigger(trigger: PauseTrigger, source: WalkSource) {
        // Hand: paused at t0, resumed at t0+90 → 90 s.
        var state = WalkPauseState()
        _ = state.apply(.pause(trigger, anchor: nil), now: Self.t0)
        let effects = state.resume(source: source, now: Self.t0 + 90)
        #expect(effects == Self.leaving(WalkPauseReason(trigger), seconds: 90, source: source) + [.releaseDetector])
        #expect(state.kind == nil)
        #expect(state.pausedTotal == 90)
    }

    @Test(arguments: [WalkSource.phone, .watch])
    func resumeByCommandAfterManualPauseIsManual(source: WalkSource) {
        // Hand: paused at t0+5, resumed at t0+65 → 60 s.
        var state = WalkPauseState()
        _ = state.pause(source: .phone, anchor: nil, now: Self.t0 + 5)
        #expect(state.resume(source: source, now: Self.t0 + 65)
                == Self.leaving(.manual, seconds: 60, source: source) + [.releaseDetector])
    }

    @Test func triggerOfAnEarlierAutoPauseIsForgotten() {
        // auto (gps) → manual → resume, then auto (motion) → resume by command: the reason is the new trigger.
        var state = WalkPauseState()
        _ = state.apply(.pause(.gps, anchor: nil), now: Self.t0)
        _ = state.pause(source: .phone, anchor: nil, now: Self.t0 + 10)
        _ = state.resume(source: .phone, now: Self.t0 + 20)
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0 + 300)
        // Hand: 330 − 300 = 30 s.
        #expect(state.resume(source: .watch, now: Self.t0 + 330)
                == Self.leaving(.motion, seconds: 30, source: .watch) + [.releaseDetector])
    }

    // MARK: - Leaving a pause that never started

    @Test func resumeWhileActiveDoesNothing() {
        var state = WalkPauseState()
        #expect(state.resume(source: .phone, now: Self.t0).isEmpty)
        #expect(state.resume(source: .watch, now: Self.t0).isEmpty)
        #expect(state.apply(.resume(.motion), now: Self.t0).isEmpty)
        #expect(state.apply(.resume(.gps), now: Self.t0).isEmpty)
        #expect(state == WalkPauseState())
    }

    @Test func resumeAfterAFinishedPauseDoesNothing() {
        // Hand: one pause of 100 − 0 = 100 s; the second resume adds nothing.
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0)
        _ = state.apply(.resume(.motion), now: Self.t0 + 100)
        let before = state
        #expect(state.resume(source: .phone, now: Self.t0 + 200).isEmpty)
        #expect(state == before)
        #expect(state.pausedTotal == 100)
    }

    // MARK: - Totals

    @Test func pausedTotalSumsTwoPauses() {
        // Hand: auto pause t0+180 → t0+480 = 300 s; manual pause t0+1 000 → t0+1 045 = 45 s; 300 + 45 = 345 s.
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0 + 180)
        #expect(state.apply(.resume(.motion), now: Self.t0 + 480) == Self.leaving(.motion, seconds: 300, source: nil))
        #expect(state.pausedTotal == 300)
        _ = state.pause(source: .watch, anchor: nil, now: Self.t0 + 1_000)
        // The pause in progress is not in the total.
        #expect(state.pausedTotal == 300)
        #expect(state.resume(source: .watch, now: Self.t0 + 1_045)
                == Self.leaving(.manual, seconds: 45, source: .watch) + [.releaseDetector])
        #expect(state.pausedTotal == 345)
    }

    @Test func pauseLengthNeverBelowZero() {
        // Hand: clock set back: paused at t0+100, resumed at t0+90 → 90 − 100 = −10 → clamped to 0; total stays 0.
        var state = WalkPauseState()
        _ = state.pause(source: .phone, anchor: nil, now: Self.t0 + 100)
        #expect(state.resume(source: .phone, now: Self.t0 + 90)
                == Self.leaving(.manual, seconds: 0, source: .phone) + [.releaseDetector])
        #expect(state.pausedTotal == 0)
    }

    @Test func zeroLengthPauseCountsZero() {
        // Hand: paused and resumed at t0+50 → 0 s.
        var state = WalkPauseState()
        _ = state.apply(.pause(.gps, anchor: nil), now: Self.t0 + 50)
        #expect(state.apply(.resume(.gps), now: Self.t0 + 50) == Self.leaving(.gps, seconds: 0, source: nil))
        #expect(state.pausedTotal == 0)
    }

    @Test func pausedSinceAndTotalFeedActiveTime() {
        // Hand: start t0; one finished pause of 300 s (t0+180 → t0+480); a second since t0+1 000; now t0+1 600.
        // Active: 1 600 − 300 − (1 600 − 1 000) = 1 600 − 300 − 600 = 700 s.
        var state = WalkPauseState()
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0 + 180)
        _ = state.apply(.resume(.motion), now: Self.t0 + 480)
        _ = state.apply(.pause(.motion, anchor: nil), now: Self.t0 + 1_000)
        #expect(AutoOff.activeTime(startedAt: Self.t0, now: Self.t0 + 1_600, pausedTotal: state.pausedTotal,
                                   pausedSince: state.pausedSince) == 700)
    }
}
