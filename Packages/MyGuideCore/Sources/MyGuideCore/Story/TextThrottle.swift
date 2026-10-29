import Foundation

/// When to show a growing text so it changes at most once per `interval` (spec 8: streamed text at most every
/// 100 ms). Pure: the caller passes the time and runs the timer.
public struct TextThrottleState: Sendable {
    public static let interval: Duration = .milliseconds(100)

    public enum Action: Sendable, Equatable {
        /// Show this text now.
        case show(String)
        /// Call `flush` at this instant; the newest text pushed by then is shown.
        case flush(at: ContinuousClock.Instant)
        /// A flush is already due; the text waits for it.
        case wait
    }

    /// The newest text not yet shown.
    public private(set) var pending: String?
    private var lastShown: ContinuousClock.Instant?
    private var due: ContinuousClock.Instant?

    public init() {}

    /// The first text, or one arriving `interval` or more after the last showing, shows at once. One arriving sooner
    /// waits until `interval` after the last showing; texts arriving meanwhile replace it.
    public mutating func push(_ text: String, now: ContinuousClock.Instant) -> Action {
        pending = text
        if due != nil { return .wait }
        if let lastShown, now - lastShown < Self.interval {
            let at = lastShown + Self.interval
            due = at
            return .flush(at: at)
        }
        return take(now: now).map(Action.show) ?? .wait
    }

    /// The due time has come: the newest pending text, if any, to show now.
    public mutating func flush(now: ContinuousClock.Instant) -> String? {
        due = nil
        return take(now: now)
    }

    /// Drops the waiting text and forgets the last showing, for the next stream.
    public mutating func reset() {
        self = TextThrottleState()
    }

    private mutating func take(now: ContinuousClock.Instant) -> String? {
        guard let text = pending else { return nil }
        pending = nil
        lastShown = now
        return text
    }
}

/// Shows a growing text through `show` at most once per `TextThrottleState.interval`, on the main actor. The first
/// text shows at once; texts arriving within the interval wait, and only the newest of them is shown when it ends.
@MainActor
public final class TextThrottle {
    private let show: (String) -> Void
    private var state = TextThrottleState()
    private var timer: Task<Void, Never>?

    public init(show: @escaping (String) -> Void) {
        self.show = show
    }

    isolated deinit {
        timer?.cancel()
    }

    public func push(_ text: String) {
        switch state.push(text, now: .now) {
        case .show(let text):
            show(text)
        case .flush(let at):
            timer = Task { [weak self] in
                try? await Task.sleep(until: at, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        case .wait:
            break
        }
    }

    /// Drops the waiting text and forgets the last showing, for the next stream.
    public func cancel() {
        timer?.cancel()
        timer = nil
        state.reset()
    }

    private func flush() {
        timer = nil
        if let text = state.flush(now: .now) { show(text) }
    }
}
