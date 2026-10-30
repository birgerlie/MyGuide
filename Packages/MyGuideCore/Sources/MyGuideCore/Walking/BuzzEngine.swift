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
    /// True for a «behind you» buzz after a story (spec 20.3.3, 20.6.1, 20.6.6).
    public var behindYou = false
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
/// and none qualifies for the override (`due` lists the tracked places). `minGap`: the place that would buzz waits
/// for its `BuzzEngine.minimumGap(for:)` since the last buzz (spec 20.2.1; checked once a place is chosen, after
/// `allExcluded`). `held`: the best due place waits for a better one (spec 20.3, 20.3.2, 20.5.1; the engine's `heldBy`
/// names it). `tourCadence` and `tourStopHeld` are not the engine's: the app did not ask it, because a tour's 3-minute
/// cadence holds buzzes back (`TourBuzzCadence`), or because a tour stop arrived at waits for its own buzz
/// (`TourStopDelivery`).
public enum QuietReason: String, Sendable, Codable, CaseIterable {
    case badAccuracy, noneDue, busy, skipQuiet, minGap, allExcluded, held, budget, tourCadence, tourStopHeld
}
// `minGap` keeps its place in the raw-value order for the walk log; the engine checks it after `allExcluded`.

/// A place the engine tracks at the moment of a decision: it came within its due radius and is not yet more than
/// `BuzzEngine.dropRadius` away. It may buzz normally only within 60 m, or within its due radius once passed
/// (`BuzzEngine.mayBuzz`, spec 20.2, 20.2.3).
public struct DuePlace: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var tier: PlaceTier
    public var distance: Double
    /// Already buzzed, heard or retired; or with the Wikidata id of a place buzzed, heard or chosen; or ranked equal
    /// or lower and within `BuzzEngine.sameSpotRadius` of it; or ranked lower, with fewer than
    /// `BuzzEngine.complexMaxSitelinks` sitelinks, and within `BuzzEngine.complexRadius` of it. A hill or island
    /// excludes nothing around it, and no spot excludes a work of art with `BuzzEngine.famousArtSitelinks` or more
    /// (only the same id or Wikidata id does).
    public var excluded: Bool
}

/// The place that held a `held` decision (spec 20.6.6), for the walk log.
public struct HoldingPlace: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum BuzzDecision: Sendable, Equatable {
    case buzz(Buzz)
    case quiet(QuietReason, due: [DuePlace])

    public var buzz: Buzz? {
        if case .buzz(let b) = self { return b }
        return nil
    }
}

