import Foundation

/// One Wikipedia geosearch: a circle around `centre` of `radius` whole metres, at most
/// `WikipediaClient.maxGeosearchRadius`.
public struct GeosearchTile: Sendable, Equatable {
    public var centre: Coordinate
    public var radius: Int

    public init(centre: Coordinate, radius: Int) {
        self.centre = centre
        self.radius = radius
    }
}

/// Where a tour looks for places (spec 4): a circle around the start for a loop, and for A→B the bounding box of the
/// straight line, padded on every side.
public enum TourArea: Sendable, Equatable {
    case loop(centre: Coordinate, radius: Double)
    /// The bounding box of the line from `from` to `to`, widened by `padding` metres on each side.
    case corridor(from: Coordinate, to: Coordinate, padding: Double)

    /// Walking speed in m/s (global constraint): the single constant for tours; the planner (T2) reuses it.
    public static let walkingSpeed = 1.3
    public static let maxLoopRadius = 2500.0
    /// The share of the line's length that pads an A→B corridor on each side.
    public static let corridorPadding = 0.3
    /// The most Wikipedia geosearches one area costs (spec 4).
    public static let maxTiles = 4

    /// Metres per degree of latitude, from the radius `GeoMath` uses.
    private static let metresPerDegree = GeoMath.earthRadius * .pi / 180
    /// Floating-point noise below this many metres does not round a tile radius up to the next metre.
    private static let roundingTolerance = 1e-6

    /// A loop of `minutes`: radius `min(2500, 1.3 × seconds / 2.5)` m, so the far side is reachable with time to spare
    /// for the way back and the stops. A negative duration counts as 0.
    public static func loop(from start: Coordinate, minutes: Int) -> TourArea {
        let seconds = Double(max(0, minutes)) * 60
        return .loop(centre: start, radius: min(maxLoopRadius, walkingSpeed * seconds / 2.5))
    }

    /// An A→B corridor padded by 30 % of the straight line's length.
    public static func corridor(from: Coordinate, to: Coordinate) -> TourArea {
        .corridor(from: from, to: to, padding: corridorPadding * GeoMath.distance(from, to))
    }

    /// The box around the area in degrees. Longitude padding is converted at the latitude farthest from the equator
    /// (the loop's centre, the corridor's line end nearest a pole), so it is never narrower than the padding there.
    /// A negative or NaN padding (or loop radius) counts as 0. Areas that cross the antimeridian or reach a pole are
    /// not supported.
    public var boundingBox: (south: Double, west: Double, north: Double, east: Double) {
        switch self {
        case .loop(let centre, let radius):
            return Self.padded(south: centre.latitude, west: centre.longitude, north: centre.latitude,
                               east: centre.longitude, by: radius)
        case .corridor(let from, let to, let padding):
            return Self.padded(south: min(from.latitude, to.latitude), west: min(from.longitude, to.longitude),
                               north: max(from.latitude, to.latitude), east: max(from.longitude, to.longitude),
                               by: padding)
        }
    }

    /// A loop holds what lies within its radius of the centre; a corridor holds its whole box. Plain comparisons, not
    /// ranges, so a NaN coordinate or an inverted box gives false instead of trapping.
    public func contains(_ c: Coordinate) -> Bool {
        switch self {
        case .loop(let centre, let radius):
            return GeoMath.distance(centre, c) <= radius
        case .corridor:
            let box = boundingBox
            return c.latitude >= box.south && c.latitude <= box.north && c.longitude >= box.west && c.longitude <= box.east
        }
    }

    /// The Wikipedia geosearches that cover the area. A loop within the geosearch maximum is its own circle. Anything
    /// else is a grid over the box of at most `maxTiles` tiles, each searched from its centre out to its farthest
    /// corner: the grid with the fewest tiles whose every tile fits the maximum radius (ties: the smaller radius), or,
    /// when none fits, the grid with the smallest radius, cut to the maximum (the corners then go unsearched).
    /// Tiles run from the south-west corner, west to east, then row by row northwards.
    public var wikipediaTiles: [GeosearchTile] {
        let maxRadius = Double(WikipediaClient.maxGeosearchRadius)
        if case .loop(let centre, let radius) = self, radius <= maxRadius {
            return [GeosearchTile(centre: centre, radius: Self.wholeMetres(radius))]
        }
        let box = boundingBox
        // (columns, rows); listed fewest tiles first so the stable minimum prefers fewer requests on a tie.
        let layouts = [(1, 1), (2, 1), (1, 2), (3, 1), (1, 3), (2, 2), (4, 1), (1, 4)]
        let grids = layouts.map { Self.grid(box, columns: $0.0, rows: $0.1) }
        // Compared in unrounded metres, so layouts beyond the maximum still rank by how far beyond they are.
        let fitting = grids.filter { Self.largestReach($0) - Self.roundingTolerance <= maxRadius }
        let chosen: [(centre: Coordinate, reach: Double)]
        if let best = fitting.min(by: { ($0.count, Self.largestReach($0)) < ($1.count, Self.largestReach($1)) }) {
            chosen = best
        } else {
            // `layouts` is not empty, so neither is `grids`.
            chosen = grids.min { (Self.largestReach($0), $0.count) < (Self.largestReach($1), $1.count) } ?? grids[0]
        }
        return chosen.map { GeosearchTile(centre: $0.centre, radius: Self.wholeMetres($0.reach)) }
    }

    /// Metres rounded up to a whole metre, ignoring floating-point noise (1404.0000000000002 → 1404), and cut to the
    /// geosearch maximum. Not finite or not positive → 0, so no value can trap the `Int` conversion.
    static func wholeMetres(_ metres: Double) -> Int {
        guard metres.isFinite, metres > 0 else { return 0 }
        let capped = min(metres, Double(WikipediaClient.maxGeosearchRadius))
        return max(0, Int((capped - roundingTolerance).rounded(.up)))
    }

    private static func padded(south: Double, west: Double, north: Double, east: Double,
                               by metres: Double) -> (south: Double, west: Double, north: Double, east: Double) {
        let metres = metres.isNaN ? 0 : max(0, metres)
        let latitude = max(abs(south), abs(north))
        let dLat = metres / metresPerDegree
        let dLon = metres / (metresPerDegree * cos(latitude * .pi / 180))
        return (south - dLat, west - dLon, north + dLat, east + dLon)
    }

    /// The box cut into equal cells (in degrees), each with its centre and the metres to its farthest corner.
    private static func grid(_ box: (south: Double, west: Double, north: Double, east: Double),
                             columns: Int, rows: Int) -> [(centre: Coordinate, reach: Double)] {
        let width = (box.east - box.west) / Double(columns), height = (box.north - box.south) / Double(rows)
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let south = box.south + Double(row) * height, west = box.west + Double(column) * width
                let centre = Coordinate(latitude: south + height / 2, longitude: west + width / 2)
                let corners = [(south, west), (south, west + width), (south + height, west), (south + height, west + width)]
                let reach = corners.map { GeoMath.distance(centre, Coordinate(latitude: $0.0, longitude: $0.1)) }.max() ?? 0
                return (centre, reach)
            }
        }
    }

    private static func largestReach(_ tiles: [(centre: Coordinate, reach: Double)]) -> Double {
        tiles.map(\.reach).max() ?? 0
    }
}
