import Foundation

/// How worth a buzz a place is while walking; lower raw value is more important.
public enum PlaceTier: Int, Sendable, Codable, Comparable {
    case top = 1, good = 2, wikiOnly = 3

    public static func < (a: PlaceTier, b: PlaceTier) -> Bool { a.rawValue < b.rawValue }
}

/// A candidate that qualifies for a walking-mode buzz, with its tier.
public struct WalkingPlace: Sendable, Equatable {
    public var candidate: Candidate
    public var tier: PlaceTier

    public init(candidate: Candidate, tier: PlaceTier) {
        self.candidate = candidate
        self.tier = tier
    }
}

public enum PlaceTiers {
    private static let neverAmenities: Set<String> = [
        "restaurant", "cafe", "bar", "pub", "fast_food", "ice_cream", "biergarten", "bank", "atm", "school", "college",
        "university", "kindergarten", "hospital", "clinic", "pharmacy", "embassy", "police", "post_office", "parking", "fuel",
    ]
    private static let neverTourism: Set<String> = ["hotel", "hostel", "guest_house", "motel", "apartment", "camp_site"]
    private static let neverRailway: Set<String> = ["station", "halt", "stop", "tram_stop", "subway_entrance"]
    private static let neverBuildings: Set<String> = [
        "train_station", "transportation", "office", "commercial", "retail", "hotel", "school", "university", "hospital",
    ]
    private static let topHistoric: Set<String> = [
        "castle", "palace", "city_gate", "citywalls", "ruins", "archaeological_site", "monument", "fort", "tower", "battlefield",
    ]
    private static let topBuildings: Set<String> = ["cathedral", "palace", "castle"]
    private static let goodTourism: Set<String> = ["museum", "attraction", "gallery"]
    private static let goodHistoric: Set<String> = ["manor", "church", "monastery", "archaeological"]
    /// `memorial` values of a `historic=memorial` too small to be worth a buzz or a tour stop on their own.
    private static let minorMemorials: Set<String> = ["plaque", "stolperstein", "stolperschwelle"]

    /// Wikidata sitelinks from which a `place` is `top` (spec 19.2; fewer is `good` for a Wikipedia-only one). An OSM
    /// candidate whose item is such a place is at least `top` too (spec 20.5).
    public static let topSitelinks = 30
    /// Sitelinks from which a Wikipedia-only `area` (not a settlement) is kept as Wiki-only; fewer is dropped
    /// (spec 20.6).
    public static let areaSitelinks = 20
    /// An OSM candidate tagged top whose item has fewer sitelinks than this is `good` (spec 20.5).
    public static let osmTopMinSitelinks = 5

    /// The tier of a place, or nil when it must never buzz (no name, or an excluded kind of place).
    /// A candidate without OSM tags (Wikipedia-only) is tiered by its facts when it has them (`factTier`), else by
    /// the tag rules, which give it Wiki-only.
    /// A candidate with OSM tags is tiered by them, with its facts adjusting the result (spec 20.5). Rule order is
    /// fixed: name, never-list, minor memorial (Wiki-only at best, whatever its other tags or facts); a `place` item
    /// with `topSitelinks` or more → Top (also when the tags alone give no tier); Top by tags, or Good lifted to Top
    /// by an article → Top, but Good when the item has fewer than `osmTopMinSitelinks` sitelinks (no facts: Top);
    /// Good → Good, but Wiki-only without an article and without a Wikidata id; else Wiki-only with an article.
    /// A church whose item is also an organisation stays a church: a `nonPlace` class never vetoes tags.
    public static func tier(for candidate: Candidate) -> PlaceTier? {
        guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !hasOSMTags(candidate), let placeClass = candidate.placeClass {
            return factTier(placeClass, sitelinks: candidate.sitelinks ?? 0)
        }
        let tags = candidate.tags ?? [:]
        if isNever(tags) { return nil }
        let article = hasArticle(candidate)

        if isMinorMemorial(tags) { return article ? .wikiOnly : nil }
        if candidate.placeClass == .place, let sitelinks = candidate.sitelinks, sitelinks >= topSitelinks { return .top }
        if isTop(tags) || (isGood(tags) && article) {
            if let sitelinks = candidate.sitelinks, sitelinks < osmTopMinSitelinks { return .good }
            return .top
        }
        if isGood(tags) { return (candidate.wikidata ?? "").isEmpty ? .wikiOnly : .good }
        return article ? .wikiOnly : nil
    }

