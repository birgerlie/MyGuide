import Foundation

/// The one-line walking status shown on the capture screen.
public enum WalkingStatus {
    /// A fix older than this no longer counts as "have GPS".
    public static let staleAfter: TimeInterval = 120
    /// The Live Activity is pushed again once its stale date would move on by this much (seconds), so it never goes
    /// stale while fixes keep coming, yet is not pushed on every fix.
    public static let staleRefreshStep: TimeInterval = 30

    /// Nil when walking mode is off. Paused wins over waiting for GPS. A missing or stale fix reads as waiting for GPS (120 s is still fresh).
    public static func text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date, paused: Bool = false) -> String? {
        guard isOn else { return nil }
        if paused { return "Paused · \(buzzCount) \(buzzCount == 1 ? "buzz" : "buzzes")" }
        guard let lastFixAt, now.timeIntervalSince(lastFixAt) <= staleAfter else { return "Walking · waiting for GPS" }
        return "Walking · \(buzzCount) \(buzzCount == 1 ? "buzz" : "buzzes")"
    }

    /// When the Live Activity stops claiming "Walking" (the widget then shows that walking is paused): `staleAfter`
    /// after the last usable fix, or after the start while there has been none. A run whose app was ended gets no more
    /// fixes and no more pushes, so its activity goes stale on its own. A fix timed before the start counts as the start.
    public static func activityStaleDate(lastFixAt: Date?, startedAt: Date) -> Date {
        max(lastFixAt ?? startedAt, startedAt) + staleAfter
    }

    /// The stale date pushed with a real pause: the widget's stale path takes over `staleAfter` later if no push follows.
    public static func pausedStaleDate(now: Date) -> Date { now + staleAfter }

    /// True when the activity must be pushed again just to carry `next` as its stale date: nothing pushed yet, or the
    /// stale date moved at least `staleRefreshStep` past the pushed one (never for one that moved backwards).
    public static func needsStaleRefresh(pushed: Date?, next: Date) -> Bool {
        guard let pushed else { return true }
        return next.timeIntervalSince(pushed) >= staleRefreshStep
    }
}
