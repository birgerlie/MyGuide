import Foundation

public enum GuidedWalkPhase: String, Sendable, Codable {
    case off, starting, walking, pausedAuto, pausedManual
}

/// The phone's walk state as the watch sees it. The phone holds the truth; the watch applies a state only
/// when `isNewer(than:)` says so.
public struct GuidedWalkState: Sendable, Equatable {
    public static let messageType = "walk.state"

    public var phase: GuidedWalkPhase
    public var buzzCount: Int
    public var startedAt: Date?
    /// Seconds of finished pauses.
    public var pausedTotal: TimeInterval
    /// Start of the pause in progress, nil when not paused.
    public var pausedSince: Date?
    public var problem: String?
    /// The phone's clock when this state was sent.
    public var sentAt: Date

    public init(phase: GuidedWalkPhase, buzzCount: Int, startedAt: Date?, pausedTotal: TimeInterval = 0,
                pausedSince: Date? = nil, problem: String? = nil, sentAt: Date) {
        self.phase = phase
        self.buzzCount = buzzCount
        self.startedAt = startedAt
        self.pausedTotal = pausedTotal
        self.pausedSince = pausedSince
        self.problem = problem
        self.sentAt = sentAt
    }

    public static func off(sentAt: Date, problem: String? = nil) -> GuidedWalkState {
        GuidedWalkState(phase: .off, buzzCount: 0, startedAt: nil, pausedTotal: 0, pausedSince: nil,
                        problem: problem, sentAt: sentAt)
    }

    public var label: String {
        switch phase {
        case .off: "Off"
        case .starting: "Starting…"
        case .walking: "Walking · \(buzzCount) \(buzzCount == 1 ? "buzz" : "buzzes")"
        case .pausedAuto: "Paused · not moving"
        case .pausedManual: "Paused"
        }
    }

    /// Walking time without pauses: (now − startedAt) − pausedTotal − the pause in progress. Never below 0.
    public func activeTime(now: Date) -> TimeInterval {
        guard phase != .off, let startedAt else { return 0 }
        let currentPause = pausedSince.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - pausedTotal - max(0, currentPause))
    }

    public func isNewer(than other: GuidedWalkState?) -> Bool {
        guard let other else { return true }
        return sentAt > other.sentAt
    }

    /// A property-list message for WatchConnectivity. Dates are seconds since 1970; nil fields are omitted.
    public var message: [String: Any] {
        var m: [String: Any] = [
            "type": Self.messageType,
            "phase": phase.rawValue,
            "buzzCount": buzzCount,
            "pausedTotal": pausedTotal,
            "sentAt": sentAt.timeIntervalSince1970,
        ]
        if let startedAt { m["startedAt"] = startedAt.timeIntervalSince1970 }
        if let pausedSince { m["pausedSince"] = pausedSince.timeIntervalSince1970 }
        if let problem { m["problem"] = problem }
        return m
    }

    /// Nil when the type is not `walk.state` or a required field is missing or of the wrong type.
    /// An optional field of the wrong type is also nil: a malformed message is not applied half-way.
    public init?(message: [String: Any]) {
        guard message["type"] as? String == Self.messageType,
              let rawPhase = message["phase"] as? String, let phase = GuidedWalkPhase(rawValue: rawPhase),
              let buzzCount = message["buzzCount"] as? Int,
              let pausedTotal = message["pausedTotal"] as? Double,
              let sentAt = message["sentAt"] as? Double
        else { return nil }
        func optionalDate(_ key: String) -> Date?? {
            guard let raw = message[key] else { return .some(nil) }
            guard let seconds = raw as? Double else { return nil }
            return .some(Date(timeIntervalSince1970: seconds))
        }
        func optionalString(_ key: String) -> String?? {
            guard let raw = message[key] else { return .some(nil) }
            guard let s = raw as? String else { return nil }
            return .some(s)
        }
        guard let startedAt = optionalDate("startedAt"), let pausedSince = optionalDate("pausedSince"),
              let problem = optionalString("problem")
        else { return nil }
        self.init(phase: phase, buzzCount: buzzCount, startedAt: startedAt, pausedTotal: pausedTotal,
                  pausedSince: pausedSince, problem: problem, sentAt: Date(timeIntervalSince1970: sentAt))
    }
}

public enum GuidedWalkCommand: String, Sendable {
    case start = "walk.start", pause = "walk.pause", resume = "walk.resume", stop = "walk.stop"

    public init?(message: [String: Any]) {
        guard let type = message["type"] as? String, let c = GuidedWalkCommand(rawValue: type) else { return nil }
        self = c
    }
}

public enum GuidedWalkAction: Sendable, Equatable { case start, pauseManual, resume, stop, none }

extension GuidedWalkCommand {
    /// What the phone does with this command in `phase` (spec 4).
    public func action(in phase: GuidedWalkPhase) -> GuidedWalkAction {
        switch (self, phase) {
        case (.start, .off): .start
        case (.pause, .walking), (.pause, .pausedAuto): .pauseManual
        case (.resume, .pausedAuto), (.resume, .pausedManual): .resume
        case (.stop, .starting), (.stop, .walking), (.stop, .pausedAuto), (.stop, .pausedManual): .stop
        default: .none
        }
    }
}
