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

/// Why the engine did not buzz (design 4.3), in the order the reasons are checked. `noneDue` is checked twice: no
/// place tracked at all (`due` empty), and, after `allExcluded`, no place that may buzz is within its own due radius
/// and none qualifies for the override (`due` lists the tracked places). `minGap`: less than
/// `BuzzEngine.minimumGap` since the last buzz (spec 20.7). `held`: the best due place waits for a better one just
/// ahead (spec 20.3). `tourCadence` and `tourStopHeld` are not the engine's: the app did not ask it, because a tour's
/// 3-minute cadence holds buzzes back (`TourBuzzCadence`), or because a tour stop arrived at waits for its own buzz
/// (`TourStopDelivery`).
public enum QuietReason: String, Sendable, Codable, CaseIterable {
    case badAccuracy, noneDue, busy, skipQuiet, minGap, allExcluded, held, budget, tourCadence, tourStopHeld
}

/// A place the engine tracks at the moment of a decision: it came within its due radius and is not yet more than
/// `BuzzEngine.dropRadius` away. It may buzz normally only while within its due radius (spec 20.2).
public struct DuePlace: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var tier: PlaceTier
    public var distance: Double
    /// Already buzzed, heard or retired, or at the spot (or with the Wikidata id) of a place buzzed, heard or chosen,
    /// or ranked lower and within `BuzzEngine.complexRadius` of one.
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

/// Decides which nearby place, if any, deserves a buzz right now (design 7.4, spec 19 and 20).
/// - **Due radius** (spec 20.2): 100 m for a top place with at least `famousSitelinks` sitelinks, 80 m for another top
///   place, 60 m for the rest (`dueRadius(for:)`). A place is tracked from its due radius until it is more than
///   `dropRadius` (120 m) away, and buzzes normally only while within its due radius.
/// - **Order** among places that may buzz: tier, then Wikidata sitelinks (more first, none counts as 0), then
///   distance (spec 19.3).
/// - **Hold** (spec 20.3): the first place in that order waits while a better-ranked (tier, then sitelinks), not
///   excluded place within `holdRadius` of it is approaching (its distance shrank since the last fix) and not yet
///   within its own due radius; at most `maxHold` from the first fix that held it, while it stays tracked.
/// - **Budget and override**: the budget paces buzzes; a top-tier place the walker is passing by (tracked, at least
///   `overrideMinDistance` away and `overridePassingMargin` beyond its closest) can override the budget at most once
///   per `overrideInterval`.
/// - **Cadence** (spec 20.7): at least `minimumGap` between two buzzes of the engine, override included.
/// - **Exclusion** (spec 19.4, 20.4): the engine remembers where it buzzed this run, how those places ranked, and
///   their Wikidata ids. Every place within `sameSpotRadius` of a buzzed spot, every lower-ranked place within
///   `complexRadius` of one, and every place with a buzzed Wikidata id counts as excluded at each later decision,
///   whatever its id, so one spot (or one complex) buzzes once even when a later list names it differently. Places
///   heard, chosen on the map or buzzed as tour stops are noted the same way (`excludeSpot(of:)`).
public struct BuzzEngine: Sendable {
    /// The due radius of a place below top (metres); also the base of `dueRadius(for:)`.
    public static let dueRadius = 60.0
    /// The due radius of a top place, and of a top place with at least `famousSitelinks` sitelinks (spec 20.2).
    public static let topDueRadius = 80.0, famousTopDueRadius = 100.0
    public static let famousSitelinks = 40
    public static let dropRadius = 120.0
    /// Places at most this far (metres, inclusive) from a buzzed place are excluded with it.
    public static let sameSpotRadius = 25.0
    /// Lower-ranked places at most this far (metres, inclusive) from a buzzed place are excluded with it (spec 20.4).
    public static let complexRadius = 40.0
    /// A better place at most this far (metres, inclusive) from the first due place holds it, for at most `maxHold`
    /// seconds (spec 20.3).
    public static let holdRadius = 60.0
    public static let maxHold: TimeInterval = 30
    /// The least time between two buzzes of the engine (spec 20.7).
    public static let minimumGap: TimeInterval = 30
    public static let overrideMinDistance = 90.0, overridePassingMargin = 10.0
    public static let overrideInterval: TimeInterval = 600, skipQuiet: TimeInterval = 60
    public static let maxFixAccuracy = 50.0

