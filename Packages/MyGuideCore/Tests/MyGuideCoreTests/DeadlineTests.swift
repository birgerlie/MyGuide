import Foundation
import Synchronization
import Testing
import MyGuideCore

@Suite struct DeadlineTests {
    private struct Boom: Error, Equatable {}

    /// Never returns and ignores cancellation, like a MapKit request that does not answer.
    private static func hang() async {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    /// Sleeps `duration` and cannot be cut short: awaiting a detached task's value does not pass cancellation on.
    private static func uncancellableSleep(_ duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }

    private static func elapsed(_ work: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        return clock.now - start
    }

    // MARK: value(within:)

    @Test func valueWhenTheWorkWins() async {
        // The work answers at once; the 60 s deadline is never reached.
        let took = await Self.elapsed {
            let value = await Deadline.value(within: .seconds(60)) { 42 }
            #expect(value == 42)
        }
        #expect(took < .seconds(1))
    }

    @Test func valueIsNilWhenTheWorkAnswersNil() async {
        let value: Int? = await Deadline.value(within: .seconds(60)) { nil }
        #expect(value == nil)
    }

    @Test(arguments: [false, true]) func valueIsNilWhenTheTimeoutWins(ignoresCancellation: Bool) async {
        // Deadline 50 ms; the work needs 60 s (or never answers). The wait is at least 50 ms and ends well before
        // 1 s: 50 ms + scheduling slack (a few ms) < 1000 ms.
        let took = await Self.elapsed {
            let value: Int? = await Deadline.value(within: .milliseconds(50)) {
                if ignoresCancellation {
                    await Self.hang()
                } else {
                    try? await Task.sleep(for: .seconds(60))
                }
                return 7
            }
            #expect(value == nil)
        }
        #expect(took >= .milliseconds(50))
        #expect(took < .seconds(1))
    }

    @Test func valueReturnsPromptlyWhenTheCallerIsCancelledAndTheWorkIgnoresIt() async {
        // A 60 s deadline proves the return comes from the cancellation, not from the timeout: the caller is cancelled
        // after 50 ms and must be back within 1 s (60 s ≫ 1 s).
        let caller = Task { await Deadline.value(within: .seconds(60)) { await Self.hang(); return 7 } }
        try? await Task.sleep(for: .milliseconds(50))
        let took = await Self.elapsed {
            caller.cancel()
            let value = await caller.value
            #expect(value == nil)
        }
        #expect(took < .seconds(1))
    }

    @Test func valueDropsALateResult() async {
        // Deadline 50 ms; the work ignores cancellation and answers at 200 ms. The caller gets nil at about 50 ms; the
        // answer at 200 ms reaches nobody and must not resume the finished wait a second time (that would trap).
        let finished = Mutex(false)
        let value: Int? = await Deadline.value(within: .milliseconds(50)) {
            await Self.uncancellableSleep(.milliseconds(200))
            finished.withLock { $0 = true }
            return 7
        }
        #expect(value == nil)
        #expect(finished.withLock { $0 } == false)
        // Wait for the late answer: 200 ms − ~50 ms already waited = ~150 ms left; poll for up to 2 s.
        let clock = ContinuousClock()
        let giveUp = clock.now + .seconds(2)
        while !finished.withLock({ $0 }), clock.now < giveUp {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished.withLock { $0 })
        // Room for the dropped resume to happen; a double resume would crash the test process here.
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: withTimeout

    @Test func withTimeoutReturnsTheWorksValue() async throws {
        let value = try await Deadline.withTimeout(.seconds(60)) { "answer" }
        #expect(value == "answer")
    }

    @Test func withTimeoutThrowsTimeoutWhenTheSleepWins() async {
        // Deadline 50 ms, work 60 s: the sleep wins, the error is Timeout (not CancellationError).
        await #expect(throws: Deadline.Timeout.self) {
            try await Deadline.withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
    }

    @Test func withTimeoutPassesTheWorksErrorOn() async {
        await #expect(throws: Boom.self) {
            try await Deadline.withTimeout(.seconds(60)) { () async throws -> Int in throw Boom() }
        }
    }

    @Test func withTimeoutThrowsCancellationWhenTheCallerIsCancelled() async {
        // 60 s deadline, cancelled at 50 ms: back within 1 s with CancellationError, not Timeout.
        let caller = Task {
            try await Deadline.withTimeout(.seconds(60)) { await Self.hang(); return 1 }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let took = await Self.elapsed {
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await caller.value }
        }
        #expect(took < .seconds(1))
    }

    // MARK: abandoningOnCancel

    @Test func abandoningOnCancelReturnsTheWorksValue() async throws {
        let value = try await Deadline.abandoningOnCancel { 5 }
        #expect(value == 5)
    }

    @Test func abandoningOnCancelPassesTheWorksErrorOn() async {
        await #expect(throws: Boom.self) {
            try await Deadline.abandoningOnCancel { () async throws -> Int in throw Boom() }
        }
    }

    @Test func abandoningOnCancelThrowsCancellationAtOnceAndDropsTheLateResult() async {
        // The work ignores cancellation and answers at 200 ms; the caller is cancelled at 50 ms and is back within
        // 1 s with CancellationError. The answer at 200 ms is dropped.
        let finished = Mutex(false)
        let caller = Task {
            try await Deadline.abandoningOnCancel { () async -> Int in
                await Self.uncancellableSleep(.milliseconds(200))
                finished.withLock { $0 = true }
                return 9
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let took = await Self.elapsed {
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await caller.value }
        }
        #expect(took < .seconds(1))
        let clock = ContinuousClock()
        let giveUp = clock.now + .seconds(2)
        while !finished.withLock({ $0 }), clock.now < giveUp {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished.withLock { $0 })
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func abandoningOnCancelWhenAlreadyCancelledThrowsCancellation() async {
        // Cancelled before the call: the cancellation handler runs at once, before the continuation is attached;
        // the early CancellationError is delivered when it is.
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Deadline.abandoningOnCancel { await Self.hang(); return 1 }
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
    }
}
