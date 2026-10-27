import Foundation

/// The one-line walking status shown on the capture screen.
public enum WalkingStatus {
    /// A fix older than this no longer counts as "have GPS".
    public static let staleAfter: TimeInterval = 120

    /// Nil when walking mode is off. A missing or stale fix reads as waiting for GPS (120 s is still fresh).
    public static func text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date) -> String? {
        guard isOn else { return nil }
        guard let lastFixAt, now.timeIntervalSince(lastFixAt) <= staleAfter else { return "Walking · waiting for GPS" }
        return "Walking · \(buzzCount) \(buzzCount == 1 ? "buzz" : "buzzes")"
    }
}