    /// True while a previous buzz is still being presented; nothing new is buzzed meanwhile.
    public var isBusy = false

    /// Where a place was buzzed, heard or chosen, and how it ranked (nil when it has no tier).
    private struct Spot: Sendable {
        var coordinate: Coordinate
        var rank: Rank?
    }

    /// Tier, then sitelinks (more first): smaller is better.
    private struct Rank: Sendable, Comparable {
        var tier: Int
        var negativeSitelinks: Int

        init(tier: PlaceTier, sitelinks: Int?) {
            self.tier = tier.rawValue
            negativeSitelinks = -(sitelinks ?? 0)
        }

        static func < (a: Rank, b: Rank) -> Bool {
            (a.tier, a.negativeSitelinks) < (b.tier, b.negativeSitelinks)
        }
    }

    private var budget: BuzzBudget
    private var excluded: Set<String>
    /// The places buzzed this run (by the engine or noted with `excludeSpot(of:)`).
    private var buzzedSpots: [Spot] = []
    /// Wikidata ids of the same places (those that have one).
    private var buzzedWikidata: Set<String> = []
    private var lastSkip: Date?
    private var lastOverride: Date?
    /// When the engine last buzzed (normal or override).
    private var lastBuzz: Date?
    /// Tracked places (by id) with the smallest distance seen while tracked.
    private var closest: [String: Double] = [:]
    /// Every place of the last usable fix (by id) with its distance then, to tell an approaching place.
    private var lastDistance: [String: Double] = [:]
    /// Tracked places (by id) held for a better place, with the time of the first fix that held them.
    private var heldSince: [String: Date] = [:]
    private let makeID: @Sendable () -> UUID

    public init(perHour: Int, now: Date, excluded: Set<String>, makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.budget = BuzzBudget(perHour: perHour, now: now)
        self.excluded = excluded
        self.makeID = makeID
    }

    /// The radius within which `place` may buzz normally (spec 20.2): `famousTopDueRadius` for a top place with at
    /// least `famousSitelinks` sitelinks, `topDueRadius` for another top place, `dueRadius` for the rest.
    public static func dueRadius(for place: WalkingPlace) -> Double {
        guard place.tier == .top else { return dueRadius }
        return (place.candidate.sitelinks ?? 0) >= famousSitelinks ? famousTopDueRadius : topDueRadius
    }

    public mutating func setPerHour(_ value: Int, at now: Date) {
        budget.setPerHour(value, at: now)
    }

    public mutating func exclude(_ placeID: String) {
        excluded.insert(placeID)
    }

    /// `place` was buzzed outside the engine (a tour stop), heard, or chosen on the map (spec 19.4): it is excluded by
    /// id, and every place within `sameSpotRadius` of it or with its Wikidata id counts as excluded from now on, as
    /// for the engine's own buzzes; so does every place within `complexRadius` that ranks below it, with its rank
    /// from `PlaceTiers.tier(for:)` (none when it has no tier). It does not count as a buzz for `minimumGap`.
    public mutating func excludeSpot(of place: Candidate) {
        excluded.insert(place.id)
        rememberSpot(of: place, tier: PlaceTiers.tier(for: place))
    }

    /// Every place may buzz again (the reset button, spec 13.5): forgets the places retired at start and those
    /// buzzed, heard or skipped this run, and the buzzed spots and Wikidata ids. The budget, the skip pause, the
    /// minimum gap, the holds and the tracked set are kept.
    public mutating func clearExclusions() {
        excluded.removeAll()
        buzzedSpots.removeAll()
        buzzedWikidata.removeAll()
    }

