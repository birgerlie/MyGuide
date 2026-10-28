import Foundation

public enum MotionActivity: String, Sendable, Codable { case stationary, walking, running, automotive, cycling, unknown }
public enum MotionConfidence: String, Sendable, Codable { case low, medium, high }

/// One activity report from the motion coprocessor. Reports arrive on change only.
public struct MotionReading: Sendable, Equatable {
    public var activity: MotionActivity
    public var confidence: MotionConfidence
    public var at: Date

    public init(activity: MotionActivity, confidence: MotionConfidence, at: Date) {
        self.activity = activity
        self.confidence = confidence
        self.at = at
    }

    /// Walking motion: walking or running, with confidence medium or high.
    public var isWalking: Bool {
        (activity == .walking || activity == .running) && confidence != .low
    }
}

public enum PauseTrigger: String, Sendable, Codable { case motion, gps }

public enum PauseChange: Sendable, Equatable {
    case pause(PauseTrigger, anchor: Coordinate?)
    case resume(PauseTrigger)
}

/// Decides when walking mode pauses and resumes (spec 5.2, 5.3). Pure: callers feed motion reports, fixes and ticks.
/// The motion state is kept as state (walking from a walking report until a report that is not walking), because
/// the motion source reports changes only.
public struct PauseDetector: Sendable {
    public static let stillDuration: TimeInterval = 180
    public static let stillRadius = 30.0
    public static let maxStillAccuracy = 50.0
    public static let resumeWalkingDuration: TimeInterval = 60
    public static let resumeDistance = 100.0
    public static let maxResumeAccuracy = 100.0

    public private(set) var isPaused = false
    public private(set) var pausedSince: Date?
    /// True after `hold()` until `release(now:)`: a manual pause. Every input then returns nil and changes nothing.
    public private(set) var isHeld = false

    private let motionAvailable: Bool
    private var walkingSince: Date?
    private var stillStart: Date
    private var anchor: Coordinate?
    private var pauseAnchor: Coordinate?

    public init(now: Date, motionAvailable: Bool) {
        self.stillStart = now
        self.motionAvailable = motionAvailable
    }

    /// Freezes the detector for a manual pause: motion, fixes and ticks give nil, so walking or moving cannot end the
    /// pause. `isPaused` and `pausedSince` stay as they were; motion reports still update the walking state, so
    /// `release(now:)` starts from the truth.
    public mutating func hold() { isHeld = true }

    /// Ends a hold or a pause by command: not held, not paused, a new still stretch from `now`, anchors cleared.
    public mutating func release(now: Date) {
        isHeld = false
        isPaused = false
        pausedSince = nil
        stillStart = now
        anchor = nil
        pauseAnchor = nil
    }

    public mutating func motion(isWalking: Bool, at: Date) -> PauseChange? {
        if isHeld {
            // Held: only the motion state is tracked (reports arrive on change only, so a missed one would be lost for
            // good). Nothing else changes and nothing is emitted.
            if isWalking {
                if walkingSince == nil { walkingSince = at }
            } else if walkingSince != nil {
                walkingSince = nil
                stillStart = at
            }
            return nil
        }
        if isWalking {
            if walkingSince == nil { walkingSince = at }
        } else if walkingSince != nil {
            walkingSince = nil
            stillStart = at
            anchor = nil
        }
        return check(now: at)
    }

    public mutating func fix(position: Coordinate, accuracy: Double, at: Date) -> PauseChange? {
        guard !isHeld else { return nil }
        if isPaused {
            if accuracy >= 0, accuracy <= Self.maxResumeAccuracy {
                if let pauseAnchor {
                    if GeoMath.distance(pauseAnchor, position) - accuracy > Self.resumeDistance {
                        return resume(.gps, now: at)
                    }
                } else {
                    pauseAnchor = position
                }
            }
        } else if accuracy >= 0, accuracy <= Self.maxStillAccuracy {
            if let current = anchor {
                if GeoMath.distance(current, position) > max(Self.stillRadius, accuracy) {
                    anchor = position
                    stillStart = at
                }
            } else {
                anchor = position
            }
        }
        return check(now: at)
    }

    public mutating func tick(now: Date) -> PauseChange? {
        guard !isHeld else { return nil }
        return check(now: now)
    }

    private mutating func check(now: Date) -> PauseChange? {
        if isPaused {
            if let walkingSince, now.timeIntervalSince(walkingSince) > Self.resumeWalkingDuration {
                return resume(.motion, now: now)
            }
            return nil
        }
        guard walkingSince == nil, now.timeIntervalSince(stillStart) >= Self.stillDuration else { return nil }
        isPaused = true
        pausedSince = now
        pauseAnchor = anchor
        return .pause(motionAvailable ? .motion : .gps, anchor: anchor)
    }

    private mutating func resume(_ trigger: PauseTrigger, now: Date) -> PauseChange {
        isPaused = false
        pausedSince = nil
        stillStart = now
        anchor = nil
        pauseAnchor = nil
        return .resume(trigger)
    }
}