/// Decides which nearby place, if any, deserves a buzz right now (design 7.4, spec 19, 20 and 20.2).
/// - **Due radius** (spec 20.2): 100 m for a top place with at least `famousSitelinks` sitelinks, 80 m for another top
///   place, 60 m for the rest (`dueRadius(for:)`). A place is tracked from its due radius until it is more than
///   `dropRadius` (120 m) away. It buzzes normally within `dueRadius` (60 m), and between 60 m and its own radius only
///   once passed: its distance has grown at least `passedMargin` from the smallest seen (spec 20.2.3).
/// - **Order** among places that may buzz: tier, then Wikidata sitelinks (more first, none counts as 0), then
///   distance (spec 19.3).
/// - **Hold** (spec 20.3, 20.5.1, 20.6.5): the first place in that order waits while a better-ranked (tier, then
///   sitelinks), not excluded place that may not buzz yet is inside its own due radius from the walker, or is
///   approaching (closer by at least `approachingMargin` than at the last fix) within `holdRadius` of it; at most
///   `maxHold` from the first fix that held it, while it stays tracked.
/// - **Budget and override**: the budget paces buzzes; a top-tier place the walker is passing by (tracked, at least
///   `overrideMinDistance` away and `overridePassingMargin` beyond its closest) can override the budget at most once
///   per `overrideInterval`.
/// - **Cadence** (spec 20.2.1, 20.4.4): after any buzz of the engine, the next one, override included, waits
///   `minimumGap(for:)` of the place it would buzz: 30 s for top or 25+ sitelinks, 90 s for 20–24, 120 s for 15–19,
///   240 s for the rest and for Wiki-only places.
/// - **Behind you** (spec 20.3.3, 20.4, 20.5.2, 20.6.1, 20.6.8): when a story that kept the engine busy for at least
///   `behindYouMinStory` ends, a famous place tracked at the decision that started it or during it, and passed since,
///   may still buzz once (`behindYouWindow`, `behindYouRadius`), whatever its rank gap but never within `topGap` (the
///   30 s minimum) of the last buzz. A skip during or after the story ends it.
/// - **Exclusion** (spec 19.4, 20.4, 20.2.2): the engine remembers where it buzzed this run, how those places ranked,
///   and their Wikidata ids. A place with a buzzed Wikidata id, a place ranked equal or lower within `sameSpotRadius`
///   of a buzzed spot, and a place ranked lower with fewer than `complexMaxSitelinks` sitelinks within
///   `complexRadius` of one count as excluded at each later
///   decision, whatever their ids, so one spot (or one complex) buzzes once even when a later list names it
///   differently, while a better place nearby may still buzz. A hill or island (`PlaceClass.natural`) excludes only
///   its own id and Wikidata id, and no spot excludes a work of art with `famousArtSitelinks` or more. Places heard,
///   chosen on the map or buzzed as tour stops are noted the same way (`excludeSpot(of:)`).
public struct BuzzEngine: Sendable {
    /// The due radius of a place below top (metres); also the base of `dueRadius(for:)`.
    public static let dueRadius = 60.0
    /// The due radius of a top place, and of a top place with at least `famousSitelinks` sitelinks (spec 20.2).
    public static let topDueRadius = 80.0, famousTopDueRadius = 100.0
    public static let famousSitelinks = 40
    public static let dropRadius = 120.0
    /// Places ranked equal or lower at most this far (metres, inclusive) from a buzzed place are excluded with it.
    public static let sameSpotRadius = 25.0
    /// Lower-ranked places with fewer than `complexMaxSitelinks` sitelinks at most this far (metres, inclusive) from a
    /// buzzed place are excluded with it (spec 20.4, 20.2.5, 20.4.1).
    public static let complexRadius = 55.0
    public static let complexMaxSitelinks = 20
    /// Beyond `dueRadius`, a place buzzes once its distance has grown this much (metres) from its closest (spec
    /// 20.2.3).
    public static let passedMargin = 5.0
    /// A better place approaching within this far (metres, inclusive) of the first due place holds it too, inside
    /// its own radius or not (spec 20.3, 20.5.1 as amended).
    public static let holdRadius = 60.0
    /// A hold lasts at most this long (spec 20.3).
    public static let maxHold: TimeInterval = 30
    /// A better place is approaching for the hold's neighbour rule when its distance shrank at least this much
    /// (metres) since the last fix, so GPS jitter does not hold (spec 20.6.5).
    public static let approachingMargin = 2.0
    /// The least time from the last buzz of the engine to a buzz of a top place or one with at least
    /// `topGapSitelinks`, of one with `highGapSitelinks` up to that, of one with `middleGapSitelinks` up to that, and
    /// of any other or Wiki-only place (spec 20.3.1, 20.4.4).
    public static let topGap: TimeInterval = 30, highGap: TimeInterval = 90, middleGap: TimeInterval = 120
    public static let otherGap: TimeInterval = 240
    public static let topGapSitelinks = 25, highGapSitelinks = 20, middleGapSitelinks = 15
    /// «Behind you» (spec 20.3.3, 20.4.3, 20.6.1): within this long after a story that kept the engine busy for at
    /// least `behindYouMinStory` ends, a place with at least `behindYouSitelinks` sitelinks that was due during the
    /// story, has been passed (`passedMargin` beyond its closest) and is at most `behindYouRadius` away buzzes once,
    /// whatever its rank gap, but at least `topGap` after the last buzz. A shorter busy spell is a story being
    /// prepared after a buzz, not one told.
    public static let behindYouWindow: TimeInterval = 60
    public static let behindYouMinStory: TimeInterval = 20
    public static let behindYouSitelinks = 30
    public static let behindYouRadius = 150.0
    /// A work of art with at least this many sitelinks is not excluded by the spot of another item (spec 20.3.5).
    public static let famousArtSitelinks = 30
    public static let overrideMinDistance = 90.0, overridePassingMargin = 10.0
    public static let overrideInterval: TimeInterval = 600, skipQuiet: TimeInterval = 60
    public static let maxFixAccuracy = 50.0

