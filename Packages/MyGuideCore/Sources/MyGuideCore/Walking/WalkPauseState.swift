import Foundation

/// What the walking controller does after a pause change, in the order given (spec 4, 5.4).
public enum WalkPauseEffect: Sendable, Equatable {
    /// Into a pause: coarse location, and the track saved (nothing is held through a pause of up to an hour).
    case suspendTracking
    /// Out of a pause: best location again, and the route, stop detector, track thinning and GPS state start afresh,
    /// so the next fix is judged as usual. The resume time becomes the floor of the Live Activity's stale date.
    case resetRoute
    /// Freeze the pause detector for a manual pause: walking or moving never ends it.
    case holdDetector
    /// Release the pause detector: it starts a fresh still stretch from now.
    case releaseDetector
    /// One walk log line.
    case log(WalkLogEvent.Kind)
    /// The quiet throttle reset, the stop story cleared from the Live Activity when `clearStop`, the Live Activity's
    /// status pushed and the walk state published.
    case refreshActivity(clearStop: Bool)
}

/// The pause bookkeeping of one walking run: which pause is in progress, since when, and the length of the finished
/// ones (which do not count toward the 4-hour limit). Each change returns the effects the controller applies, in order.
/// A fresh value is active with nothing paused; a run starts and stops with one.
public struct WalkPauseState: Sendable, Equatable {
    /// `auto` from the pause detector, with what triggered it (the `resumed` reason of a resume by command);
    /// `manual` from the owner's Pause, which holds until Resume.
    private enum Pause: Sendable, Equatable {
        case auto(PauseTrigger)
        case manual
    }

    private struct Current: Sendable, Equatable {
        var pause: Pause
        var since: Date
    }

    private var current: Current?
    /// The length of the run's finished pauses, in seconds.
    public private(set) var pausedTotal: TimeInterval = 0

    public init() {}

    /// The pause in progress; nil while active.
    public var kind: WalkingPauseKind? {
        switch current?.pause {
        case nil: nil
        case .auto: .auto
        case .manual: .manual
        }
    }

    /// True while paused, by either kind.
    public var isPaused: Bool { current != nil }

    /// When the pause in progress began; nil while active. An auto-pause turned manual keeps its start.
    public var pausedSince: Date? { current?.since }

    /// The pause detector's output. Ignored during a manual pause (the held detector gives none anyway): only Resume
    /// ends it. A detector pause applies only while active, a detector resume only to an auto-pause.
    public mutating func apply(_ change: PauseChange?, now: Date) -> [WalkPauseEffect] {
        switch change {
        case .pause(let trigger, let anchor):
            guard current == nil else { return [] }
            return enter(.auto(trigger), reason: WalkPauseReason(trigger), anchor: anchor, source: nil, now: now)
        case .resume(let trigger):
            guard case .auto = current?.pause else { return [] }
            return leave(reason: WalkPauseReason(trigger), source: nil, now: now)
        case nil:
            return []
        }
    }

    /// The owner's Pause, from the phone or the watch. From walking it enters a manual pause; from an auto-pause the
    /// same pause turns manual: `pausedSince` is kept and one `paused` line with reason `manual` is written. Either
    /// way the detector is held. Already manual: nothing. `anchor` is where the walker is, when known well enough.
    public mutating func pause(source: WalkSource, anchor: Coordinate?, now: Date) -> [WalkPauseEffect] {
        switch current?.pause {
        case .manual:
            return []
        case .auto:
            current?.pause = .manual
            return [.holdDetector, .log(.paused(.manual, at: anchor, source: source)), .refreshActivity(clearStop: false)]
        case nil:
            return enter(.manual, reason: .manual, anchor: anchor, source: source, now: now) + [.holdDetector]
        }
    }

    /// The owner's Resume, from the phone or the watch: ends either kind of pause as if the walker had moved, and
    /// releases the detector. The `resumed` reason is `manual` after a manual pause, else the trigger of the
    /// auto-pause. Not paused: nothing.
    public mutating func resume(source: WalkSource, now: Date) -> [WalkPauseEffect] {
        let reason: WalkPauseReason
        switch current?.pause {
        case nil: return []
        case .manual: reason = .manual
        case .auto(let trigger): reason = WalkPauseReason(trigger)
        }
        return leave(reason: reason, source: source, now: now) + [.releaseDetector]
    }

    /// The one way into a pause. Callers have checked that none is in progress.
    private mutating func enter(_ pause: Pause, reason: WalkPauseReason, anchor: Coordinate?, source: WalkSource?,
                                now: Date) -> [WalkPauseEffect] {
        current = Current(pause: pause, since: now)
        return [.suspendTracking, .log(.paused(reason, at: anchor, source: source)), .refreshActivity(clearStop: true)]
    }

    /// The one way out of a pause: its length (never below 0, as the clock may be set back) joins the total.
    /// Callers have checked that one is in progress.
    private mutating func leave(reason: WalkPauseReason, source: WalkSource?, now: Date) -> [WalkPauseEffect] {
        let paused = current.map { max(0, now.timeIntervalSince($0.since)) } ?? 0
        pausedTotal += paused
        current = nil
        return [.resetRoute, .log(.resumed(reason, pausedSeconds: paused, source: source)),
                .refreshActivity(clearStop: true)]
    }
}
