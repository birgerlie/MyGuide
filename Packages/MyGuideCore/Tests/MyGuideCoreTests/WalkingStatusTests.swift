import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingStatusTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func text() {
        #expect(WalkingStatus.text(isOn: false, lastFixAt: Self.t0, buzzCount: 3, now: Self.t0) == nil)
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 0, now: Self.t0) == "Walking · waiting for GPS")
        // Review Focus 1: 120 s is still fresh, 121 s is stale
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 120) == "Walking · 1 buzz")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 121) == "Walking · waiting for GPS")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 0, now: Self.t0) == "Walking · 0 buzzes")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 7, now: Self.t0) == "Walking · 7 buzzes")
    }

    @Test func aFixFromTheFutureIsFresh() {
        // A clock that stepped back makes the age negative (-5 s), which is not older than 120 s.
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0 + 5, buzzCount: 2, now: Self.t0) == "Walking · 2 buzzes")
    }
}

@Suite struct WalkingActivityStalenessTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func staleDateFollowsTheLastFix() {
        // Hand: last fix at t0+50 → t0+50+120 = t0+170. Last fix at t0+600 → t0+720.
        #expect(WalkingStatus.activityStaleDate(lastFixAt: Self.t0 + 50, startedAt: Self.t0) == Self.t0 + 170)
        #expect(WalkingStatus.activityStaleDate(lastFixAt: Self.t0 + 600, startedAt: Self.t0) == Self.t0 + 720)
    }

    @Test func withoutAFixTheStartCounts() {
        // Hand: no fix, started t0 → t0+120. A fix 10 s before the start (fresh cached fix) → still t0+120, not t0+110.
        #expect(WalkingStatus.activityStaleDate(lastFixAt: nil, startedAt: Self.t0) == Self.t0 + 120)
        #expect(WalkingStatus.activityStaleDate(lastFixAt: Self.t0 - 10, startedAt: Self.t0) == Self.t0 + 120)
    }

    @Test func refreshOnlyWhenTheStaleDateMovesThirtySeconds() {
        // Hand: pushed t0+120. Next t0+150: 30 ≥ 30 → push. Next t0+149: 29 < 30 → no. Next t0+100 (moved back) → no.
        #expect(WalkingStatus.needsStaleRefresh(pushed: nil, next: Self.t0))
        #expect(WalkingStatus.needsStaleRefresh(pushed: Self.t0 + 120, next: Self.t0 + 150))
        #expect(!WalkingStatus.needsStaleRefresh(pushed: Self.t0 + 120, next: Self.t0 + 149))
        #expect(!WalkingStatus.needsStaleRefresh(pushed: Self.t0 + 120, next: Self.t0 + 100))
    }

    @Test func oneFixASecondNeverLetsTheActivityGoStale() {
        // Fixes every second from t0 to t0+600, pushing whenever needed. Hand: pushes at fixes t0, t0+30, …, t0+600
        // (each moves the stale date 30 s) → 21 pushes; before every fix the pushed stale date is ≥ fix + 90 > fix,
        // so the activity is never stale while fixes come. After the last fix it goes stale at t0+600+120 = t0+720.
        var pushed: Date?
        var pushes = 0
        for s in 0...600 {
            let fix = Self.t0 + Double(s)
            if let pushed { #expect(pushed > fix) }
            let next = WalkingStatus.activityStaleDate(lastFixAt: fix, startedAt: Self.t0)
            if WalkingStatus.needsStaleRefresh(pushed: pushed, next: next) {
                pushed = next
                pushes += 1
            }
        }
        #expect(pushes == 21)
        #expect(pushed == Self.t0 + 720)
    }
}
