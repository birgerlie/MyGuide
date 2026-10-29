import Foundation

/// A tour being walked (tours spec 6, 7): the routed tour, when it started, the stops visited and skipped, and when the
/// walker reached its end. Stored as JSON in Application Support and restored at launch.
///
/// Stops are taken in plan order: `next` is the first stop neither visited nor skipped, and only it can be arrived at,
/// so two stops close together are taken one per fix.
public struct ActiveTour: Sendable, Equatable, Codable {
    /// Within this many metres of the next stop the walker has arrived (the buzz engine's due radius); the same for
    /// the end.
    public static let arrivalRadius = 60.0
    /// A tour started longer ago than this (12 h) is not restored: it was left behind, not paused.
    public static let maxAge: TimeInterval = 12 * 3600
    /// The routes' paths are simplified to this many metres when a tour starts (`GeoPolyline.simplified`): the stored
    /// file stays small (MapKit's walking routes carry a point every few metres), and the line drawn on the map looks
    /// the same.
    public static let pathTolerance = 3.0

    public var routed: RoutedTour
    public var startedAt: Date
    /// Stop ids, in the order they were visited.
    public var visited: [String]
    /// Stop ids, in the order they were skipped.
    public var skipped: [String]
    /// When the walker reached the end with every stop done; nil while the tour runs.
    public var finishedAt: Date?

    /// A tour starting now: nothing visited or skipped, and every leg's path simplified (`pathTolerance`).
    public init(routed: RoutedTour, startedAt: Date) {
        var simplified = routed
        for index in simplified.legs.indices {
            simplified.legs[index].path = GeoPolyline.simplified(simplified.legs[index].path,
                                                                 tolerance: Self.pathTolerance)
        }
        self.routed = simplified
        self.startedAt = startedAt
        self.visited = []
        self.skipped = []
        self.finishedAt = nil
    }

    /// The stops in walking order.
    public var stops: [TourStop] { routed.plan.stops }

    /// The first stop neither visited nor skipped; nil when every stop is done.
    public var next: TourStop? {
        stops.first { !isDone($0.id) }
    }

    /// Stops visited or skipped, of all the plan's stops. Ids that are not stops of the plan count for nothing.
    public var progress: (done: Int, total: Int) {
        (stops.filter { isDone($0.id) }.count, stops.count)
    }

    /// The visited stops that are stops of the plan.
    public var visitedCount: Int {
        stops.filter { visited.contains($0.id) }.count
    }

    /// True once the walker reached the end with every stop done (`reachEnd`).
    public var isFinished: Bool { finishedAt != nil }

    /// From the start to the finish in seconds, never negative; nil until finished.
    public var elapsedSeconds: Double? {
        finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// Marks `next` visited and returns it when `position` is within `arrivalRadius` of it (inclusive); else nil.
    /// Never more than one stop per call. Nothing after the finish.
    public mutating func arrive(at position: Coordinate, now: Date) -> TourStop? {
        guard !isFinished, let next, GeoMath.distance(position, next.coordinate) <= Self.arrivalRadius else {
            return nil
        }
        visited.append(next.id)
        return next
    }

    /// Skips `next`; nothing when every stop is done.
    public mutating func skipNext() {
        guard let next else { return }
        skipped.append(next.id)
    }

    /// Finishes the tour at `now` and returns true when every stop is done and `position` is within `arrivalRadius` of
    /// the end (the start again for a loop, the destination for A→B). False otherwise, and once finished.
    public mutating func reachEnd(at position: Coordinate, now: Date) -> Bool {
        guard !isFinished, next == nil,
              GeoMath.distance(position, routed.plan.end) <= Self.arrivalRadius else { return false }
        finishedAt = now
        return true
    }

    /// True when the tour started more than `maxAge` before `now`. A clock behind the start is not stale.
    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(startedAt) > Self.maxAge
    }

    private func isDone(_ id: String) -> Bool {
        visited.contains(id) || skipped.contains(id)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case routed, startedAt, visited, skipped, finishedAt }

    /// `routed` and `startedAt` are required; the lists and the finish may be missing (an empty list, not finished),
    /// so a file from a build that wrote fewer fields still restores. The paths are taken as stored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routed = try container.decode(RoutedTour.self, forKey: .routed)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        visited = try container.decodeIfPresent([String].self, forKey: .visited) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routed, forKey: .routed)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(visited, forKey: .visited)
        try container.encode(skipped, forKey: .skipped)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
    }
}

/// While a tour runs, places other than its stops buzz at most once per `interval` (tours spec 6), so the tour stays
/// the main thread. Every buzz counts as the last one, a stop's too; a stop itself is never held back.
public struct TourBuzzCadence: Sendable, Equatable {
    /// 3 minutes.
    public static let interval: TimeInterval = 180

    public private(set) var lastBuzzAt: Date?

    public init() {}

    /// True with no buzz yet, from `interval` after the last buzz (inclusive), and when `now` is before the last buzz
    /// (the clock was set back), so the rule never holds buzzes back longer than it means to.
    public func allows(at now: Date) -> Bool {
        guard let lastBuzzAt else { return true }
        let since = now.timeIntervalSince(lastBuzzAt)
        return since < 0 || since >= Self.interval
    }

    public mutating func noteBuzz(at now: Date) {
        lastBuzzAt = now
    }
}