    /// The owner skipped a buzz: stay quiet for `skipQuiet` seconds.
    public mutating func noteSkip(at now: Date) {
        lastSkip = now
    }

    public mutating func evaluate(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                  course: Double?, now: Date) -> Buzz? {
        decide(places: places, position: position, accuracy: accuracy, course: course, now: now).buzz
    }

    /// Like `evaluate`, but says why nothing was buzzed. Quiet reasons are checked in the order of `QuietReason`.
    public mutating func decide(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                course: Double?, now: Date) -> BuzzDecision {
        guard WalkingFix.isUsable(accuracy: accuracy) else { return .quiet(.badAccuracy, due: []) }

        // Update the tracked set and the distances. A place that is no longer in `places` is forgotten.
        struct Due { var place: WalkingPlace; var distance: Double; var bearing: Double }
        var due: [Due] = []
        var stillDue: [String: Double] = [:]
        var distances: [String: Double] = [:]
        for place in places {
            let id = place.candidate.id
            let distance = GeoMath.distance(position, place.candidate.coordinate)
            distances[id] = distance
            let previous = closest[id]
            let isDue = previous != nil ? distance <= Self.dropRadius : distance <= Self.dueRadius(for: place)
            guard isDue else { continue }
            stillDue[id] = min(previous ?? distance, distance)
            due.append(Due(place: place, distance: distance,
                           bearing: GeoMath.bearing(from: position, to: place.candidate.coordinate)))
        }
        closest = stillDue
        let previousDistance = lastDistance
        lastDistance = distances
        heldSince = heldSince.filter { stillDue[$0.key] != nil }

        let ordered = due.sorted { Self.orderKey($0.place, $0.distance) < Self.orderKey($1.place, $1.distance) }
        let duePlaces = ordered.map {
            DuePlace(id: $0.place.candidate.id, name: $0.place.candidate.name, tier: $0.place.tier,
                     distance: $0.distance, excluded: isExcluded($0.place))
        }

        if due.isEmpty { return .quiet(.noneDue, due: []) }
        if isBusy { return .quiet(.busy, due: duePlaces) }
        if let lastSkip, now.timeIntervalSince(lastSkip) < Self.skipQuiet { return .quiet(.skipQuiet, due: duePlaces) }
        if Self.isWithin(Self.minimumGap, of: lastBuzz, now: now) { return .quiet(.minGap, due: duePlaces) }

        let candidates = ordered.filter { !isExcluded($0.place) }
        if candidates.isEmpty { return .quiet(.allExcluded, due: duePlaces) }

        var held = false
        if let first = candidates.first(where: { $0.distance <= Self.dueRadius(for: $0.place) }),
           budget.canSpend(at: now) {
            if isHeld(first.place, places: places, distances: distances, previous: previousDistance, now: now) {
                held = true
            } else if budget.spend(at: now) {
                return .buzz(buzz(first.place, first.distance, first.bearing, course, usedOverride: false, now: now))
            }
        }

        // The first top-tier candidate (in the due order) that is far enough and has been passed; the interval
        // check is not part of the choice.
        if let top = candidates.first(where: {
            $0.place.tier == .top && $0.distance >= Self.overrideMinDistance
                && $0.distance > (closest[$0.place.candidate.id] ?? $0.distance) + Self.overridePassingMargin
        }), lastOverride.map({ now.timeIntervalSince($0) >= Self.overrideInterval }) ?? true {
            lastOverride = now
            return .buzz(buzz(top.place, top.distance, top.bearing, course, usedOverride: true, now: now))
        }
        if held { return .quiet(.held, due: duePlaces) }
        let anyWithinRadius = candidates.contains { $0.distance <= Self.dueRadius(for: $0.place) }
        return .quiet(anyWithinRadius ? .budget : .noneDue, due: duePlaces)
    }

