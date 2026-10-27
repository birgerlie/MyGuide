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

    /// The tier of a place, or nil when it must never buzz (no name, or an excluded kind of place).
    /// Rule order is fixed: name, never-list, Top, Good (lifted to Top by an article), Wiki-only (needs an article).
    public static func tier(for candidate: Candidate) -> PlaceTier? {
        guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tags = candidate.tags ?? [:]
        if isNever(tags) { return nil }
        let article = hasArticle(candidate)

        if isTop(tags) { return .top }
        if isGood(tags) { return article ? .top : .good }
        return article ? .wikiOnly : nil
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
            if v == "memorial" && tags["memorial"] != "plaque" { return true }
            if v == "building" && tags["heritage"] != nil { return true }
        }
        return tags["place"] == "square" && tags["historic"] != nil
    }
}
