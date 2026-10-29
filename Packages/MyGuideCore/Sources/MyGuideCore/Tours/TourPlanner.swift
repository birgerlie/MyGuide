import Foundation

/// A planned tour (spec 5): the ordered stops between `start` and `end`, with the straight-line estimate the app then
/// checks with walking routes.
public struct TourPlan: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case loop, aToB }

    public var kind: Kind
    public var start: Coordinate
    /// The start again for a loop; the destination for A→B.
    public var end: Coordinate
    /// In walking order.
    public var stops: [TourStop]
    /// Walking (straight × 1.3 / 1.3 m/s per leg) + 240 s per stop.
    public var estimatedSeconds: Double
    /// A loop: the chosen duration. A→B: 1.25 × the direct estimate + 240 s per stop.
    public var budgetSeconds: Double

    public init(kind: Kind, start: Coordinate, end: Coordinate, stops: [TourStop], estimatedSeconds: Double,
                budgetSeconds: Double) {
        self.kind = kind
        self.start = start
        self.end = end
        self.stops = stops
        self.estimatedSeconds = estimatedSeconds
        self.budgetSeconds = budgetSeconds
    }
}

/// A place on a tour, with the score the planner gave it.
public struct TourStop: Sendable, Equatable, Codable, Identifiable {
    /// The place's candidate id.
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    public var tier: PlaceTier
    public var score: Double
    /// The place as the planner found it (tags, article), so the stop's buzz tells the same place a walking buzz
    /// would; nil for stops stored before it existed (decoded if present).
    public var candidate: Candidate?

    public init(id: String, name: String, coordinate: Coordinate, tier: PlaceTier, score: Double,
                candidate: Candidate? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.tier = tier
        self.score = score
        self.candidate = candidate
    }
}

/// Plans tours on straight lines (spec 5): greedy insertion by score ÷ added seconds within the budget, then 2-opt over
/// the stop order. Every choice that could tie is broken by id, so the same input always gives the same plan.
public enum TourPlanner {
    /// The tours' single walking speed (m/s), `TourArea.walkingSpeed`.
    public static let walkingSpeed = TourArea.walkingSpeed
    /// Walking routes are this much longer than the straight line, on average.
    public static let detourFactor = 1.3
    /// Seconds spent at each stop.
    public static let dwellSeconds = 240.0
    /// A routed total may exceed the budget by this share (the trimming in `TourRouting` uses it).
    public static let overrunAllowance = 0.10
    /// An A→B whose ends are fewer straight metres apart than this gets no stops: the direct route is the tour.
    public static let minimumDirectMetres = 200.0
    /// An A→B whose ends are farther apart than this (straight metres) is refused before any search: a walk of over
    /// 15 km is not a tour, and the corridor's place search would cover a huge area.
    public static let maxDirectMetres = 15_000.0
    /// An A→B may walk this multiple of the direct estimate (the dwell comes on top).
    public static let aToBBudgetFactor = 1.25
    /// A tour has at most this many stops (controller ruling), in both modes.
    public static let maxStops = 12

    /// Floating-point noise below this many seconds does not push a stop over the budget, so a stop whose cost works
    /// out to exactly the budget by hand fits.
    private static let budgetTolerance = 1e-6
    /// 2-opt applies a reversal only when it saves more than this many seconds, so rounding cannot make it loop.
    private static let improvementTolerance = 1e-9

    /// Whether an A→B from `start` to `destination` may be planned: both ends finite and at most `maxDirectMetres`
    /// apart in a straight line.
    public static func isWithinWalkingRange(from start: Coordinate, to destination: Coordinate) -> Bool {
        guard isFinite(start), isFinite(destination) else { return false }
        return GeoMath.distance(start, destination) <= maxDirectMetres
    }

    /// The estimated walk between two points: straight metres × `detourFactor` / `walkingSpeed`.
    public static func estimatedLegSeconds(from a: Coordinate, to b: Coordinate) -> Double {
        GeoMath.distance(a, b) * detourFactor / walkingSpeed
    }

    /// A loop from `start` back to it within `minutes` (a negative duration counts as 0). A start that is not finite
    /// gives no stops and an estimate of 0.
    public static func loop(from start: Coordinate, minutes: Int, candidates: [TourCandidate]) -> TourPlan {
        let budget = Double(max(0, minutes)) * 60
        guard isFinite(start) else {
            return TourPlan(kind: .loop, start: start, end: start, stops: [], estimatedSeconds: 0, budgetSeconds: budget)
        }
        let stops = plan(start: start, end: start, candidates: candidates) { _ in budget }
        return TourPlan(kind: .loop, start: start, end: start, stops: stops,
                        estimatedSeconds: estimatedSeconds(start: start, stops: stops, end: start), budgetSeconds: budget)
    }

