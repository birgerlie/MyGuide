import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GuidedWalkTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func state(_ phase: GuidedWalkPhase, buzzes: Int = 0) -> GuidedWalkState {
        GuidedWalkState(phase: phase, buzzCount: buzzes, startedAt: phase == .off ? nil : t0,
                        pausedTotal: 0, pausedSince: nil, problem: nil, sentAt: t0)
    }

    @Test func labels() {
        #expect(Self.state(.off).label == "Off")
        #expect(Self.state(.starting).label == "Starting…")
        #expect(Self.state(.walking, buzzes: 1).label == "Walking · 1 buzz")
        #expect(Self.state(.walking, buzzes: 2).label == "Walking · 2 buzzes")
        #expect(Self.state(.walking, buzzes: 0).label == "Walking · 0 buzzes")
        #expect(Self.state(.pausedAuto, buzzes: 3).label == "Paused · not moving")
        #expect(Self.state(.pausedManual, buzzes: 3).label == "Paused")
    }

    @Test func offFactoryCarriesProblemAndSentAt() {
        let s = GuidedWalkState.off(sentAt: Self.t0 + 5, problem: "Workout ended")
        #expect(s.phase == .off)
        #expect(s.buzzCount == 0)
        #expect(s.startedAt == nil)
        #expect(s.problem == "Workout ended")
        #expect(s.sentAt == Self.t0 + 5)
        #expect(GuidedWalkState.off(sentAt: Self.t0).problem == nil)
    }

    @Test func activeTimeSubtractsPauses() {
        // Hand: now − startedAt = 1000; pausedTotal = 100; current pause = (t0+1000) − (t0+900) = 100.
        // 1000 − 100 − 100 = 800.
        var s = GuidedWalkState(phase: .pausedAuto, buzzCount: 0, startedAt: Self.t0,
                                pausedTotal: 100, pausedSince: Self.t0 + 900, problem: nil, sentAt: Self.t0)
        #expect(s.activeTime(now: Self.t0 + 1000) == 800)
        // Hand: not paused now: 1000 − 100 − 0 = 900.
        s.pausedSince = nil
        s.phase = .walking
        #expect(s.activeTime(now: Self.t0 + 1000) == 900)
        // Off gives 0, even with a startedAt left over.
        s.phase = .off
        #expect(s.activeTime(now: Self.t0 + 1000) == 0)
        #expect(GuidedWalkState.off(sentAt: Self.t0).activeTime(now: Self.t0 + 1000) == 0)
        // Clock step back: now = t0 − 50 → −50 − 0 = −50 → clamped to 0.
        s.phase = .walking
        #expect(s.activeTime(now: Self.t0 - 50) == 0)
        // Pauses exceeding elapsed: 10 − 100 = −90 → 0.
        #expect(s.activeTime(now: Self.t0 + 10) == 0)
    }

    @Test func messageRoundTrip() {
        let full = GuidedWalkState(phase: .pausedAuto, buzzCount: 4, startedAt: Self.t0,
                                   pausedTotal: 12.5, pausedSince: Self.t0 + 300,
                                   problem: "Not saved to Health", sentAt: Self.t0 + 301)
        #expect(GuidedWalkState(message: full.message) == full)
        let m = full.message
        #expect(m["type"] as? String == "walk.state")
        #expect(m["phase"] as? String == "pausedAuto")
        #expect(m["buzzCount"] as? Int == 4)
        #expect(m["startedAt"] as? Double == 1_000_000)
        #expect(m["sentAt"] as? Double == 1_000_301)

        let bare = GuidedWalkState.off(sentAt: Self.t0)
        let bm = bare.message
        #expect(bm["startedAt"] == nil)
        #expect(bm["pausedSince"] == nil)
        #expect(bm["problem"] == nil)
        #expect(GuidedWalkState(message: bm) == bare)
    }

    @Test func wrongTypeOrMissingFieldIsNil() {
        let good = Self.state(.walking, buzzes: 1).message
        #expect(GuidedWalkState(message: good) != nil)

        var wrongType = good; wrongType["type"] = "walk.pause"
        #expect(GuidedWalkState(message: wrongType) == nil)
        for key in ["type", "phase", "buzzCount", "pausedTotal", "sentAt"] {
            var m = good; m[key] = nil
            #expect(GuidedWalkState(message: m) == nil, "missing \(key)")
        }
        var badPhase = good; badPhase["phase"] = "dancing"
        #expect(GuidedWalkState(message: badPhase) == nil)
        var badCount = good; badCount["buzzCount"] = "3"
        #expect(GuidedWalkState(message: badCount) == nil)
        var badDate = good; badDate["sentAt"] = "yesterday"
        #expect(GuidedWalkState(message: badDate) == nil)
        #expect(GuidedWalkState(message: [:]) == nil)
    }

    @Test func olderSentAtIsNotApplied() {
        let current = Self.state(.walking)
        var equal = current; equal.phase = .off
        var older = current; older.sentAt = Self.t0 - 1
        var newer = current; newer.sentAt = Self.t0 + 1
        #expect(!equal.isNewer(than: current))
        #expect(!older.isNewer(than: current))
        #expect(newer.isNewer(than: current))
        #expect(current.isNewer(than: nil))
    }

    @Test func actionTable() {
        let phases: [GuidedWalkPhase] = [.off, .starting, .walking, .pausedAuto, .pausedManual]
        let table: [GuidedWalkCommand: [GuidedWalkAction]] = [
            .start:  [.start, .none, .none, .none, .none],
            .pause:  [.none, .none, .pauseManual, .pauseManual, .none],
            .resume: [.none, .none, .none, .resume, .resume],
            .stop:   [.none, .stop, .stop, .stop, .stop],
        ]
        var cells = 0
        for (command, expected) in table {
            for (phase, want) in zip(phases, expected) {
                #expect(command.action(in: phase) == want, "\(command) in \(phase)")
                cells += 1
            }
        }
        #expect(cells == 20)
    }

    @Test func commandParsing() {
        #expect(GuidedWalkCommand(message: ["type": "walk.pause"]) == .pause)
        #expect(GuidedWalkCommand(message: ["type": "walk.start"]) == .start)
        #expect(GuidedWalkCommand(message: ["type": "walk.resume"]) == .resume)
        #expect(GuidedWalkCommand(message: ["type": "walk.stop"]) == .stop)
        #expect(GuidedWalkCommand(message: ["type": "walk.dance"]) == nil)
        #expect(GuidedWalkCommand(message: ["type": "walk.state"]) == nil)
        #expect(GuidedWalkCommand(message: ["type": 5]) == nil)
        #expect(GuidedWalkCommand(message: [:]) == nil)
    }
}

/// The watch–phone message types outside the guided walk. Older builds on the other side send and expect exactly
/// these strings.
@Suite struct WatchMessageTests {
    @Test func wireStrings() {
        #expect(WatchMessage.checkTell == "check.tell")
        #expect(WatchMessage.ping == "ping")
        #expect(WatchMessage.pong == "pong")
        #expect(GuidedWalkState.messageType == "walk.state")
        #expect(GuidedWalkBuzz.messageType == "buzz")
    }
}
