import Foundation

/// Notices that the owner has stopped on a walk: they have stayed within 25 m of one spot for 60 s, moving slower
/// than 0.5 m/s. The spot is the running mean of the fixes since the owner last moved. A single fix more than 25 m
/// away is held back; only a second consecutive one (or a fix back near the spot) decides whether it was GPS jitter
/// or a real move. A held-back fix older than 30 s is dropped unused, so a gap in the fixes never dates a new stay
/// back to before the owner got there. A stop is reported once per anchor, and not again within 100 m of an earlier
/// stop on this trip.
public struct StopDetector: Sendable {
    public static let radius = 25.0, duration: TimeInterval = 60, maxSpeed = 0.5
    /// A held-back fix older than this (seconds) when the next fix arrives is dropped: neither jitter nor a move.
    public static let pendingTimeout: TimeInterval = 30
    public static let repeatRadius = 100.0
    /// Same limit as `WalkingFix.isUsable`, so the two cannot drift apart.
    public static let maxFixAccuracy = BuzzEngine.maxFixAccuracy

    private var previousStops: [Coordinate]
    /// Mean of the fixes absorbed since the anchor. `count == 0` means there is no anchor yet.
    private var mean = Coordinate(latitude: 0, longitude: 0)
    private var count = 0
    private var anchorAt = Date.distantPast
    private var fired = false
    /// The one fix more than `radius` from the mean, waiting for a second one to confirm a move.
    private var pending: (position: Coordinate, at: Date)?

    public init(previousStops: [Coordinate]) {
        self.previousStops = previousStops
    }

    /// Feeds one location fix. Returns the stop spot (the running mean) the first time the owner has stayed put for
    /// `duration`, and nil otherwise. Fixes that `WalkingFix.isUsable` rejects are ignored entirely.
    public mutating func update(position: Coordinate, accuracy: Double, speed: Double, now: Date) -> Coordinate? {
        guard WalkingFix.isUsable(accuracy: accuracy) else { return nil }
        // After a gap the held-back fix says nothing about this one; re-anchoring at it would date the stay back.
        if let held = pending, now.timeIntervalSince(held.at) > Self.pendingTimeout { pending = nil }

        // A known speed above the limit means the owner is walking: the stay starts over at this fix.
        // A negative speed means unknown and does not count as moving; NaN fails both comparisons.
        if speed >= 0 && speed > Self.maxSpeed {
            restart(at: position, now: now)
            return nil
        }
        guard count > 0 else {
            restart(at: position, now: now)
            return nil
        }

        if GeoMath.distance(mean, position) <= Self.radius {
            // Near the spot: any held-back fix was jitter after all, so it joins the mean too.
            if let held = pending {
                absorb(held.position)
                pending = nil
            }
            absorb(position)
        } else if let held = pending {
            // Second fix in a row away from the spot: the owner has moved. The new stay starts at the first of them.
            restart(at: held.position, now: held.at)
            absorb(position)
            pending = nil
        } else {
            pending = (position, now)
            return nil
        }

        guard !fired, now.timeIntervalSince(anchorAt) >= Self.duration else { return nil }
        guard !previousStops.contains(where: { GeoMath.distance($0, mean) <= Self.repeatRadius }) else { return nil }

        fired = true
        previousStops.append(mean)
        return mean
    }

    private mutating func restart(at position: Coordinate, now: Date) {
        mean = position
        count = 1
        anchorAt = now
        fired = false
        pending = nil
    }

    /// Folds one fix into the running mean. A fix equal to the mean leaves it bit-for-bit unchanged.
    private mutating func absorb(_ position: Coordinate) {
        count += 1
        let n = Double(count)
        mean = Coordinate(
            latitude: mean.latitude + (position.latitude - mean.latitude) / n,
            longitude: mean.longitude + (position.longitude - mean.longitude) / n
        )
    }
}
