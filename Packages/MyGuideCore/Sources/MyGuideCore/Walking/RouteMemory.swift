import Foundation

/// Where the walker came from, for the story prompt ("Stortorvet, 3 min ago, 220 m behind").
public struct CameFrom: Sendable, Equatable {
    public var street: String
    /// Whole minutes, rounded down.
    public var minutesAgo: Int
    /// Straight line, metres.
    public var distance: Double
    /// From the current position to that point.
    public var bearing: Double
    /// The current street, when it covered the whole stretch since then: set only with at least one newer successful
    /// lookup, and every newer lookup (failed or without a street name counts as unknown) on the current street.
    public var along: String?

    public init(street: String, minutesAgo: Int, distance: Double, bearing: Double, along: String?) {
        self.street = street
        self.minutesAgo = minutesAgo
        self.distance = distance
        self.bearing = bearing
        self.along = along
    }
}

/// What a story request knows about the walk: the resolved address, the direction and the stretch behind.
public struct WalkContext: Sendable, Equatable {
    /// nil = lookup failed.
    public var address: Address?
    /// Walking direction; nil = unknown.
    public var bearing: Double?
    /// Current street.
    public var street: String?
    public var cameFrom: CameFrom?

    public init(address: Address?, bearing: Double?, street: String?, cameFrom: CameFrom?) {
        self.address = address
        self.bearing = bearing
        self.street = street
        self.cameFrom = cameFrom
    }
}

/// Remembers the recent track and the street lookups made along it, so a story can say which way the walker is
/// heading and where they came from. Positions along the walk are "path offsets": cumulative path length over the
/// samples, kept per sample so they survive trimming.
public struct RouteMemory: Sendable {
    public static let bearingPath = 100.0, minimumBearingPath = 20.0
    public static let lookupSpacing = 100.0
    public static let windowPath = 300.0, windowTime: TimeInterval = 300
    public static let addressReuseDistance = 50.0
    /// A lookup closer than this (path) to the newest sample is "here", not "came from".
    static let minimumCameFromPath = 30.0
    static let keepPath = 400.0, keepTime: TimeInterval = 600
    /// Path offsets are sums of haversine distances; boundaries compare with this slack.
    private static let slack = 1e-6

    private struct Point: Sendable {
        var sample: TrackSample
        var offset: Double
    }

    private struct Lookup: Sendable {
        var address: Address?
        var at: Date
        var position: Coordinate
        var offset: Double
        var street: String? { GuideText.streetName(fromAddressLine: address?.line) }
    }

    private var points: [Point] = []
    private var lookups: [Lookup] = []

    public init() {}

    public mutating func add(_ sample: TrackSample) {
        let offset = points.last.map { $0.offset + GeoMath.distance($0.sample.coordinate, sample.coordinate) } ?? 0
        points.append(Point(sample: sample, offset: offset))
        trim()
    }

    /// Bearing from the sample `bearingPath` back along the path (or the oldest, when the path is at least
    /// `minimumBearingPath`) to the newest sample; nil below that.
    public var walkingBearing: Double? {
        guard let newest = points.last, let oldest = points.first else { return nil }
        guard newest.offset - oldest.offset >= Self.minimumBearingPath - Self.slack else { return nil }
        let target = newest.offset - Self.bearingPath + Self.slack
        let from = points.last { $0.offset <= target } ?? oldest
        return GeoMath.bearing(from: from.sample.coordinate, to: newest.sample.coordinate)
    }

    /// True when there are samples and no lookup yet, or the path since the last lookup is ≥ `lookupSpacing`.
    public var needsStreetLookup: Bool {
        guard let newest = points.last else { return false }
        guard let last = lookups.last else { return true }
        return newest.offset - last.offset >= Self.lookupSpacing - Self.slack
    }

    /// Records a lookup at the newest sample. nil (failed) still resets the spacing: skipped, not retried.
    public mutating func recordLookup(_ address: Address?, at: Date) {
        guard let newest = points.last else { return }
        lookups.append(Lookup(address: address, at: at, position: newest.sample.coordinate, offset: newest.offset))
        trim()
    }

    /// The newest looked-up address within `addressReuseDistance` of `position`.
    public func recentAddress(near position: Coordinate) -> Address? {
        for lookup in lookups.reversed() {
            guard let address = lookup.address else { continue }
            if GeoMath.distance(lookup.position, position) <= Self.addressReuseDistance { return address }
        }
        return nil
    }

    /// `address` is the one the caller resolved for the current spot; its street is the current street.
    public func context(address: Address?, course: Double?, now: Date) -> WalkContext {
        var bearing = walkingBearing
        if bearing == nil, let course, course.isFinite, course >= 0 { bearing = course }
        let street = GuideText.streetName(fromAddressLine: address?.line)
        return WalkContext(address: address, bearing: bearing, street: street,
                           cameFrom: cameFrom(currentStreet: street, now: now))
    }

    public mutating func reset() {
        points.removeAll()
        lookups.removeAll()
    }

    private func cameFrom(currentStreet: String?, now: Date) -> CameFrom? {
        guard let newest = points.last else { return nil }
        let index = lookups.firstIndex { lookup in
            guard lookup.street != nil else { return false }
            let path = newest.offset - lookup.offset
            return path >= Self.minimumCameFromPath - Self.slack
                && GeoMath.distance(newest.sample.coordinate, lookup.position) >= Self.minimumCameFromPath
                && path <= Self.windowPath + Self.slack
                && max(0, now.timeIntervalSince(lookup.at)) <= Self.windowTime
        }
        guard let index, let street = lookups[index].street else { return nil }
        let lookup = lookups[index]
        let age = max(0, now.timeIntervalSince(lookup.at))
        var along: String?
        let newer = lookups[(index + 1)...]
        if let currentStreet, currentStreet != street,
           newer.contains(where: { $0.address != nil }),
           newer.allSatisfy({ $0.street == currentStreet }) {
            along = currentStreet
        }
        return CameFrom(street: street, minutesAgo: Int(age / 60),
                        distance: GeoMath.distance(newest.sample.coordinate, lookup.position),
                        bearing: GeoMath.bearing(from: newest.sample.coordinate, to: lookup.position),
                        along: along)
    }

    /// Drops samples more than `keepTime` or `keepPath` behind the newest, and lookups outside that window.
    /// The last lookup (spacing) and the last successful one (address reuse) always stay.
    private mutating func trim() {
        guard let newest = points.last else { return }
        func stale(_ at: Date, _ offset: Double) -> Bool {
            newest.sample.at.timeIntervalSince(at) > Self.keepTime || newest.offset - offset > Self.keepPath
        }
        points.removeAll { stale($0.sample.at, $0.offset) }
        let lastIndex = lookups.count - 1
        let lastSuccess = lookups.lastIndex { $0.address != nil }
        var kept: [Lookup] = []
        for (index, lookup) in lookups.enumerated() {
            if index == lastIndex || index == lastSuccess || !stale(lookup.at, lookup.offset) { kept.append(lookup) }
        }
        lookups = kept
    }
}
