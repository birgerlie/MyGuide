import Foundation

/// Lines on the map as coordinate arrays.
public enum GeoPolyline {
    /// `path` with the points that add less than `tolerance` metres of shape left out (Douglas–Peucker): every kept
    /// stretch stays within `tolerance` of the original points it replaces. The ends are always kept. Distances are
    /// measured on a flat projection around the first point (equirectangular), exact enough for walking routes of a
    /// few kilometres, and to the segment (not the infinite line), so a turn back is never taken for a straight.
    /// Fewer than 3 points, or a tolerance that is not a positive number, give `path` unchanged.
    public static func simplified(_ path: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard path.count >= 3, tolerance.isFinite, tolerance > 0 else { return path }
        let origin = path[0]
        let metresPerDegree = GeoMath.earthRadius * .pi / 180
        let xScale = cos(origin.latitude * .pi / 180) * metresPerDegree
        let points = path.map {
            (x: ($0.longitude - origin.longitude) * xScale, y: ($0.latitude - origin.latitude) * metresPerDegree)
        }

        var keep = [Bool](repeating: false, count: path.count)
        keep[0] = true
        keep[path.count - 1] = true
        // A stack of (first, last) index ranges instead of recursion, so a long path cannot overflow the stack.
        var ranges = [(0, path.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last - first >= 2 else { continue }
            var farthest = first, maxDistance = -1.0
            for index in (first + 1)..<last {
                let d = distance(points[index], toSegment: points[first], points[last])
                if d > maxDistance {
                    maxDistance = d
                    farthest = index
                }
            }
            guard maxDistance > tolerance else { continue }
            keep[farthest] = true
            ranges.append((first, farthest))
            ranges.append((farthest, last))
        }
        return path.indices.filter { keep[$0] }.map { path[$0] }
    }

    /// The distance from `p` to the segment `a`–`b` in the plane; to `a` when the segment has no length.
    private static func distance(_ p: (x: Double, y: Double), toSegment a: (x: Double, y: Double),
                                 _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