    /// The due order: tier, then sitelinks (more first, nil as 0), then distance.
    private static func orderKey(_ place: WalkingPlace, _ distance: Double) -> (PlaceTier, Int, Double) {
        (place.tier, -(place.candidate.sitelinks ?? 0), distance)
    }

    /// True when `place` must wait for a better one just ahead (spec 20.3): a place of `places` that ranks above it,
    /// is not excluded, lies within `holdRadius` of it, is beyond its own due radius and is closer than at the last
    /// fix. Notes the first fix that held `place`; false once `maxHold` has passed since (or when that fix is dated
    /// after `now`, the clock set back).
    private mutating func isHeld(_ place: WalkingPlace, places: [WalkingPlace], distances: [String: Double],
                                 previous: [String: Double], now: Date) -> Bool {
        let rank = Rank(tier: place.tier, sitelinks: place.candidate.sitelinks)
        let better = places.contains { other in
            guard other.candidate.id != place.candidate.id,
                  Rank(tier: other.tier, sitelinks: other.candidate.sitelinks) < rank,
                  let distance = distances[other.candidate.id], let before = previous[other.candidate.id],
                  distance > Self.dueRadius(for: other), distance < before,
                  GeoMath.distance(other.candidate.coordinate, place.candidate.coordinate) <= Self.holdRadius
            else { return false }
            return !isExcluded(other)
        }
        guard better else { return false }
        let since = heldSince[place.candidate.id] ?? now
        heldSince[place.candidate.id] = since
        return Self.isWithin(Self.maxHold, of: since, now: now)
    }

    /// Excluded by id, by a Wikidata id buzzed this run, within `sameSpotRadius` (inclusive) of a spot buzzed this
    /// run, or ranked lower than a place buzzed this run within `complexRadius` (inclusive) of it.
    private func isExcluded(_ place: WalkingPlace) -> Bool {
        if excluded.contains(place.candidate.id) { return true }
        if place.candidate.wikidata.map({ buzzedWikidata.contains($0) }) == true { return true }
        let rank = Rank(tier: place.tier, sitelinks: place.candidate.sitelinks)
        return buzzedSpots.contains { spot in
            let distance = GeoMath.distance(spot.coordinate, place.candidate.coordinate)
            if distance <= Self.sameSpotRadius { return true }
            guard distance <= Self.complexRadius, let spotRank = spot.rank else { return false }
            return spotRank < rank
        }
    }

    /// Remembers `place`'s spot with its rank (when it has a tier) and its Wikidata id (an empty one is no id).
    private mutating func rememberSpot(of place: Candidate, tier: PlaceTier?) {
        buzzedSpots.append(Spot(coordinate: place.coordinate,
                                rank: tier.map { Rank(tier: $0, sitelinks: place.sitelinks) }))
        if let wikidata = place.wikidata, !wikidata.isEmpty { buzzedWikidata.insert(wikidata) }
    }

    /// True when `date` lies less than `interval` before `now`; a date after `now` (the clock was set back) holds
    /// nothing off.
    private static func isWithin(_ interval: TimeInterval, of date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < interval
    }

    /// Excludes `place` by id, remembers its spot, rank and Wikidata id and the time, then builds the buzz.
    private mutating func buzz(_ place: WalkingPlace, _ distance: Double, _ bearing: Double,
                               _ course: Double?, usedOverride: Bool, now: Date) -> Buzz {
        excluded.insert(place.candidate.id)
        rememberSpot(of: place.candidate, tier: place.tier)
        lastBuzz = now
        return Buzz(id: makeID(), place: place, distance: distance, bearing: bearing,
                    title: place.candidate.name,
                    detail: BuzzText.detail(distance: distance, bearing: bearing, course: course),
                    usedOverride: usedOverride)
    }
}
