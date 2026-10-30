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

    @Test func freshnessEdgeIsExactlyStaleAfter() {
        // Age 120 s = staleAfter → fresh; 120.001 s > 120 → waiting.
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 120.001)
                == "Walking · waiting for GPS")
    }

    @Test func hasFreshFix() {
        // Age = now − lastFixAt. 120 = staleAfter → fresh; 120.001 > 120 → not; no fix → not.
        #expect(WalkingStatus.hasFreshFix(lastFixAt: Self.t0, now: Self.t0 + 120))
        #expect(!WalkingStatus.hasFreshFix(lastFixAt: Self.t0, now: Self.t0 + 120.001))
        #expect(!WalkingStatus.hasFreshFix(lastFixAt: nil, now: Self.t0))
        // Age 0 → fresh; age −5 (clock stepped back) → fresh, as in `text`.
        #expect(WalkingStatus.hasFreshFix(lastFixAt: Self.t0, now: Self.t0))
        #expect(WalkingStatus.hasFreshFix(lastFixAt: Self.t0 + 5, now: Self.t0))
    }

    @Test func aFixFromTheFutureIsFresh() {
        // A clock that stepped back makes the age negative (-5 s), which is not older than 120 s.
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0 + 5, buzzCount: 2, now: Self.t0) == "Walking · 2 buzzes")
    }

    @Test func pausedTextWinsOverWaiting() {
        // No fix at all, yet paused wins over "waiting for GPS"; 1 → "buzz", 2 → "buzzes".
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 1, now: Self.t0, pause: .manual) == "Paused · 1 buzz")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 2, now: Self.t0, pause: .manual) == "Paused · 2 buzzes")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 1, now: Self.t0, pause: .auto) == "Paused · not moving · 1 buzz")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 2, now: Self.t0, pause: .auto) == "Paused · not moving · 2 buzzes")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 2, now: Self.t0, pause: nil) == "Walking · 2 buzzes")
        #expect(WalkingStatus.text(isOn: false, lastFixAt: nil, buzzCount: 2, now: Self.t0, pause: .auto) == nil)
    }

    @Test func lineIsNilWhenOff() {
        #expect(WalkingStatus.line(isOn: false, startedAt: Self.t0, lastFixAt: Self.t0, now: Self.t0, pause: nil,
                                   language: .norwegian) == nil)
        #expect(WalkingStatus.line(isOn: false, startedAt: nil, lastFixAt: nil, now: Self.t0, pause: .manual,
                                   language: .english) == nil)
    }

    @Test func lineShowsTheTimeSinceTheStart() {
        // Hand: 42 min = 2520 s → «42 min». 2549 s = 42.48 min → rounds to 42; 2550 s = 42.5 → 43 (nearest, half up).
        // 3900 s = 65 min → «1 t 5 min» / «1 h 5 min». 0 s → «0 min».
        let fix = Self.t0 + 3900
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0 + 2520, now: Self.t0 + 2520,
                                   pause: nil, language: .norwegian) == .walking("Gåmodus · 42 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0 + 2549, now: Self.t0 + 2549,
                                   pause: nil, language: .norwegian) == .walking("Gåmodus · 42 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0 + 2550, now: Self.t0 + 2550,
                                   pause: nil, language: .norwegian) == .walking("Gåmodus · 43 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: fix, now: fix, pause: nil,
                                   language: .norwegian) == .walking("Gåmodus · 1 t 5 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: fix, now: fix, pause: nil,
                                   language: .english) == .walking("Walking · 1 h 5 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0, now: Self.t0, pause: nil,
                                   language: .english) == .walking("Walking · 0 min"))
    }

    @Test func lineWithoutAStartIsJustWalking() {
        #expect(WalkingStatus.line(isOn: true, startedAt: nil, lastFixAt: Self.t0, now: Self.t0, pause: nil,
                                   language: .norwegian) == .walking("Gåmodus"))
    }

    @Test func lineWaitsForGPSAfter120Seconds() {
        // Hand: fix age 120 s = staleAfter → still walking (2 min since start); 121 s → waiting; no fix → waiting.
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0, now: Self.t0 + 120, pause: nil,
                                   language: .norwegian) == .walking("Gåmodus · 2 min"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: Self.t0, now: Self.t0 + 121, pause: nil,
                                   language: .norwegian) == .waitingForGPS("Venter på GPS"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: nil, now: Self.t0, pause: nil,
                                   language: .english) == .waitingForGPS("Waiting for GPS"))
    }

    @Test func linePausedWinsOverWaitingForGPS() {
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: nil, now: Self.t0, pause: .manual,
                                   language: .norwegian) == .paused("Pauset"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: nil, now: Self.t0, pause: .auto,
                                   language: .norwegian) == .paused("Pauset · står stille"))
        #expect(WalkingStatus.line(isOn: true, startedAt: Self.t0, lastFixAt: nil, now: Self.t0, pause: .auto,
                                   language: .english) == .paused("Paused · not moving"))
        #expect(WalkingStatus.Line.paused("Paused").text == "Paused")
    }

    @Test func pausedStaleDate() {
        // Hand: t0 + 120.
        #expect(WalkingStatus.pausedStaleDate(now: Self.t0) == Self.t0 + 120)
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

@Suite struct WalkingStatusNorwegianTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func sameRulesInNorwegian() {
        let nb = StoryLanguage.norwegian
        #expect(WalkingStatus.text(isOn: false, lastFixAt: Self.t0, buzzCount: 3, now: Self.t0, language: nb) == nil)
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 0, now: Self.t0, language: nb) == "Går · venter på GPS")
        // 120 s is still fresh, 121 s is stale; 1 → "varsel", otherwise "varsler".
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 120, language: nb) == "Går · 1 varsel")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 1, now: Self.t0 + 121, language: nb) == "Går · venter på GPS")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 0, now: Self.t0, language: nb) == "Går · 0 varsler")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 2, now: Self.t0, pause: .manual, language: nb) == "Pauset · 2 varsler")
        #expect(WalkingStatus.text(isOn: true, lastFixAt: nil, buzzCount: 1, now: Self.t0, pause: .auto, language: nb) == "Pauset · står stille · 1 varsel")
    }

    @Test func englishIsTheDefault() {
        #expect(WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 2, now: Self.t0, language: .english)
                == WalkingStatus.text(isOn: true, lastFixAt: Self.t0, buzzCount: 2, now: Self.t0))
    }
}
