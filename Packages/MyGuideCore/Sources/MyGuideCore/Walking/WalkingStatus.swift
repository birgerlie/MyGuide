import Foundation

/// Why walking mode is paused, for the status text: by the detector (`auto`) or by the user's command (`manual`).
public enum WalkingPauseKind: Sendable { case auto, manual }

/// The one-line walking status shown on the capture screen.
public enum WalkingStatus {
    /// A fix older than this no longer counts as "have GPS".
    public static let staleAfter: TimeInterval = 120
    /// The Live Activity is pushed again once its stale date would move on by this much (seconds), so it never goes
    /// stale while fixes keep coming, yet is not pushed on every fix.
    public static let staleRefreshStep: TimeInterval = 30

    /// Nil when walking mode is off. Paused wins over waiting for GPS: manual reads "Paused · N buzzes", auto "Paused · not moving · N buzzes". A missing or stale fix reads as waiting for GPS (120 s is still fresh).
    /// Norwegian ("Går · N varsler", "Pauset · står stille · N varsler", "Går · venter på GPS") follows the same rules.
    /// The Live Activity no longer shows this line: it has its own texts (`WalkingActivityController`, spec 7.5).
    public static func text(isOn: Bool, lastFixAt: Date?, buzzCount: Int, now: Date, pause: WalkingPauseKind? = nil,
                            language: StoryLanguage = .english) -> String? {
        guard isOn else { return nil }
        let nb = language == .norwegian
        let buzzes = nb
            ? "\(buzzCount) \(buzzCount == 1 ? "varsel" : "varsler")"
            : "\(buzzCount) \(buzzCount == 1 ? "buzz" : "buzzes")"
        let walking = nb ? "Går" : "Walking"
        let paused = nb ? "Pauset" : "Paused"
        switch pause {
        case .manual: return "\(paused) · \(buzzes)"
        case .auto: return "\(paused) · \(nb ? "står stille" : "not moving") · \(buzzes)"
        case nil: break
        }
        guard hasFreshFix(lastFixAt: lastFixAt, now: now) else {
            return "\(walking) · \(nb ? "venter på GPS" : "waiting for GPS")"
        }
        return "\(walking) · \(buzzes)"
    }

    /// True when there is a fix at most `staleAfter` old (exactly 120 s is still fresh). A fix timed after `now` (the
    /// clock stepped back) counts as fresh.
    public static func hasFreshFix(lastFixAt: Date?, now: Date) -> Bool {
        guard let lastFixAt else { return false }
        return now.timeIntervalSince(lastFixAt) <= staleAfter
    }

    /// The walking line over the tab bar (spec 14, amended 2026-10-30), without the buzz count, which only the walking
    /// sheet shows. Nil when walking mode is off. Paused wins over waiting for GPS, as in `text`: manual «Pauset» /
    /// «Paused», auto «Pauset · står stille» / «Paused · not moving». A missing or stale fix reads «Venter på GPS» /
    /// «Waiting for GPS». Otherwise «Gåmodus · 42 min» / «Walking · 42 min», the time since `startedAt` as
    /// `TourFormat.duration` words it; without `startedAt` just «Gåmodus» / «Walking».
    public static func line(isOn: Bool, startedAt: Date?, lastFixAt: Date?, now: Date, pause: WalkingPauseKind?,
                            language: StoryLanguage) -> Line? {
        guard isOn else { return nil }
        let nb = language == .norwegian
        switch pause {
        case .manual: return .paused(nb ? "Pauset" : "Paused")
        case .auto: return .paused(nb ? "Pauset · står stille" : "Paused · not moving")
        case nil: break
        }
        guard hasFreshFix(lastFixAt: lastFixAt, now: now) else {
            return .waitingForGPS(nb ? "Venter på GPS" : "Waiting for GPS")
        }
        let walking = nb ? "Gåmodus" : "Walking"
        guard let startedAt else { return .walking(walking) }
        return .walking("\(walking) · \(TourFormat.duration(now.timeIntervalSince(startedAt), language: language))")
    }

    /// What the walking line says, by kind, so the screen can rank it against a problem, a story and a tour.
    public enum Line: Equatable, Sendable {
        case walking(String)
        case waitingForGPS(String)
        case paused(String)

        public var text: String {
            switch self {
            case .walking(let text), .waitingForGPS(let text), .paused(let text): text
            }
        }
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
