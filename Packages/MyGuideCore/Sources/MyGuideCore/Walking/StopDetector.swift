import Foundation

/// Notices that the owner has stopped on a walk: they have stayed within 25 m of one spot for 60 s, moving slower
/// than 0.5 m/s. A stop is reported once per anchor, and not again within 100 m of an earlier stop on this trip.
public struct StopDetector: Sendable {
    public static let radius = 25.0, duration: TimeInterval = 60, maxSpeed = 0.5
    public static let repeatRadius = 100.0, maxFixAccuracy = 50.0

    private var previousStops: [Coordinate]
    private var anchor: Coordinate?
    private var anchorAt = Date.distantPast
    private var fired = false

    public init(previousStops: [Coordinate]) {
        self.previousStops = previousStops
    }

    /// Feeds one location fix. Returns the stop spot (the anchor) the first time the owner has stayed put for
    /// `duration`, and nil otherwise. Fixes with an unusable accuracy are ignored entirely.
    public mutating func update(position: Coordinate, accuracy: Double, speed: Double, now: Date) -> Coordinate? {
        guard accuracy.isFinite, accuracy >= 0, accuracy <= Self.maxFixAccuracy else { return nil }

        // A negative speed means unknown and does not count as moving; NaN fails both comparisons.
        let movedAway = anchor.map { GeoMath.distance($0, position) > Self.radius } ?? true
        let moving = speed >= 0 && speed > Self.maxSpeed
        if movedAway || moving {
            anchor = position
            anchorAt = now
            fired = false
        }

        guard !fired, let anchor, now.timeIntervalSince(anchorAt) >= Self.duration else { return nil }
        guard !previousStops.contains(where: { GeoMath.distance($0, anchor) <= Self.repeatRadius }) else { return nil }

        fired = true
        previousStops.append(anchor)
        return anchor
    }
}
