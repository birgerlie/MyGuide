import Foundation

/// Decides when a walk needs a fresh place fetch and holds the latest result.
/// Shared public services: refetch only after `refetchDistance`, retry a failure no sooner than `retryInterval`
/// (while the walk has no places, `emptyRetryInterval` doubling per consecutive failure up to `retryInterval`,
/// spec 19.6). A list whose OpenStreetMap part failed is retried
/// `NearbyList.osmFailedRetryAge` after it was fetched, without moving, so a walk does not go on with Wikipedia places
/// only for 250 m.
/// At the start of a run a stored list may stand in (`claimStaleList`, then `takeStaleList`) until the first fetch
/// comes back; it sets no centre, so it never holds a fetch back.
public struct PlaceFeed: Sendable {
    public static let refetchDistance = 250.0
    public static let retryInterval: TimeInterval = 60
    /// The retry delay after a first failure while the walk has no places, or only a stale list's; it doubles with
    /// each further consecutive failure, up to `retryInterval`: 15, 30, 60, 60 … s.
    public static let emptyRetryInterval: TimeInterval = 15

    public private(set) var places: [WalkingPlace] = []
    public private(set) var isFetching = false
    /// True while `places` came from a stale stored list rather than a fetch.
    public private(set) var placesAreStale = false
    private var lastCentre: Coordinate?
    private var lastFailure: Date?
    /// When the current places' list was fetched, if OpenStreetMap failed for it; nil otherwise.
    private var osmFailedAt: Date?
    /// True once a stale list has been claimed, taken or not: one claim per feed (per run).
    private var staleOffered = false
    /// Failed fetches since the last success (or since the start).
    private var consecutiveFailures = 0

    public init() {}

    /// True until a stale list has been claimed, while no fetch has come back and there are no places.
    public var wantsStaleList: Bool {
        !staleOffered && lastCentre == nil && places.isEmpty
    }

    /// The wait after a failed fetch as things stand: while there are no places or only stale ones,
    /// `emptyRetryInterval` · 2^(n − 1) for the n-th consecutive failure (n = 0 and 1 give 15 s), at most
    /// `retryInterval`; `retryInterval` otherwise. The nearby list is asked to hold off no longer than this either.
    public var failureRetryInterval: TimeInterval {
        guard places.isEmpty || placesAreStale else { return Self.retryInterval }
        // Capped before doubling, so a long outage cannot overflow the shift.
        let doublings = min(max(consecutiveFailures - 1, 0), 2)
        return min(Self.emptyRetryInterval * Double(1 << doublings), Self.retryInterval)
    }

    public func shouldFetch(at position: Coordinate, now: Date) -> Bool {
        if isFetching { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < failureRetryInterval { return false }
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
        consecutiveFailures = 0
        osmFailedAt = osmFailed ? min(fetchedAt ?? now, now) : nil
        isFetching = false
    }

    /// Claims the run's one stale list while `wantsStaleList`; true when this call claimed it. The caller then
    /// prepares the list (its facts may need a lookup) and hands it to `takeStaleList`; no second claim succeeds
    /// meanwhile.
    public mutating func claimStaleList() -> Bool {
        guard wantsStaleList else { return false }
        staleOffered = true
        return true
    }

    /// Takes the claimed stale list's places when they are not empty and still nothing has come back (no fetch
    /// succeeded, no places); returns whether it did. A fetch under way goes on and replaces them; no centre is set,
    /// so `shouldFetch` still asks for a fetch at the next fix when none runs.
    @discardableResult
    public mutating func takeStaleList(_ places: [WalkingPlace]) -> Bool {
        guard staleOffered, lastCentre == nil, self.places.isEmpty, !places.isEmpty else { return false }
        self.places = places
        placesAreStale = true
        return true
    }

    /// `claimStaleList` and `takeStaleList` at once, for a list that needs no preparing. The claim is used up even
    /// when the places are empty.
    @discardableResult
    public mutating func offerStaleList(_ places: [WalkingPlace]) -> Bool {
        claimStaleList() && takeStaleList(places)
    }

    /// Keeps the old places and holds off a retry for `failureRetryInterval`.
    public mutating func fetchFailed(now: Date) {
        lastFailure = now
        consecutiveFailures += 1
        isFetching = false
    }

    /// The caller stopped the fetch: no result, no retry delay.
    public mutating func fetchCancelled() {
        isFetching = false
    }
}