    /// True while a previous buzz is still being presented (its story preparing or playing); nothing new is buzzed
    /// meanwhile. Setting it without a time (`setBusy(_:at:)` gives one) dates the start or end of the busy spell at
    /// the next decision.
    public var isBusy = false {
        didSet {
            guard oldValue != isBusy else { return }
            if isBusy {
                // The decision that started the story counts too (spec 20.5.2). A new busy spell replaces any
                // pending «behind you» of the last one.
                dueWhileBusy = trackedAtLastDecision
                busyStart = .pending
                busyEnd = nil
                skippedSinceBusy = false
            } else {
                busyEnd = .pending
            }
        }
    }

    /// When the last busy spell began or ended, for «behind you»; `pending` until the next decision when no time was
    /// given.
    private enum BusyMark: Sendable {
        case pending
        case at(Date)
    }
    private var busyStart: BusyMark?
    private var busyEnd: BusyMark?
    /// The owner skipped since the last busy spell began: its «behind you» is off (spec 20.6.8).
    private var skippedSinceBusy = false
    /// Places (by id) tracked at the decision that started the story or at a decision during it (spec 20.5.2).
    private var dueWhileBusy: Set<String> = []
    /// Places (by id) tracked at the last usable decision.
    private var trackedAtLastDecision: Set<String> = []

    /// Where a place was buzzed, heard or chosen, and how it ranked (nil when it has no tier: it then excludes every
    /// place at its spot). A hill or island excludes no place around it.
    private struct Spot: Sendable {
        var coordinate: Coordinate
        var rank: Rank?
        var excludesNeighbours: Bool
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
    /// Every place of the last usable fix (by id) with its distance then, to tell an approaching place.
    private var lastDistance: [String: Double] = [:]
    /// Tracked places (by id) with the smallest distance seen while tracked.
    private var closest: [String: Double] = [:]
    /// Tracked places (by id) held for a better place, with the time of the first fix that held them.
    private var heldSince: [String: Date] = [:]
    private let makeID: @Sendable () -> UUID

    /// The best-ranked place that held the last decision, when it was quiet with `held` (spec 20.6.6); nil after any
    /// other decision.
    public private(set) var heldBy: HoldingPlace?

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

    /// The least time from the engine's last buzz to a buzz of `place` (spec 20.3.1, 20.4.4): `topGap` for top or at
    /// least `topGapSitelinks` sitelinks, `highGap` from `highGapSitelinks`, `middleGap` from `middleGapSitelinks`,
    /// `otherGap` for fewer (none counts as 0) and for every Wiki-only place.
    public static func minimumGap(for place: WalkingPlace) -> TimeInterval {
        let sitelinks = place.candidate.sitelinks ?? 0
        switch place.tier {
        case .top: return topGap
        case .wikiOnly: return otherGap
        case .good:
            if sitelinks >= topGapSitelinks { return topGap }
            if sitelinks >= highGapSitelinks { return highGap }
            return sitelinks >= middleGapSitelinks ? middleGap : otherGap
        }
    }

    /// Whether a place at `distance`, with `closest` the smallest distance seen while tracked (this fix included),
    /// may buzz normally (spec 20.2, 20.2.3): within `dueRadius`, or within its own due radius once its distance has
    /// grown at least `passedMargin` from `closest`.
    static func mayBuzz(_ place: WalkingPlace, distance: Double, closest: Double) -> Bool {
        distance <= dueRadius || (distance <= dueRadius(for: place) && distance >= closest + passedMargin)
    }

    /// Sets `isBusy`; a busy spell starting (free → busy) or ending (busy → free) is dated `now` for «behind you»
    /// (spec 20.3.3, 20.6.1).
    public mutating func setBusy(_ busy: Bool, at now: Date) {
        isBusy = busy
        if busy {
            if case .pending? = busyStart { busyStart = .at(now) }
        } else if case .pending? = busyEnd {
            busyEnd = .at(now)
        }
    }

    public mutating func setPerHour(_ value: Int, at now: Date) {
        budget.setPerHour(value, at: now)
    }

    public mutating func exclude(_ placeID: String) {
        excluded.insert(placeID)
    }

    /// `place` was buzzed outside the engine (a tour stop), heard, or chosen on the map (spec 19.4): it is excluded by
    /// id, and every place within `sameSpotRadius` of it or with its Wikidata id counts as excluded from now on, as
    /// for the engine's own buzzes (by rank, with its rank from `PlaceTiers.tier(for:)`; none when it has no tier, and
    /// then every place at its spot is excluded). It does not count as a buzz for `minimumGap(for:)`.
    public mutating func excludeSpot(of place: Candidate) {
        excluded.insert(place.id)
        rememberSpot(of: place, tier: PlaceTiers.tier(for: place))
    }

