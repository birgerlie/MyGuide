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

/// An attitude rotation matrix as Core Motion gives it (`CMRotationMatrix`), relative to the `xTrueNorthZVertical`
/// reference frame (X north, Y west, Z up). It maps reference vectors to device coordinates (v_device = R · v_ref), so
/// row i is device axis i expressed in the reference frame.
public struct RotationMatrix: Sendable, Equatable {
    public var m11, m12, m13: Double
    public var m21, m22, m23: Double
    public var m31, m32, m33: Double

    public init(m11: Double, m12: Double, m13: Double,
                m21: Double, m22: Double, m23: Double,
                m31: Double, m32: Double, m33: Double) {
        self.m11 = m11; self.m12 = m12; self.m13 = m13
        self.m21 = m21; self.m22 = m22; self.m23 = m23
        self.m31 = m31; self.m32 = m32; self.m33 = m33
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

    /// The phone heading of an attitude in the `xTrueNorthZVertical` frame: top edge = device +Y = row 2, back =
    /// device −Z = −row 3, converted from (north, west, up) to (north, east, up); then `azimuth(top:back:)`.
    public static func azimuth(rotation r: RotationMatrix) -> Double? {
        azimuth(top: Vector3(north: r.m21, east: -r.m22, up: r.m23),
                back: Vector3(north: -r.m31, east: r.m32, up: -r.m33))
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
        // Exactly opposite headings: the arc is ambiguous, GeoMath.signedOffset resolves it to +180 (clockwise).
        let arc = GeoMath.signedOffset(from: previous, to: sample)
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
