import Foundation

/// One walked leg of a tour: routed by the app's walking router, or a straight line when routing failed or the request
/// cap was spent.
public struct RoutedLeg: Sendable, Equatable, Codable {
    public var seconds: Double
    public var metres: Double
    /// The line to draw, from the leg's start to its end.
    public var path: [Coordinate]
    /// A straight-line stand-in (spec 5: «Omtrentlig rute»), not a walking route.
    public var approximate: Bool

    public init(seconds: Double, metres: Double, path: [Coordinate], approximate: Bool) {
        self.seconds = seconds
        self.metres = metres
        self.path = path
        self.approximate = approximate
    }
}

/// A plan checked against walking routes: `legs` has one leg per gap (start → first stop, …, last stop → end).
public struct RoutedTour: Sendable, Equatable, Codable {
    public var plan: TourPlan
    public var legs: [RoutedLeg]
    /// Some leg is a straight-line stand-in.
    public var approximate: Bool

    public init(plan: TourPlan, legs: [RoutedLeg], approximate: Bool) {
        self.plan = plan
        self.legs = legs
        self.approximate = approximate
    }

    /// The legs' seconds + 240 s per stop.
    public var totalSeconds: Double {
        legs.reduce(0) { $0 + $1.seconds } + TourPlanner.dwellSeconds * Double(plan.stops.count)
    }

    /// The legs' metres.
    public var totalMetres: Double {
        legs.reduce(0) { $0 + $1.metres }
    }
}

/// Checks a plan against walking routes (spec 5, «Verification»).
public enum TourRouting {
    /// Fits a plan: routes every leg via `leg`, then, while the total exceeds the budget × 1.10 and stops remain, drops
    /// the worst stop (`TourPlanner.dropWorst` over the current leg seconds) and routes only the one leg that joins its
    /// neighbours; every other leg is kept. Legs are routed one at a time, in order.
    ///
    /// At most `maxRequests` calls to `leg` (a negative cap counts as 0), and none once the caller is cancelled. A leg
    /// that is not requested for either reason, or whose answer is nil or has seconds or metres that are not finite and
    /// non-negative, becomes an approximate straight leg: the estimate's seconds, straight metres × the detour factor,
    /// and the path [from, to]. A routed leg with an empty path gets [from, to]. A leg between equal points is 0 s and
    /// 0 m without a request. The tour is approximate when any leg is.
    public static func fit(_ plan: TourPlan, maxRequests: Int,
                           leg: @Sendable (Coordinate, Coordinate) async -> RoutedLeg?) async -> RoutedTour {
        var requestsLeft = max(0, maxRequests)

        func route(_ from: Coordinate, _ to: Coordinate) async -> RoutedLeg {
            if from == to { return RoutedLeg(seconds: 0, metres: 0, path: [from], approximate: false) }
            guard requestsLeft > 0, !Task.isCancelled else { return straight(from, to) }
            requestsLeft -= 1
            guard var routed = await leg(from, to), isUsable(routed) else { return straight(from, to) }
            if routed.path.isEmpty { routed.path = [from, to] }
            return routed
        }

        var current = plan
        let points = [plan.start] + plan.stops.map(\.coordinate) + [plan.end]
        var legs: [RoutedLeg] = []
        for (from, to) in zip(points, points.dropFirst()) {
            legs.append(await route(from, to))
        }

        while !current.stops.isEmpty,
              total(legs, stops: current.stops.count) > current.budgetSeconds * (1 + TourPlanner.overrunAllowance) {
            let next = TourPlanner.dropWorst(current, legSeconds: legs.map(\.seconds))
            guard let k = removedIndex(from: current.stops, to: next.stops) else { break }
            // Stop k sat between legs k and k + 1; one leg from its predecessor to its successor replaces both.
            let from = k == 0 ? current.start : current.stops[k - 1].coordinate
            let to = k == current.stops.count - 1 ? current.end : current.stops[k + 1].coordinate
            legs.replaceSubrange(k...(k + 1), with: [await route(from, to)])
            current = next
        }

        return RoutedTour(plan: current, legs: legs, approximate: legs.contains(where: \.approximate))
    }

    // MARK: - Internals

    private static func total(_ legs: [RoutedLeg], stops: Int) -> Double {
        legs.reduce(0) { $0 + $1.seconds } + TourPlanner.dwellSeconds * Double(stops)
    }

    private static func isUsable(_ leg: RoutedLeg) -> Bool {
        leg.seconds.isFinite && leg.seconds >= 0 && leg.metres.isFinite && leg.metres >= 0
    }

    /// The straight-line stand-in: the planner's estimate, and metres to match it (seconds × walking speed).
    private static func straight(_ from: Coordinate, _ to: Coordinate) -> RoutedLeg {
        RoutedLeg(seconds: TourPlanner.estimatedLegSeconds(from: from, to: to),
                  metres: GeoMath.distance(from, to) * TourPlanner.detourFactor, path: [from, to], approximate: true)
    }

    /// The index of the one stop `dropWorst` removed (it keeps the order of the rest), or nil if it removed none.
    private static func removedIndex(from before: [TourStop], to after: [TourStop]) -> Int? {
        guard after.count == before.count - 1 else { return nil }
        return after.indices.first { before[$0] != after[$0] } ?? before.count - 1
    }
}