    /// Every place may buzz again (the reset button, spec 13.5): forgets the places retired at start and those
    /// buzzed, heard or skipped this run, and the buzzed spots and Wikidata ids. The budget, the skip pause, the
    /// time of the last buzz, the holds and the tracked set are kept.
    public mutating func clearExclusions() {
        excluded.removeAll()
        buzzedSpots.removeAll()
        buzzedWikidata.removeAll()
    }

    /// The owner skipped a buzz: stay quiet for `skipQuiet` seconds, and no «behind you» for the story playing or
    /// just ended (spec 20.6.8: the owner just asked for quiet).
    public mutating func noteSkip(at now: Date) {
        lastSkip = now
        skippedSinceBusy = true
    }

    public mutating func evaluate(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                  course: Double?, now: Date) -> Buzz? {
        decide(places: places, position: position, accuracy: accuracy, course: course, now: now).buzz
    }

    /// Like `evaluate`, but says why nothing was buzzed. Quiet reasons are checked in the order of `QuietReason`.
    public mutating func decide(places: [WalkingPlace], position: Coordinate, accuracy: Double,
                                course: Double?, now: Date) -> BuzzDecision {
        if case .pending? = busyStart { busyStart = .at(now) }
        if case .pending? = busyEnd { busyEnd = .at(now) }
        heldBy = nil
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
        trackedAtLastDecision = Set(stillDue.keys)
        let previousDistance = lastDistance
        lastDistance = distances
        heldSince = heldSince.filter { stillDue[$0.key] != nil }

        let ordered = due.sorted { Self.orderKey($0.place, $0.distance) < Self.orderKey($1.place, $1.distance) }
        let duePlaces = ordered.map {
            DuePlace(id: $0.place.candidate.id, name: $0.place.candidate.name, tier: $0.place.tier,
                     distance: $0.distance, excluded: isExcluded($0.place))
        }

        func mayBuzz(_ due: Due) -> Bool {
            Self.mayBuzz(due.place, distance: due.distance, closest: stillDue[due.place.candidate.id] ?? due.distance)
        }
        func gapPassed(_ place: WalkingPlace) -> Bool {
            !Self.isWithin(Self.minimumGap(for: place), of: lastBuzz, now: now)
        }
        let skipQuiet = Self.isWithin(Self.skipQuiet, of: lastSkip, now: now)
        // The place an ordinary decision would buzz (or hold, or keep waiting for its gap).
        let first = ordered.first { !isExcluded($0.place) && mayBuzz($0) }
        if isBusy {
            // Every tracked place, also one just outside its radius again (spec 20.5.2).
            dueWhileBusy.formUnion(stillDue.keys)
        } else if !skipQuiet, let behind = behindYou(places: places, distances: distances, now: now) {
            // The place that would buzz goes first only when it may buzz now (its gap passed, not held) and has at
            // least as many sitelinks (spec 20.4.2, 20.6.2). «Behind you» then stays pending for the rest of its
            // window, but in the app that buzz starts its story preparing at once: the new busy spell replaces the
            // window, and as it lasts only seconds no «behind you» follows it.
            let behindSitelinks = behind.candidate.sitelinks ?? 0
            let ordinaryFirst = first.map { first in
                gapPassed(first.place) && (first.place.candidate.sitelinks ?? 0) >= behindSitelinks
                    && !wouldBeHeld(first.place, places: places, distances: distances, closest: stillDue,
                                    previous: previousDistance, now: now)
            } ?? false
            if !ordinaryFirst, budget.spend(at: now) {
                busyEnd = nil
                dueWhileBusy = []
                return .buzz(buzz(behind, distances[behind.candidate.id] ?? 0,
                                  GeoMath.bearing(from: position, to: behind.candidate.coordinate), course,
                                  usedOverride: false, behindYou: true, now: now))
            }
        }

        if due.isEmpty { return .quiet(.noneDue, due: []) }
        if isBusy { return .quiet(.busy, due: duePlaces) }
        if skipQuiet { return .quiet(.skipQuiet, due: duePlaces) }

        let candidates = ordered.filter { !isExcluded($0.place) }
        if candidates.isEmpty { return .quiet(.allExcluded, due: duePlaces) }

        var holding: WalkingPlace?, waitsForGap = false
        // The gap grows as the rank falls, so when the first place must wait, every later one must too.
        if let first {
            if !gapPassed(first.place) {
                waitsForGap = true
            } else if budget.canSpend(at: now) {
                if let better = holder(of: first.place, places: places, distances: distances, closest: stillDue,
                                       previous: previousDistance), noteHold(of: first.place, now: now) {
                    holding = better
                } else if budget.spend(at: now) {
                    return .buzz(buzz(first.place, first.distance, first.bearing, course, usedOverride: false, now: now))
                }
            }
        }

        // The first top-tier candidate (in the due order) that is far enough and has been passed; the interval
        // and gap checks are not part of the choice.
        if let top = candidates.first(where: {
            $0.place.tier == .top && $0.distance >= Self.overrideMinDistance
                && $0.distance > (closest[$0.place.candidate.id] ?? $0.distance) + Self.overridePassingMargin
        }), !Self.isWithin(Self.overrideInterval, of: lastOverride, now: now) {
            if gapPassed(top.place) {
                lastOverride = now
                return .buzz(buzz(top.place, top.distance, top.bearing, course, usedOverride: true, now: now))
            }
            waitsForGap = true
        }
        if let holding {
            heldBy = HoldingPlace(id: holding.candidate.id, name: holding.candidate.name)
            return .quiet(.held, due: duePlaces)
        }
        if waitsForGap { return .quiet(.minGap, due: duePlaces) }
        return .quiet(candidates.contains(where: mayBuzz) ? .budget : .noneDue, due: duePlaces)
    }

