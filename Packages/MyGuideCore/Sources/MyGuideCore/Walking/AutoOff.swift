import Foundation

public enum AutoOffReason: Sendable, Equatable { case timeLimit, lowBattery }

/// When walking mode turns itself off (design 7.6): after four hours, or when the battery runs low.
public enum AutoOff {
    public static let maxDuration: TimeInterval = 14_400
    public static let minBattery: Float = 0.15

    /// `batteryLevel` is `UIDevice.batteryLevel`: 0…1, or a negative number when unknown (never a reason).
    public static func reason(startedAt: Date, now: Date, batteryLevel: Float) -> AutoOffReason? {
        if now.timeIntervalSince(startedAt) >= maxDuration { return .timeLimit }
        if batteryLevel >= 0, batteryLevel < minBattery { return .lowBattery }
        return nil
    }

    public static func message(_ reason: AutoOffReason) -> String {
        switch reason {
        case .timeLimit: "Walking mode turned off after 4 hours."
        case .lowBattery: "Walking mode turned off: battery below 15%."
        }
    }
}
