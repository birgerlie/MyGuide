import Synchronization

/// Races work against a deadline, and stops waiting for work that ignores cancellation (MapKit's request, a shared
/// fetch, a system callback that may never come). Waiting ends on time; the work itself is cancelled and left to end
/// on its own, and whatever it answers late is dropped.
public enum Deadline {
    /// Thrown by `withTimeout` when the sleep wins.
    public struct Timeout: Error, Equatable {
        public init() {}
    }

    /// The work's value if it answers within `timeout`, else nil. Never throws: running out of time, an abandoned
    /// wait and the caller's cancellation all give nil, and the caller's cancellation returns at once even when the
    /// work ignores it.
    public static func value<T: Sendable>(within timeout: Duration,
                                          _ work: @escaping @Sendable () async -> T?) async -> T? {
        do {
            return try await withTimeout(timeout, work)
        } catch {
            return nil
        }
    }

    /// Races `work` against a sleep of `timeout`; the loser is cancelled. Throws `Timeout` if the sleep wins.
    /// `work` runs abandonable, so a source that ignores cancellation (MapKit's request) cannot hold the race open.
    public static func withTimeout<T: Sendable>(_ timeout: Duration,
                                                _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await abandoningOnCancel(work) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Timeout()
            }
            defer { group.cancelAll() }
            // Both children always finish (with a value or an error), so next() never returns nil here.
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }

    /// Runs `work` in its own task and waits for it, but stops waiting with CancellationError as soon as the
    /// caller is cancelled, even if `work` ignores cancellation. The abandoned task is cancelled and left to end on its own.
    public static func abandoningOnCancel<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce<T>()
        let task = Task {
            do { once.resume(with: .success(try await work())) } catch { once.resume(with: .failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { once.attach($0) }
        } onCancel: {
            task.cancel()
            once.resume(with: .failure(CancellationError()))
        }
    }
}

/// Resumes one continuation exactly once with the first result offered, whether that result arrives
/// before or after the continuation is attached. Later results are dropped.
private final class ResumeOnce<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Error>)
        case early(Result<T, Error>)
        case done
    }
    private let state = Mutex<State>(.idle)

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return nil
            case .early(let result):
                state = .done
                return result
            case .waiting, .done:
                preconditionFailure("ResumeOnce attached twice")
            }
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .early(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .early, .done:
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
