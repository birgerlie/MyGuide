import Foundation
import Testing
@testable import MyGuideCore

/// Streamed text shown at most every 100 ms (spec 8).
@Suite struct TextThrottleTests {
    static let t = ContinuousClock.now
    static func at(_ ms: Int) -> ContinuousClock.Instant { t + .milliseconds(ms) }

    @Test func interval() {
        #expect(TextThrottleState.interval == .milliseconds(100))
    }

    @Test func firstPushShowsImmediately() {
        var state = TextThrottleState()
        #expect(state.push("a", now: Self.at(0)) == .show("a"))
        #expect(state.pending == nil)
    }

    @Test func pushesWithinTheIntervalCoalesceIntoTheNewest() {
        var state = TextThrottleState()
        #expect(state.push("a", now: Self.at(0)) == .show("a"))
        // 40 − 0 = 40 < 100 → wait until 0 + 100 = 100 ms.
        #expect(state.push("ab", now: Self.at(40)) == .flush(at: Self.at(100)))
        // A flush is already due: 70 ms just replaces the waiting text.
        #expect(state.push("abc", now: Self.at(70)) == .wait)
        #expect(state.pending == "abc")
        // At 100 ms the newest text shows; "ab" is never shown.
        #expect(state.flush(now: Self.at(100)) == "abc")
        // 150 − 100 = 50 < 100 → wait until 100 + 100 = 200 ms.
        #expect(state.push("abcd", now: Self.at(150)) == .flush(at: Self.at(200)))
        #expect(state.flush(now: Self.at(200)) == "abcd")
        // 350 − 200 = 150 ≥ 100 → at once.
        #expect(state.push("abcde", now: Self.at(350)) == .show("abcde"))
    }

    @Test func boundaryIsExactlyTheInterval() {
        var state = TextThrottleState()
        _ = state.push("a", now: Self.at(0))
        // 99 − 0 = 99 < 100 → waits; at 100 it is due.
        #expect(state.push("b", now: Self.at(99)) == .flush(at: Self.at(100)))
        #expect(state.flush(now: Self.at(100)) == "b")
        // 200 − 100 = 100, not < 100 → at once.
        #expect(state.push("c", now: Self.at(200)) == .show("c"))
    }

    @Test func flushNeverLosesTheLastValue() {
        var state = TextThrottleState()
        _ = state.push("1", now: Self.at(0))
        for i in 2...20 { _ = state.push("\(i)", now: Self.at(i)) }
        #expect(state.flush(now: Self.at(100)) == "20")
        // Nothing pushed since: a flush shows nothing more.
        #expect(state.flush(now: Self.at(200)) == nil)
    }

    @Test func resetDropsTheWaitingTextAndTheLastShowing() {
        var state = TextThrottleState()
        _ = state.push("a", now: Self.at(0))
        _ = state.push("b", now: Self.at(10))
        state.reset()
        #expect(state.pending == nil)
        #expect(state.flush(now: Self.at(100)) == nil)
        // The next stream starts fresh: 20 ms after the old showing, yet at once.
        #expect(state.push("x", now: Self.at(20)) == .show("x"))
    }

    // MARK: - Main-actor throttle

    @MainActor final class Shown {
        var texts: [String] = []
    }

    @MainActor static func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @MainActor @Test func throttleShowsFirstAtOnceAndTheNewestLater() async {
        let shown = Shown()
        let throttle = TextThrottle { shown.texts.append($0) }
        throttle.push("a")
        // Synchronously, before any suspension.
        #expect(shown.texts == ["a"])
        throttle.push("ab")
        throttle.push("abc")
        #expect(shown.texts == ["a"])
        // Within about 100 ms the newest arrives; "ab" never shows.
        #expect(await Self.waitUntil { shown.texts.count == 2 })
        #expect(shown.texts == ["a", "abc"])
    }

    @MainActor @Test func throttleCancelDropsTheWaitingText() async throws {
        let shown = Shown()
        let throttle = TextThrottle { shown.texts.append($0) }
        throttle.push("a")
        throttle.push("ab")
        throttle.cancel()
        // Well past the 100 ms flush: nothing more shows.
        try await Task.sleep(for: .milliseconds(300))
        #expect(shown.texts == ["a"])
        // And the next stream's first text shows at once.
        throttle.push("x")
        #expect(shown.texts == ["a", "x"])
    }
}
