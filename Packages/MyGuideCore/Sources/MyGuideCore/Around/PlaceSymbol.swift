import Foundation

/// The SF Symbol a place shows on the «Rundt deg» map and, without a picture, on its card (spec 5, 10, 16.7).
/// Parks and fountains are not on the map (spec 12.8), so they have no row.
public enum PlaceSymbol {
    /// The symbol for a place without a row of its own.
    public static let generic = "mappin"

    /// The first row whose values meet the place's kind values wins, so the order decides a place with mixed tags
    /// (a castle that is also a museum shows as a castle).
    public static func systemName(for candidate: Candidate) -> String {
        let values = kindValues(of: candidate)
        for row in rows where !row.values.isDisjoint(with: values) { return row.symbol }
        return generic
    }

    // MARK: - Private

    /// The tag keys that say what kind of place it is. Values under other keys (a name, a description) never count.
    private static let kindKeys: Set<String> = [
        "historic", "building", "amenity", "tourism", "man_made", "memorial", "castle_type",
    ]

    private static let rows: [(values: Set<String>, symbol: String)] = [
        (["castle", "palace", "fort", "city_gate", "citywalls"], "building.columns"),
        (["church", "cathedral", "place_of_worship", "monastery"], "building.2"),
        (["monument", "memorial", "statue"], "figure.stand"),
        (["museum", "gallery"], "photo.artframe"),
        (["ruins", "archaeological_site", "battlefield"], "mountain.2"),
        (["tower"], "antenna.radiowaves.left.and.right"),
    ]

    /// The values of the kind keys in the place's tags, plus the value of its "key=value" kind when that key is a
    /// kind key (groundings stored before tags existed carry only the kind).
    private static func kindValues(of candidate: Candidate) -> Set<String> {
        var values = Set((candidate.tags ?? [:]).compactMap { kindKeys.contains($0.key) ? $0.value : nil })
        let parts = candidate.kind.split(separator: "=", maxSplits: 1)
        if parts.count == 2, kindKeys.contains(String(parts[0])) { values.insert(String(parts[1])) }
        return values
    }
}
