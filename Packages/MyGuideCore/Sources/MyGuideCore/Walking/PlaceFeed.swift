import Foundation

/// Decides when a walk needs a fresh place fetch and holds the latest result.
/// Shared public services: refetch only after `refetchDistance`, retry a failure no sooner than `retryInterval`
/// (`emptyRetryInterval` while the walk has no places, spec 19.6). A list whose OpenStreetMap part failed is retried
/// `NearbyList.osmFailedRetryAge` after it was fetched, without moving, so a walk does not go on with Wikipedia places
/// only for 250 m.
/// At the start of a run a stored list may stand in (`offerStaleList`) until the first fetch comes back; it sets no
/// centre, so it never holds a fetch back.
public struct PlaceFeed: Sendable {
    public static let refetchDistance = 250.0
    public static let retryInterval: TimeInterval = 60
    /// The retry delay after a failure while the walk has no places, or only a stale list's.
    public static let emptyRetryInterval: TimeInterval = 15

    public private(set) var places: [WalkingPlace] = []
    public private(set) var isFetching = false
    /// True while `places` came from a stale stored list rather than a fetch.
    public private(set) var placesAreStale = false
    private var lastCentre: Coordinate?
    private var lastFailure: Date?
    /// When the current places' list was fetched, if OpenStreetMap failed for it; nil otherwise.
    private var osmFailedAt: Date?
    /// True once a stale list has been offered, taken or not: one offer per feed (per run).
    private var staleOffered = false

    public init() {}

    /// True until a stale list has been offered, while no fetch has come back and there are no places.
    public var wantsStaleList: Bool {
        !staleOffered && lastCentre == nil && places.isEmpty
    }

    public func shouldFetch(at position: Coordinate, now: Date) -> Bool {
        if isFetching { return false }
        let retry = places.isEmpty || placesAreStale ? Self.emptyRetryInterval : Self.retryInterval
        if let lastFailure, now.timeIntervalSince(lastFailure) < retry { return false }
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
        placesAreStale = false
        lastCentre = center
        lastFailure = nil
        osmFailedAt = osmFailed ? min(fetchedAt ?? now, now) : nil
        isFetching = false
    }

    /// Takes a stale stored list's places while `wantsStaleList` and they are not empty; returns whether it did. The
    /// offer is used up either way. A fetch under way goes on and replaces them; no centre is set, so `shouldFetch`
    /// still asks for a fetch at the next fix when none runs.
    @discardableResult
    public mutating func offerStaleList(_ places: [WalkingPlace]) -> Bool {
        let wanted = wantsStaleList
        staleOffered = true
        guard wanted, !places.isEmpty else { return false }
        self.places = places
        placesAreStale = true
        return true
    }

    /// Keeps the old places and holds off a retry for `retryInterval`, or `emptyRetryInterval` while there are no
    /// places or only stale ones.
    public mutating func fetchFailed(now: Date) {
        lastFailure = now
        isFetching = false
    }

    /// The caller stopped the fetch: no result, no retry delay.
    public mutating func fetchCancelled() {
        isFetching = false
    }
}