    /// True when the candidate carries OSM tags (non-nil and not empty), so the tag rules decide its tier.
    public static func hasOSMTags(_ candidate: Candidate) -> Bool {
        !(candidate.tags ?? [:]).isEmpty
    }

    /// True when the tiering drops a named candidate for its Wikidata class alone: no OSM tags, and an item that is
    /// `nonPlace` (an organisation, person or event placed at a building's coordinates), a `settlement`, or an
    /// `area` with fewer than `areaSitelinks` sitelinks. The walk log lists these as `dropped`. A blank name is not
    /// counted: the name rule drops that candidate.
    public static func isDroppedByClass(_ candidate: Candidate) -> Bool {
        guard !hasOSMTags(candidate), let placeClass = candidate.placeClass,
              !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return factTier(placeClass, sitelinks: candidate.sitelinks ?? 0) == nil
    }

    /// The tier of a candidate without OSM tags from its Wikidata facts (spec 19.2, 20.6): `nonPlace` and
    /// `settlement` never buzz; a `place` is Top from `topSitelinks` sitelinks and Good below; an `area` is Wiki-only
    /// from `areaSitelinks` sitelinks and dropped below; an `unknown` item is Wiki-only.
    private static func factTier(_ placeClass: PlaceClass, sitelinks: Int) -> PlaceTier? {
        switch placeClass {
        case .nonPlace, .settlement: nil
        case .place: sitelinks >= topSitelinks ? .top : .good
        case .area: sitelinks >= areaSitelinks ? .wikiOnly : nil
        case .unknown: .wikiOnly
        }
    }

    /// True when Wikipedia knows the place: an article title, a summary (only Wikipedia supplies them) or a Wikipedia-born id.
    public static func hasArticle(_ candidate: Candidate) -> Bool {
        !(candidate.wikipediaTitle ?? "").isEmpty || candidate.summary != nil || candidate.id.hasPrefix("wiki:")
    }

    private static func isNever(_ tags: [String: String]) -> Bool {
        if tags["shop"] != nil || tags["office"] != nil || tags["public_transport"] != nil { return true }
        if let v = tags["amenity"], neverAmenities.contains(v) { return true }
        if let v = tags["tourism"], neverTourism.contains(v) { return true }
        if let v = tags["railway"], neverRailway.contains(v) { return true }
        if let v = tags["building"], neverBuildings.contains(v) { return true }
        return tags["highway"] == "bus_stop"
    }

    /// A plaque, stolperstein or stolperschwelle (`historic=memorial` with that `memorial` value).
    private static func isMinorMemorial(_ tags: [String: String]) -> Bool {
        guard tags["historic"] == "memorial", let v = tags["memorial"] else { return false }
        return minorMemorials.contains(v)
    }

    private static func isTop(_ tags: [String: String]) -> Bool {
        if let v = tags["historic"], topHistoric.contains(v) { return true }
        if let v = tags["building"], topBuildings.contains(v) { return true }
        return tags["castle_type"] == "palace"
    }

    private static func isGood(_ tags: [String: String]) -> Bool {
        if tags["amenity"] == "place_of_worship" { return true }
        if let v = tags["tourism"], goodTourism.contains(v) { return true }
        if let v = tags["historic"] {
            if goodHistoric.contains(v) { return true }
            // Minor memorials returned before this rule.
            if v == "memorial" { return true }
            if v == "building" && tags["heritage"] != nil { return true }
        }
        return tags["place"] == "square" && tags["historic"] != nil
    }
}
