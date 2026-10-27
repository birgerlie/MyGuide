import Foundation

/// One buzz to deliver: the place, where it is relative to the walker, and the line to show.
public struct Buzz: Sendable, Equatable {
    public var id: UUID
    public var place: WalkingPlace
    public var distance: Double
    public var bearing: Double
    /// The place name.
    public var title: String
    /// `BuzzText.detail(...)`.
    public var detail: String
    /// True when this buzz bypassed the budget (top-tier place being passed).
    public var usedOverride: Bool
}

/// Decides which nearby place, if any, deserves a buzz right now (design 7.4).
/// A place is "due" from 60 m until it is more than 120 m away; the budget paces buzzes, and a top-tier place
/// the walker is passing by can override the budget at most once per 10 minutes.
public struct BuzzEngine: Sendable {
    public static let dueRadius = 60.0, dropRadius = 120.0
    public static let overrideMinDistance = 90.0, overridePassingMargin = 10.0
    public static let overrideInterval: TimeInterval = 600, skipQuiet: TimeInterval = 60
    public static let maxFixAccuracy = 50.0

    /// True while a previous buzz is still being presented; nothing new is buzzed meanwhile.
    public var isBusy = false

    private var budget: BuzzBudget
    private var excluded: Set<String>
    private var lastSkip: Date?
    private var lastOverride: Date?
    /// Due places (by id) with the smallest distance seen while due.
    private var closest: [String: Double] = [:]
    private let makeID: @Sendable () -> UUID

    public init(perHour: Int, now: Date, excluded: Set<String>, makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.budget = BuzzBudget(perHour: perHour, now: now)
        self.excluded = excluded
        self.makeID = makeID
    }

    public mutating func setPerHour(_ value: Int, at now: Date) {
        budget.setPerHour(value, at: now)
    }

    public mutating func exclude(_ placeID: String) {
        excluded.insert(placeID)
    }

    /// The owner skipped a buzz: stay quiet for `skipQuiet` seconds.
    public mutating func noteSkip(at now: Date) {
        lastSkip = now
    }

    public mutating func evaluate(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                  course: Double?, now: Date) -> Buzz? {
        guard accuracy.isFinite, accuracy >= 0, accuracy <= Self.maxFixAccuracy else { return nil }

        // Update the due set. A place that is no longer in `places` is forgotten.
        struct Due { var place: WalkingPlace; var distance: Double; var bearing: Double }
        var due: [Due] = []
        var stillDue: [String: Double] = [:]
        for place in places {
            let id = place.candidate.id
            let distance = GeoMath.distance(position, place.candidate.coordinate)
            let previous = closest[id]
            let isDue = previous != nil ? distance <= Self.dropRadius : distance <= Self.dueRadius
            guard isDue else { continue }
            stillDue[id] = min(previous ?? distance, distance)
            due.append(Due(place: place, distance: distance,
                           bearing: GeoMath.bearing(from: position, to: place.candidate.coordinate)))
        }
        closest = stillDue

        if isBusy { return nil }
        if let lastSkip, now.timeIntervalSince(lastSkip) < Self.skipQuiet { return nil }

        let candidates = due
            .filter { !excluded.contains($0.place.candidate.id) }
            .sorted { ($0.place.tier, $0.distance) < ($1.place.tier, $1.distance) }

        if let first = candidates.first, budget.canSpend(at: now), budget.spend(at: now) {
            return buzz(first.place, first.distance, first.bearing, course, usedOverride: false)
        }

        // The first top-tier candidate (tier/distance order) that is far enough and has been passed; the interval
        // check is not part of the choice.
        if let top = candidates.first(where: {
            $0.place.tier == .top && $0.distance >= Self.overrideMinDistance
                && $0.distance > (closest[$0.place.candidate.id] ?? $0.distance) + Self.overridePassingMargin
        }), lastOverride.map({ now.timeIntervalSince($0) >= Self.overrideInterval }) ?? true {
            lastOverride = now
            return buzz(top.place, top.distance, top.bearing, course, usedOverride: true)
        }
        return nil
    }

    private mutating func buzz(_ place: WalkingPlace, _ distance: Double, _ bearing: Double,
                               _ course: Double?, usedOverride: Bool) -> Buzz {
        excluded.insert(place.candidate.id)
        return Buzz(id: makeID(), place: place, distance: distance, bearing: bearing,
                    title: place.candidate.name,
                    detail: BuzzText.detail(distance: distance, bearing: bearing, course: course),
                    usedOverride: usedOverride)
    }
}