    /// An A→B from `start` to `destination`. Budget: 1.25 × the direct estimate + 240 s per stop, so the stops may add
    /// at most a quarter to the walking. Ends fewer than 200 straight metres apart get no stops. An end that is not
    /// finite gives no stops, an estimate of 0 and a budget of 0.
    public static func aToB(from start: Coordinate, to destination: Coordinate, candidates: [TourCandidate]) -> TourPlan {
        guard isFinite(start), isFinite(destination) else {
            return TourPlan(kind: .aToB, start: start, end: destination, stops: [], estimatedSeconds: 0, budgetSeconds: 0)
        }
        let walkingBudget = aToBWalkingBudget(start: start, end: destination)
        let stops = GeoMath.distance(start, destination) < minimumDirectMetres
            ? []
            : plan(start: start, end: destination, candidates: candidates) { walkingBudget + dwellSeconds * Double($0) }
        return TourPlan(kind: .aToB, start: start, end: destination, stops: stops,
                        estimatedSeconds: estimatedSeconds(start: start, stops: stops, end: destination),
                        budgetSeconds: walkingBudget + dwellSeconds * Double(stops.count))
    }

    /// Drops the stop with the worst score ÷ saved seconds; the caller re-routes the two affected legs.
    ///
    /// `legSeconds` are the routed legs in order (start → first stop, …, last stop → end). Removing stop k saves its two
    /// legs and its dwell, minus the estimate of the new leg that joins its neighbours. The count must be
    /// `stops.count + 1` (asserted in debug builds; a release build then takes every leg as its estimate). A single leg
    /// that is NaN, infinite or negative (a router that returned nonsense) is replaced by its straight-line estimate.
    /// A stop whose removal saves no time is dropped only when no stop saves time. Ties drop the larger id (insertion
    /// prefers the smaller). The order of the other stops is kept; the estimate and an A→B budget are recomputed.
    /// A plan without stops comes back unchanged.
    public static func dropWorst(_ plan: TourPlan, legSeconds: [Double]) -> TourPlan {
        guard !plan.stops.isEmpty else { return plan }
        assert(legSeconds.count == plan.stops.count + 1, "dropWorst needs one routed leg per gap")
        let points = [plan.start] + plan.stops.map(\.coordinate) + [plan.end]
        let countMatches = legSeconds.count == plan.stops.count + 1
        func leg(_ index: Int) -> Double {
            if countMatches, legSeconds[index].isFinite, legSeconds[index] >= 0 { return legSeconds[index] }
            return estimatedLegSeconds(from: points[index], to: points[index + 1])
        }

        // Worst first: stops whose removal saves time before those that save none, then the smaller ratio, then the
        // larger id.
        var worst: (index: Int, saves: Bool, ratio: Double)?
        for (k, stop) in plan.stops.enumerated() {
            let saved = leg(k) + leg(k + 1) - estimatedLegSeconds(from: points[k], to: points[k + 2]) + dwellSeconds
            let saves = saved > 0
            // A stop that saves nothing ranks after every stop that does; among those, ratios are not compared.
            let ratio = saves ? stop.score / saved : 0
            guard let current = worst else { worst = (k, saves, ratio); continue }
            let isWorse: Bool
            if saves != current.saves {
                isWorse = saves
            } else if saves, ratio != current.ratio {
                isWorse = ratio < current.ratio
            } else {
                isWorse = stop.id > plan.stops[current.index].id
            }
            if isWorse { worst = (k, saves, ratio) }
        }

        var result = plan
        if let worst { result.stops.remove(at: worst.index) }
        result.estimatedSeconds = estimatedSeconds(start: result.start, stops: result.stops, end: result.end)
        if result.kind == .aToB {
            result.budgetSeconds = aToBWalkingBudget(start: result.start, end: result.end)
                + dwellSeconds * Double(result.stops.count)
        }
        return result
    }

    /// The plan without the stop `id` (the preview's «Fjern», spec 6): the other stops re-ordered by 2-opt, the
    /// estimate and an A→B budget recomputed; a loop keeps its chosen duration. No stop is added in its place. An id
    /// not in the plan gives the plan back unchanged; a repeated id loses its first occurrence. With an end that is
    /// not finite the order is kept and the estimate and budget are 0, as `aToB` gives for such ends.
    public static func removing(_ id: String, from plan: TourPlan) -> TourPlan {
        guard let index = plan.stops.firstIndex(where: { $0.id == id }) else { return plan }
        var result = plan
        result.stops.remove(at: index)
        guard isFinite(plan.start), isFinite(plan.end) else {
            result.estimatedSeconds = 0
            if result.kind == .aToB { result.budgetSeconds = 0 }
            return result
        }
        result.stops = twoOpt(result.stops, start: result.start, end: result.end)
        result.estimatedSeconds = estimatedSeconds(start: result.start, stops: result.stops, end: result.end)
        if result.kind == .aToB {
            result.budgetSeconds = aToBWalkingBudget(start: result.start, end: result.end)
                + dwellSeconds * Double(result.stops.count)
        }
        return result
    }

    // MARK: - Internals