    /// The «behind you» place (spec 20.3.3, 20.6.1): within `behindYouWindow` of the end of the last busy spell,
    /// when that spell lasted at least `behindYouMinStory` and no skip came since it began, and at least `topGap`
    /// after the last buzz: the best (in the due order) of `places` that was due during it, has at least
    /// `behindYouSitelinks` sitelinks, is at most `behindYouRadius` away (inclusive), has been passed (its distance at
    /// least `passedMargin` beyond its closest; one no longer tracked went beyond `dropRadius` and so was passed) and
    /// is not excluded. Nil outside the window (a story end dated after `now`, the clock set back, is outside; so is a
    /// spell whose end is dated before its start), with no such place, or when the budget cannot pay. Call after
    /// `closest` is updated for this fix.
    private func behindYou(places: [WalkingPlace], distances: [String: Double], now: Date) -> WalkingPlace? {
        guard !skippedSinceBusy, case .at(let start)? = busyStart, case .at(let end)? = busyEnd,
              end.timeIntervalSince(start) >= Self.behindYouMinStory,
              Self.isWithin(Self.behindYouWindow, of: end, now: now),
              // The 30 s minimum between two buzzes (spec 20.1.7) holds for «behind you» too (spec 20.6.1).
              !Self.isWithin(Self.topGap, of: lastBuzz, now: now),
              !dueWhileBusy.isEmpty, budget.canSpend(at: now) else { return nil }
        return places.filter { place in
            let id = place.candidate.id
            guard dueWhileBusy.contains(id), (place.candidate.sitelinks ?? 0) >= Self.behindYouSitelinks,
                  let distance = distances[id], distance <= Self.behindYouRadius,
                  closest[id].map({ distance >= $0 + Self.passedMargin }) ?? true else { return false }
            return !isExcluded(place)
        }
        .min { Self.orderKey($0, distances[$0.candidate.id] ?? 0) < Self.orderKey($1, distances[$1.candidate.id] ?? 0) }
    }

    /// The due order: tier, then sitelinks (more first, nil as 0), then distance.
    private static func orderKey(_ place: WalkingPlace, _ distance: Double) -> (PlaceTier, Int, Double) {
        (place.tier, -(place.candidate.sitelinks ?? 0), distance)
    }

