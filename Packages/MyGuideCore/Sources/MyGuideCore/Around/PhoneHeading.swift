import Foundation

/// A vector in the local north / east / up frame (CoreMotion `xTrueNorthZVertical`, converted by the app).
public struct Vector3: Sendable, Equatable {
    public var north, east, up: Double
    public init(north: Double, east: Double, up: Double) {
        self.north = north
        self.east = east
        self.up = up
    }
}

public enum PhoneHeading {
    /// Shortest horizontal projection of top + back that still gives a stable direction (spec 6.4).
    static let minimumLength = 0.25

    /// Azimuth (0..<360, clockwise from true north) of the horizontal projection of top + back; nil when that
    /// projection is shorter than 0.25 (spec 6.4) or an input is not finite.
    public static func azimuth(top: Vector3, back: Vector3) -> Double? {
        let n = top.north + back.north
        let e = top.east + back.east
        guard n.isFinite, e.isFinite, (n * n + e * e).squareRoot() >= minimumLength else { return nil }
        var degrees = atan2(e, n) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        // -1e-17 + 360 rounds to 360.0; keep the range half-open.
        return degrees >= 360 ? 0 : degrees
    }
}

/// Circular exponential smoothing of compass headings (spec 6.4).
public struct HeadingSmoother: Sendable {
    public static let timeConstant: TimeInterval = 0.5

    private var heading: Double?
    private var last: Date?

    public init() {}

    /// α = 1 − e^(−Δt/τ); the heading moves α of the way along the shortest arc to the new sample, so 355 → 5 goes
    /// through north. The first sample passes through; a non-finite sample, or one not newer than the last, changes nothing.
    public mutating func add(_ heading: Double, at: Date) -> Double {
        guard heading.isFinite else { return self.heading ?? 0 }
        let sample = Self.normalised(heading)
        guard let previous = self.heading, let last else {
            self.heading = sample
            self.last = at
            return sample
        }
        let dt = at.timeIntervalSince(last)
        guard dt > 0 else { return previous }
        let alpha = 1 - exp(-dt / Self.timeConstant)
        // Exactly opposite headings: the arc is ambiguous, PlaceSelector.offset resolves it to +180 (clockwise).
        let arc = PlaceSelector.offset(heading: previous, bearing: sample)
        let next = Self.normalised(previous + alpha * arc)
        self.heading = next
        self.last = at
        return next
    }

    private static func normalised(_ degrees: Double) -> Double {
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r >= 360 ? 0 : r
    }
}
