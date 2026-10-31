import Foundation

/// How «Rundt deg» frames a place the owner picks in the nearby list (spec 16, amended 2026-10-31): the owner and the
/// place together, with room around them, so the map shows where it is and which way to go. Never closer in than the
/// map's usual framing of the owner.
public enum MapFocus {
    /// What the map shows: its centre and its extent in metres north–south and east–west.
    public struct Frame: Sendable, Equatable {
        public var centre: Coordinate
        public var northSouthMetres: Double
        public var eastWestMetres: Double
    }

    /// The span is the owner–place extent times this, so neither sits on the edge.
    public static let margin: Double = 1.6
    /// The least span either way, in metres: the map's usual framing of the owner (`AroundMap.ownerSpan`).
    public static let minimumSpan: Double = 600
    /// Metres per degree of latitude (and of longitude at the equator).
    static let metresPerDegree: Double = 111_320

    /// The owner and the place framed together; without the owner's position, the place alone at `minimumSpan`.
    /// The centre is the plain average of the two, which is right for places in walking distance (not across 180°).
    public static func frame(owner: Coordinate?, place: Coordinate) -> Frame {
        guard let owner else {
            return Frame(centre: place, northSouthMetres: minimumSpan, eastWestMetres: minimumSpan)
        }
        let centre = Coordinate(latitude: (owner.latitude + place.latitude) / 2,
                                longitude: (owner.longitude + place.longitude) / 2)
        let northSouth = abs(owner.latitude - place.latitude) * metresPerDegree
        let eastWest = abs(owner.longitude - place.longitude) * metresPerDegree
            * cos(centre.latitude * .pi / 180)
        return Frame(centre: centre,
                     northSouthMetres: max(northSouth * margin, minimumSpan),
                     eastWestMetres: max(eastWest * margin, minimumSpan))
    }
}
