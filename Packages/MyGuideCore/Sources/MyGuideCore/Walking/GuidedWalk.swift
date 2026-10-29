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

/// The `type` of the watch–phone messages outside the guided walk (WatchConnectivity dictionaries). Builds on either
/// side may be older than the other, so the strings never change.
public enum WatchMessage {
    /// Watch → phone, from the Action button's «Tell me» (`TellMeIntent`): the phone's Walking check plays its test
    /// tone. It does not tell a story.
    public static let checkTell = "check.tell"
    /// Watch → phone from the watch's check screen; the phone answers `pong` at once.
    public static let ping = "ping"
    public static let pong = "pong"
}

/// A buzz the phone sends straight to the watch during a guided walk (spec 18), beside its notification: iOS forwards
/// a notification to the watch only while the iPhone is locked. The watch plays a haptic and shows the place with
/// «Lytt», which sends `tellMessage(id:)` back.
public struct GuidedWalkBuzz: Sendable, Equatable {
    public static let messageType = "buzz"
    /// The watch's «Lytt» on a buzz it showed: the phone tells that buzz's story, as the notification's Listen does.
    public static let tellMessageType = "buzz.tell"
    /// A buzz older than this (seconds) is not shown: one queued with `transferUserInfo` can arrive long after it was
    /// sent, when the place is far behind.
    public static let maxAge: TimeInterval = 120

    public var id: UUID
    /// The place name.
    public var name: String
    /// Distance and direction ("50 m til høyre"), in the iPhone's screen language.
    public var line: String
    /// The phone's clock when the buzz was sent.
    public var sentAt: Date

    public init(id: UUID, name: String, line: String, sentAt: Date) {
        self.id = id
        self.name = name
        self.line = line
        self.sentAt = sentAt
    }

    /// A property-list message for WatchConnectivity; `sentAt` is seconds since 1970.
    public var message: [String: Any] {
        ["type": Self.messageType, "id": id.uuidString, "name": name, "line": line,
         "sentAt": sentAt.timeIntervalSince1970]
    }

    /// Nil when the type is not `buzz`, or a field is missing, of the wrong type, or (the id) not a UUID.
    public init?(message: [String: Any]) {
        guard message["type"] as? String == Self.messageType,
              let rawID = message["id"] as? String, let id = UUID(uuidString: rawID),
              let name = message["name"] as? String,
              let line = message["line"] as? String,
              let sentAt = message["sentAt"] as? Double
        else { return nil }
        self.init(id: id, name: name, line: line, sentAt: Date(timeIntervalSince1970: sentAt))
    }

    /// True while the buzz is at most `maxAge` old at `now`. A `sentAt` slightly ahead of the watch's clock counts as
    /// fresh.
    public func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(sentAt) <= Self.maxAge
    }

    /// The watch's «Lytt» for the buzz `id`.
    public static func tellMessage(id: UUID) -> [String: Any] {
        ["type": tellMessageType, "id": id.uuidString]
    }

    /// The phone's buzz notification category and the `userInfo` key of its buzz id (`BuzzNotifier`).
    public static let notificationCategory = "BUZZ"
    public static let notificationIDKey = "buzzID"
    /// The buzz notification's actions: Listen (the phone tells the story) and Skip. Shared by the phone, which
    /// registers them, and the watch, which answers a Listen tapped on a forwarded notification.
    public static let notificationTellAction = "TELL_ME"
    public static let notificationSkipAction = "SKIP"

    /// The buzz id of a buzz notification; nil for another category (the offer of the next part carries the same id,
    /// and must not be taken for the buzz), a missing id or one that is not a UUID.
    public static func notificationBuzzID(category: String, userInfo: [AnyHashable: Any]) -> UUID? {
        guard category == notificationCategory, let raw = userInfo[notificationIDKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// The buzz id of a `buzz.tell` message; nil for any other message or an id that is not a UUID.
    public static func tellID(in message: [String: Any]) -> UUID? {
        guard message["type"] as? String == tellMessageType, let raw = message["id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

/// The buzz ids the watch has shown, each remembered for `window` seconds, so the same buzz is felt once: when its
/// notification arrives too, or the message comes twice.
public struct RecentBuzzIDs: Sendable {
    /// 10 minutes.
    public static let defaultWindow: TimeInterval = 600

    public let window: TimeInterval
    private var shownAt: [UUID: Date] = [:]

    public init(window: TimeInterval = defaultWindow) {
        self.window = window
    }

    /// Remembers `id` as shown at `now` and returns true, unless it is still remembered from an earlier time, when it
    /// returns false and keeps the earlier time. Forgets the ids whose window has passed.
    public mutating func remember(_ id: UUID, now: Date) -> Bool {
        shownAt = shownAt.filter { now.timeIntervalSince($0.value) < window }
        guard shownAt[id] == nil else { return false }
        shownAt[id] = now
        return true
    }

    /// True when `id` was shown less than `window` seconds before `now`.
    public func contains(_ id: UUID, now: Date) -> Bool {
        guard let at = shownAt[id] else { return false }
        return now.timeIntervalSince(at) < window
    }

    /// How many ids are held; for tests.
    var count: Int { shownAt.count }
}