    /// The best-ranked place (in the due order) that makes `place` wait (spec 20.3, 20.3.2, 20.4.2, 20.5.1 as
    /// amended, 20.6.5): a place of `places` that ranks above it, is not excluded, may not buzz yet (`mayBuzz`, with
    /// its smallest tracked distance from `closest`), and either
    /// - is inside its own due radius from the walker (approaching, new or waiting for its closest approach: inside
    ///   its radius it is tracked, so all three reduce to "not passed"), however far it is from `place`; or
    /// - is approaching (at least `approachingMargin` closer than at the last fix, `previous`) within `holdRadius` of
    ///   `place`, inside its own radius or not.
    /// Nil when there is none. The `maxHold` cap is not part of it (`noteHold(of:now:)`).
    private func holder(of place: WalkingPlace, places: [WalkingPlace], distances: [String: Double],
                        closest: [String: Double], previous: [String: Double]) -> WalkingPlace? {
        let rank = Rank(tier: place.tier, sitelinks: place.candidate.sitelinks)
        return places.filter { other in
            guard other.candidate.id != place.candidate.id,
                  Rank(tier: other.tier, sitelinks: other.candidate.sitelinks) < rank,
                  let distance = distances[other.candidate.id],
                  !Self.mayBuzz(other, distance: distance, closest: closest[other.candidate.id] ?? distance)
            else { return false }
            let insideItsRadius = distance <= Self.dueRadius(for: other)
            let approachingNearby = previous[other.candidate.id].map { $0 - distance >= Self.approachingMargin } == true
                && GeoMath.distance(other.candidate.coordinate, place.candidate.coordinate) <= Self.holdRadius
            guard insideItsRadius || approachingNearby else { return false }
            return !isExcluded(other)
        }
        .min { Self.orderKey($0, distances[$0.candidate.id] ?? 0) < Self.orderKey($1, distances[$1.candidate.id] ?? 0) }
    }

    /// `place` has a holder at this fix: notes the first fix that held it, and returns whether the hold still runs
    /// (false once `maxHold` has passed since that fix, or when it is dated after `now`, the clock set back).
    private mutating func noteHold(of place: WalkingPlace, now: Date) -> Bool {
        let since = heldSince[place.candidate.id] ?? now
        heldSince[place.candidate.id] = since
        return Self.isWithin(Self.maxHold, of: since, now: now)
    }

    /// Whether an ordinary decision would hold `place` now (`holder(of:…)` and the `maxHold` cap), without noting the
    /// hold.
    private func wouldBeHeld(_ place: WalkingPlace, places: [WalkingPlace], distances: [String: Double],
                             closest: [String: Double], previous: [String: Double], now: Date) -> Bool {
        guard holder(of: place, places: places, distances: distances, closest: closest, previous: previous) != nil
        else { return false }
        return Self.isWithin(Self.maxHold, of: heldSince[place.candidate.id] ?? now, now: now)
    }

    /// Excluded by id, by a Wikidata id buzzed this run, ranked equal or lower than a place buzzed this run within
    /// `sameSpotRadius` (inclusive) of it (any rank when that place had none), or ranked lower than one within
    /// `complexRadius` (inclusive) of it. Spots of hills and islands exclude nothing around them, and no spot
    /// excludes a work of art with at least `famousArtSitelinks` sitelinks (spec 20.3.5).
    private func isExcluded(_ place: WalkingPlace) -> Bool {
        if excluded.contains(place.candidate.id) { return true }
        if place.candidate.wikidata.map({ buzzedWikidata.contains($0) }) == true { return true }
        if place.candidate.isArt == true, (place.candidate.sitelinks ?? 0) >= Self.famousArtSitelinks { return false }
        let rank = Rank(tier: place.tier, sitelinks: place.candidate.sitelinks)
        return buzzedSpots.contains { spot in
            guard spot.excludesNeighbours else { return false }
            let distance = GeoMath.distance(spot.coordinate, place.candidate.coordinate)
            guard let spotRank = spot.rank else { return distance <= Self.sameSpotRadius }
            if distance <= Self.sameSpotRadius { return !(rank < spotRank) }
            return distance <= Self.complexRadius && spotRank < rank
                && (place.candidate.sitelinks ?? 0) < Self.complexMaxSitelinks
        }
    }

    /// Remembers `place`'s spot with its rank (when it has a tier) and its Wikidata id (an empty one is no id).
    private mutating func rememberSpot(of place: Candidate, tier: PlaceTier?) {
        buzzedSpots.append(Spot(coordinate: place.coordinate,
                                rank: tier.map { Rank(tier: $0, sitelinks: place.sitelinks) },
                                excludesNeighbours: place.placeClass != .natural))
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
                               _ course: Double?, usedOverride: Bool, behindYou: Bool = false, now: Date) -> Buzz {
        excluded.insert(place.candidate.id)
        rememberSpot(of: place.candidate, tier: place.tier)
        lastBuzz = now
        return Buzz(id: makeID(), place: place, distance: distance, bearing: bearing,
                    title: place.candidate.name,
                    detail: BuzzText.detail(distance: distance, bearing: bearing, course: course),
                    usedOverride: usedOverride, behindYou: behindYou)
    }
}
