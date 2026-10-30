import Foundation

/// Decides whether a `quiet` decision is worth a log line: only when the reason, the set of due place ids or the
/// holding place (`held`, spec 20.6.6) differs from the last logged one (spec 4.3). Call `reset()` after a buzz, a pause or a resume.
public struct QuietThrottle: Sendable {
    private struct Key: Equatable { var reason: QuietReason; var ids: [String]; var holder: String? }
    private var last: Key?

    public init() {}

    public mutating func shouldLog(_ reason: QuietReason, due: [DuePlace], heldBy: HoldingPlace? = nil) -> Bool {
        let key = Key(reason: reason, ids: due.map(\.id).sorted(), holder: heldBy?.id)
        if key == last { return false }
        last = key
        return true
    }

    public mutating func reset() { last = nil }
}