    /// Walking + dwell for the route start → stops → end.
    static func estimatedSeconds(start: Coordinate, stops: [TourStop], end: Coordinate) -> Double {
        let points = [start] + stops.map(\.coordinate) + [end]
        let walking = zip(points, points.dropFirst()).reduce(0.0) { $0 + estimatedLegSeconds(from: $1.0, to: $1.1) }
        return walking + dwellSeconds * Double(stops.count)
    }

    private static func isFinite(_ c: Coordinate) -> Bool { c.latitude.isFinite && c.longitude.isFinite }

    private static func aToBWalkingBudget(start: Coordinate, end: Coordinate) -> Double {
        aToBBudgetFactor * estimatedLegSeconds(from: start, to: end)
    }

    /// Greedy insertion of at most `maxStops`, then 2-opt. `budget(n)` is the most a route with n stops may take; it must
    /// grow by at most `dwellSeconds` per stop (a loop's is constant, an A→B's grows by exactly that). Candidates with a
    /// score that is not finite and positive, or a coordinate that gives no finite cost, are never visited; a repeated
    /// id counts once (the first).
    ///
    /// A candidate that does not fit is dropped for good: it can never fit later. Take the route after later rounds
    /// with the candidate inserted; removing the stops added since (shortcutting past them) never lengthens the walk,
    /// by the triangle inequality of great-circle distance, and leaves the candidate in some gap of today's route. So
    /// its later walking is at least today's cheapest, and each stop added since costs another 240 s of dwell, at
    /// least what it adds to the budget. (Floating-point rounding could matter only for a candidate within a few ulps
    /// of the limit, where either answer is acceptable.)
    private static func plan(start: Coordinate, end: Coordinate, candidates: [TourCandidate],
                             budget: (Int) -> Double) -> [TourStop] {
        var seen = Set<String>()
        var remaining = candidates.compactMap { candidate -> TourStop? in
            let place = candidate.place.candidate
            guard candidate.score.isFinite, candidate.score > 0, seen.insert(place.id).inserted else { return nil }
            return TourStop(id: place.id, name: place.name, coordinate: place.coordinate, tier: candidate.place.tier,
                            score: candidate.score, candidate: place)
        }
        var stops: [TourStop] = []
        var estimate = estimatedSeconds(start: start, stops: [], end: end)

        while !remaining.isEmpty && stops.count < maxStops {
            let points = [start] + stops.map(\.coordinate) + [end]
            let limit = budget(stops.count + 1) + budgetTolerance
            var best: (stop: TourStop, position: Int, added: Double, ratio: Double)?
            var fitting: [TourStop] = []
            for stop in remaining {
                // The cheapest gap for this stop; the first of equal gaps.
                var cheapest: (position: Int, added: Double)?
                for i in 0..<(points.count - 1) {
                    let added = estimatedLegSeconds(from: points[i], to: stop.coordinate)
                        + estimatedLegSeconds(from: stop.coordinate, to: points[i + 1])
                        - estimatedLegSeconds(from: points[i], to: points[i + 1]) + dwellSeconds
                    guard added.isFinite else { continue }
                    if cheapest.map({ added < $0.added }) ?? true { cheapest = (i, added) }
                }
                // Added is at least the dwell (the triangle inequality), so the ratio is finite.
                guard let cheapest, estimate + cheapest.added <= limit else { continue }
                fitting.append(stop)
                let ratio = stop.score / cheapest.added
                if let current = best {
                    guard ratio > current.ratio || (ratio == current.ratio && stop.id < current.stop.id) else { continue }
                }
                best = (stop, cheapest.position, cheapest.added, ratio)
            }
            guard let best else { break }
            stops.insert(best.stop, at: best.position)
            estimate += best.added
            // Ids are unique here, so this keeps every fitting candidate but the inserted one, in input order.
            remaining = fitting.filter { $0.id != best.stop.id }
        }
        return twoOpt(stops, start: start, end: end)
    }

    /// Shortens the walk start → stops → end by reversing stretches of the stop order while that saves time; the ends
    /// stay. First improvement, scanning from the start, until no reversal helps: deterministic for a given order.
    static func twoOpt(_ stops: [TourStop], start: Coordinate, end: Coordinate) -> [TourStop] {
        guard stops.count >= 2 else { return stops }
        // Route indices: 0 is the start, 1...n the stops, n + 1 the end.
        var route = [start] + stops.map(\.coordinate) + [end]
        var order = stops
        let n = stops.count
        var improved = true
        while improved {
            improved = false
            scan: for i in 1..<n {
                for j in (i + 1)...n {
                    // Reversing route[i...j] swaps edges (i−1, i) and (j, j+1) for (i−1, j) and (i, j+1).
                    let before = estimatedLegSeconds(from: route[i - 1], to: route[i])
                        + estimatedLegSeconds(from: route[j], to: route[j + 1])
                    let after = estimatedLegSeconds(from: route[i - 1], to: route[j])
                        + estimatedLegSeconds(from: route[i], to: route[j + 1])
                    if after < before - improvementTolerance {
                        route[i...j].reverse()
                        order[(i - 1)...(j - 1)].reverse()
                        improved = true
                        break scan
                    }
                }
            }
        }
        return order
    }
}
