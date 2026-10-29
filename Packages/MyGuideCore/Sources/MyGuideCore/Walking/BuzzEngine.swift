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

extension Buzz {
    /// A place the walker chose on the map: told like a buzz, but nothing offered it, so no course ("100 m away") and
    /// no budget override.
    public init(chosen place: WalkingPlace, position: Coordinate) {
        let distance = GeoMath.distance(position, place.candidate.coordinate)
        let bearing = GeoMath.bearing(from: position, to: place.candidate.coordinate)
        self.init(id: UUID(), place: place, distance: distance, bearing: bearing, title: place.candidate.name,
                  detail: BuzzText.detail(distance: distance, bearing: bearing, course: nil), usedOverride: false)
    }
}

/// Why the engine did not buzz (design 4.3), in the order the reasons are checked. `tourCadence` is not the engine's:
/// the app did not ask it, because a tour's 3-minute cadence holds buzzes back (`TourBuzzCadence`).
public enum QuietReason: String, Sendable, Codable, CaseIterable {
    case badAccuracy, noneDue, busy, skipQuiet, allExcluded, budget, tourCadence
}

/// A place that is due (within the due/drop radius) at the moment of a decision.
public struct DuePlace: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var tier: PlaceTier
    public var distance: Double
    /// Already buzzed, heard or retired.
    public var excluded: Bool
}

public enum BuzzDecision: Sendable, Equatable {
    case buzz(Buzz)
    case quiet(QuietReason, due: [DuePlace])

    public var buzz: Buzz? {
        if case .buzz(let b) = self { return b }
        return nil
    }
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

    /// Every place may buzz again (the reset button, spec 13.5): forgets the places retired at start and those
    /// buzzed, heard or skipped this run. The budget, the skip pause and the due set are kept.
    public mutating func clearExclusions() {
        excluded.removeAll()
    }

    /// The owner skipped a buzz: stay quiet for `skipQuiet` seconds.
    public mutating func noteSkip(at now: Date) {
        lastSkip = now
    }

    public mutating func evaluate(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                  course: Double?, now: Date) -> Buzz? {
        decide(places: places, position: position, accuracy: accuracy, course: course, now: now).buzz
    }

    /// Like `evaluate`, but says why nothing was buzzed. Quiet reasons are checked in the order of design 4.3.
    public mutating func decide(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                course: Double?, now: Date) -> BuzzDecision {
        guard WalkingFix.isUsable(accuracy: accuracy) else { return .quiet(.badAccuracy, due: []) }

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

        let ordered = due.sorted { ($0.place.tier, $0.distance) < ($1.place.tier, $1.distance) }
        let duePlaces = ordered.map {
            DuePlace(id: $0.place.candidate.id, name: $0.place.candidate.name, tier: $0.place.tier,
                     distance: $0.distance, excluded: excluded.contains($0.place.candidate.id))
        }

        if due.isEmpty { return .quiet(.noneDue, due: []) }
        if isBusy { return .quiet(.busy, due: duePlaces) }
        if let lastSkip, now.timeIntervalSince(lastSkip) < Self.skipQuiet { return .quiet(.skipQuiet, due: duePlaces) }

        let candidates = ordered.filter { !excluded.contains($0.place.candidate.id) }
        if candidates.isEmpty { return .quiet(.allExcluded, due: duePlaces) }

        if let first = candidates.first, budget.canSpend(at: now), budget.spend(at: now) {
            return .buzz(buzz(first.place, first.distance, first.bearing, course, usedOverride: false))
        }

        // The first top-tier candidate (tier/distance order) that is far enough and has been passed; the interval
        // check is not part of the choice.
        if let top = candidates.first(where: {
            $0.place.tier == .top && $0.distance >= Self.overrideMinDistance
                && $0.distance > (closest[$0.place.candidate.id] ?? $0.distance) + Self.overridePassingMargin
        }), lastOverride.map({ now.timeIntervalSince($0) >= Self.overrideInterval }) ?? true {
            lastOverride = now
            return .buzz(buzz(top.place, top.distance, top.bearing, course, usedOverride: true))
        }
        return .quiet(.budget, due: duePlaces)
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
