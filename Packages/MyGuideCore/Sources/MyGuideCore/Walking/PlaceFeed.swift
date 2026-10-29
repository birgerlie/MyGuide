import Foundation

/// Decides when a walk needs a fresh place fetch and holds the latest result.
/// Shared public services: refetch only after `refetchDistance`, retry a failure no sooner than `retryInterval`.
/// A list whose OpenStreetMap part failed is retried `NearbyList.osmFailedRetryAge` after it was fetched, without
/// moving, so a walk does not go on with Wikipedia places only for 250 m.
public struct PlaceFeed: Sendable {
    public static let refetchDistance = 250.0
    public static let retryInterval: TimeInterval = 60

    public private(set) var places: [WalkingPlace] = []
    public private(set) var isFetching = false
    private var lastCentre: Coordinate?
    private var lastFailure: Date?
    /// When the current places' list was fetched, if OpenStreetMap failed for it; nil otherwise.
    private var osmFailedAt: Date?

    public init() {}

    public func shouldFetch(at position: Coordinate, now: Date) -> Bool {
        if isFetching { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryInterval { return false }
        guard let lastCentre else { return true }
        if let osmFailedAt, now.timeIntervalSince(osmFailedAt) >= NearbyList.osmFailedRetryAge { return true }
        return GeoMath.distance(lastCentre, position) >= Self.refetchDistance
    }

    public mutating func fetchStarted(now: Date) {
        isFetching = true
    }

    /// `osmFailed` and `fetchedAt` describe the list the places came from (`fetchedAt` defaults to `now`; a list
    /// dated after `now`, the clock set back, counts from `now`).
    public mutating func fetchSucceeded(_ places: [WalkingPlace], at center: Coordinate, now: Date,
                                        osmFailed: Bool = false, fetchedAt: Date? = nil) {
        self.places = places
        lastCentre = center
        lastFailure = nil
        osmFailedAt = osmFailed ? min(fetchedAt ?? now, now) : nil
        isFetching = false
    }

    /// Keeps the old places and holds off a retry for `retryInterval`.
    public mutating func fetchFailed(now: Date) {
        lastFailure = now
        isFetching = false
    }

    /// The caller stopped the fetch: no result, no retry delay.
    public mutating func fetchCancelled() {
        isFetching = false
    }
}
