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

    /// A routed leg of `metres` along `path`, timed at the tours' walking speed (`TourArea.walkingSpeed`, 1.3 m/s)
    /// rather than the router's own, so routed and estimated legs use one speed. Metres that are not finite and
    /// non-negative give seconds that `TourRouting.fit` rejects, so such a leg becomes a straight one.
    public static func walked(metres: Double, path: [Coordinate]) -> RoutedLeg {
        RoutedLeg(seconds: metres / TourArea.walkingSpeed, metres: metres, path: path, approximate: false)
    }
}

/// A plan checked against walking routes: `legs` has one leg per gap (start → first stop, …, last stop → end).
public struct RoutedTour: Sendable, Equatable, Codable {
    public var plan: TourPlan
    public var legs: [RoutedLeg]

    public init(plan: TourPlan, legs: [RoutedLeg]) {
        self.plan = plan
        self.legs = legs
    }

    /// Some leg is a straight-line stand-in.
    public var approximate: Bool { legs.contains { $0.approximate } }

    /// The legs' seconds + 240 s per stop.
    public var totalSeconds: Double {
        legs.reduce(0) { $0 + $1.seconds } + TourPlanner.dwellSeconds * Double(plan.stops.count)
    }

    /// The legs' metres.
    public var totalMetres: Double {
        legs.reduce(0) { $0 + $1.metres }
    }

    private enum CodingKeys: String, CodingKey { case plan, legs }

    /// Decodes `plan` and `legs`; an `approximate` field stored by an earlier version is ignored, since the legs decide.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decode(TourPlan.self, forKey: .plan)
        legs = try container.decode([RoutedLeg].self, forKey: .legs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(plan, forKey: .plan)
        try container.encode(legs, forKey: .legs)
    }
}

/// Checks a plan against walking routes (spec 5, «Verification»).
public enum TourRouting {
    /// At most this many requests are in flight while the first legs are routed.
    public static let maxConcurrentRequests = 4

    /// Fits a plan: routes every leg via `leg`, then, while the total exceeds the budget × 1.10 and stops remain, drops
    /// the worst stop (`TourPlanner.dropWorst` over the current leg seconds) and routes only the one leg that joins its
    /// neighbours; every other leg is kept.
    ///
    /// The first legs are routed concurrently, at most `maxConcurrentRequests` at a time, and stored by index, so the
    /// order of the answers does not matter. Request slots are handed out in leg order before each request starts, so
    /// the cap is exact. Joining legs are routed one at a time.
    ///
    /// At most `maxRequests` calls to `leg` (a negative cap counts as 0). Once the caller is cancelled no request
    /// starts and no stop is dropped: `fit` returns as soon as the requests already in flight answer. A leg that is not
    /// requested, or whose answer is nil or has seconds or metres that are not finite and non-negative, becomes an
    /// approximate straight leg: the estimate's seconds, straight metres × the detour factor, and the path [from, to].
    /// A routed leg with an empty path gets [from, to]. A leg between equal points is 0 s and 0 m without a request.
    ///
    /// Duration: with the app's 10 s per request, a 12-stop plan (13 legs) takes at worst ⌈13 / 4⌉ × 10 = 40 s for the
    /// first legs plus 12 × 10 s for joining legs if every stop is dropped, ≈ 160 s; usually a few seconds.
    public static func fit(_ plan: TourPlan, maxRequests: Int,
                           leg: @Sendable (Coordinate, Coordinate) async -> RoutedLeg?) async -> RoutedTour {
        await withoutActuallyEscaping(leg) { leg in
            await fit(plan, maxRequests: maxRequests, escapingLeg: leg)
        }
    }

    // MARK: - Internals

    private static func fit(_ plan: TourPlan, maxRequests: Int,
                            escapingLeg leg: @escaping @Sendable (Coordinate, Coordinate) async -> RoutedLeg?) async
        -> RoutedTour {
        var requestsLeft = max(0, maxRequests)
        let points = [plan.start] + plan.stops.map(\.coordinate) + [plan.end]
        let gaps = Array(zip(points, points.dropFirst()))
        // Every leg starts as its straight stand-in; routed answers replace them by index.
        var legs = gaps.map { straight($0.0, $0.1) }

        await withTaskGroup(of: (Int, RoutedLeg?).self) { group in
            var inFlight = 0
            for (index, (from, to)) in gaps.enumerated() {
                if from == to { legs[index] = sameSpot(from); continue }
                guard requestsLeft > 0, !Task.isCancelled else { continue }
                if inFlight == maxConcurrentRequests, let (done, answer) = await group.next() {
                    legs[done] = resolve(answer, gaps[done].0, gaps[done].1)
                    inFlight -= 1
                }
                // The wait above may have spanned a cancellation.
                guard !Task.isCancelled else { continue }
                requestsLeft -= 1
                inFlight += 1
                group.addTask { (index, await leg(from, to)) }
            }
            for await (done, answer) in group {
                legs[done] = resolve(answer, gaps[done].0, gaps[done].1)
            }
        }

        var current = plan
        while !Task.isCancelled, !current.stops.isEmpty,
              total(legs, stops: current.stops.count) > current.budgetSeconds * (1 + TourPlanner.overrunAllowance) {
            let next = TourPlanner.dropWorst(current, legSeconds: legs.map(\.seconds))
            guard let k = removedIndex(from: current.stops, to: next.stops) else { break }
            // Stop k sat between legs k and k + 1; one leg from its predecessor to its successor replaces both.
            let from = k == 0 ? current.start : current.stops[k - 1].coordinate
            let to = k == current.stops.count - 1 ? current.end : current.stops[k + 1].coordinate
            let joining: RoutedLeg
            if from == to {
                joining = sameSpot(from)
            } else if requestsLeft > 0, !Task.isCancelled {
                requestsLeft -= 1
                joining = resolve(await leg(from, to), from, to)
            } else {
                joining = straight(from, to)
            }
            legs.replaceSubrange(k...(k + 1), with: [joining])
            current = next
        }

        return RoutedTour(plan: current, legs: legs)
    }

    private static func total(_ legs: [RoutedLeg], stops: Int) -> Double {
        legs.reduce(0) { $0 + $1.seconds } + TourPlanner.dwellSeconds * Double(stops)
    }

    /// The router's answer if usable (empty path filled in), else the straight stand-in.
    private static func resolve(_ answer: RoutedLeg?, _ from: Coordinate, _ to: Coordinate) -> RoutedLeg {
        guard var routed = answer, routed.seconds.isFinite, routed.seconds >= 0, routed.metres.isFinite,
              routed.metres >= 0 else { return straight(from, to) }
        if routed.path.isEmpty { routed.path = [from, to] }
        return routed
    }

    private static func sameSpot(_ point: Coordinate) -> RoutedLeg {
        RoutedLeg(seconds: 0, metres: 0, path: [point], approximate: false)
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
