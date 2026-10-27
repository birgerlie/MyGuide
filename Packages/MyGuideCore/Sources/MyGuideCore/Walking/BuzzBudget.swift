import Foundation

/// The owner's buzz allowance while walking: an average per hour, refilled continuously and held at most `capacity`.
/// Stored as tokens plus the instant they were last brought up to date, so reads never need a timer.
public struct BuzzBudget: Sendable, Equatable {
    public static let capacity = 3.0
    public static let perHourRange = 5...60
    public static let defaultPerHour = 20

    public private(set) var perHour: Int
    private var tokens: Double
    private var accruedAt: Date

    /// A new budget starts with exactly one buzz available.
    public init(perHour: Int, now: Date) {
        self.perHour = min(max(perHour, Self.perHourRange.lowerBound), Self.perHourRange.upperBound)
        self.tokens = 1
        self.accruedAt = now
    }

    /// Buzzes available at `now`: stored tokens plus what has refilled since, never above `capacity`.
    /// A clock earlier than the last accrual refills nothing.
    public func available(at now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(accruedAt))
        // Multiply before dividing so whole-second boundaries (e.g. 180 s at 20/h) land on exact values.
        return min(Self.capacity, tokens + elapsed * Double(perHour) / 3600)
    }

    public func canSpend(at now: Date) -> Bool {
        available(at: now) >= 1
    }

    /// Takes one buzz if one is available. Returns false and changes nothing otherwise.
    public mutating func spend(at now: Date) -> Bool {
        accrue(to: now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Changes the average rate (clamped into `perHourRange`). Time up to `now` accrues at the old rate first.
    public mutating func setPerHour(_ value: Int, at now: Date) {
        accrue(to: now)
        perHour = min(max(value, Self.perHourRange.lowerBound), Self.perHourRange.upperBound)
    }

    /// Folds refill up to `now` into `tokens`. Does nothing when `now` is not later than `accruedAt`,
    /// so the accrual point never moves backwards.
    private mutating func accrue(to now: Date) {
        guard now > accruedAt else { return }
        tokens = available(at: now)
        accruedAt = now
    }
}
