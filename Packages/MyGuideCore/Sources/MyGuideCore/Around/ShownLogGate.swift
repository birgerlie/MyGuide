import Foundation

/// Decides which of the map's selections walking mode writes to the walk log as `shown` (spec 19.7), so the log holds
/// what the map showed and only its changes:
/// - a newly selected place is written with why it was selected: `tap` or `buzz` for an explicit selection,
///   `tap` too while the selector holds a tapped place, else `heading`;
/// - the same place again is written only when an explicit tap or buzz gives it a different reason; automatic
///   updates of the same place say nothing new;
/// - no place is written as `cleared` only once the map has shown none for `clearedConfirmation` seconds, so a fix
///   that blinks above the accuracy limit and back writes nothing. Nothing is cleared before a place was written.
///
/// Pure state: the caller feeds it every selection update, at least once a second while the map is visible, and
/// writes what it returns.
public struct ShownLogGate: Sendable {
    /// Seconds without a selected place before `cleared` is written.
    public static let clearedConfirmation: TimeInterval = 5

    /// The last line returned: its place (nil for `cleared`) and reason.
    private var logged: (placeID: String?, reason: ShownReason)?
    /// Since when no place has been selected, while a `cleared` waits for its confirmation.
    private var clearedSince: Date?

    public init() {}

    /// The map's selection at `now`: the selected place's `placeID` and `name` (nil without one); `cause`, why it is
    /// selected: `heading` for the selector's automatic rules (also when it keeps the playing story's place),
    /// `tap` or `buzz` right after that explicit selection of this place (`cleared` counts as `heading`);
    /// `holding`, true while the selector holds a tapped place, which is then the selected one. Returns the `shown`
    /// line to write, or nil.
    public mutating func note(placeID: String?, name: String?, cause: ShownReason, holding: Bool,
                              now: Date) -> WalkLogEvent.Kind? {
        guard let placeID else { return noteNoPlace(now: now) }
        clearedSince = nil
        let explicit = cause == .tap || cause == .buzz
        let reason: ShownReason = explicit ? cause : (holding ? .tap : .heading)
        if let logged, logged.placeID == placeID, !explicit || logged.reason == reason { return nil }
        logged = (placeID, reason)
        return .shown(placeID: placeID, name: name, reason: reason)
    }

    /// The map is no longer visible: a `cleared` waiting for its confirmation is dropped, and the wait starts afresh
    /// when the map shows no place again.
    public mutating func mapHidden() {
        clearedSince = nil
    }

    private mutating func noteNoPlace(now: Date) -> WalkLogEvent.Kind? {
        guard let logged, logged.placeID != nil else {
            clearedSince = nil
            return nil
        }
        // A start dated after now (the clock was set back) starts the wait again from now.
        guard let since = clearedSince, now >= since else {
            clearedSince = now
            return nil
        }
        guard now.timeIntervalSince(since) >= Self.clearedConfirmation else { return nil }
        clearedSince = nil
        self.logged = (nil, .cleared)
        return .shown(placeID: nil, name: nil, reason: .cleared)
    }
}
