import Foundation

/// Decides whether a `quiet` decision is worth a log line: only when the reason or the set of due place ids differs
/// from the last logged pair (spec 4.3). Call `reset()` after a buzz, a pause or a resume.
public struct QuietThrottle: Sendable {
    private struct Key: Equatable { var reason: QuietReason; var ids: [String] }
    private var last: Key?

    public init() {}

    public mutating func shouldLog(_ reason: QuietReason, due: [DuePlace]) -> Bool {
        let key = Key(reason: reason, ids: due.map(\.id).sorted())
        if key == last { return false }
        last = key
        return true
    }

    public mutating func reset() { last = nil }
}
