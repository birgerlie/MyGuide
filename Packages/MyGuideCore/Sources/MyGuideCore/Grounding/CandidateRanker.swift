import Foundation

public enum CandidateRanker {
    public static let maxCandidates = 15
    /// Candidates with the same name closer than this (metres) are the same place.
    public static let duplicateRadius = 50.0

    /// Merges OpenStreetMap and Wikipedia candidates. OSM candidates come first and keep their identity;
    /// a Wikipedia candidate with the same wikidata id or article title is folded into the OSM one
    /// (supplying its summary if the OSM one has none). Same-name candidates within `duplicateRadius` are dropped.
    public static func merge(osm: [Candidate], wiki: [Candidate]) -> [Candidate] {
        var consumed = Set<Int>()
        var kept: [Candidate] = []

        func isDuplicate(_ c: Candidate) -> Bool {
            let name = c.name.lowercased()
            return kept.contains { $0.name.lowercased() == name && GeoMath.distance($0.coordinate, c.coordinate) <= duplicateRadius }
        }

        for var o in osm {
            let match = wiki.indices.first { i in
                guard !consumed.contains(i) else { return false }
                let w = wiki[i]
                if let q = o.wikidata, q == w.wikidata { return true }
                if let t = o.wikipediaTitle, t == w.wikipediaTitle { return true }
                return false
            }
            if let match {
                consumed.insert(match)
                if o.summary == nil { o.summary = wiki[match].summary }
            }
            if !isDuplicate(o) { kept.append(o) }
        }
        for (i, w) in wiki.enumerated() where !consumed.contains(i) {
            if !isDuplicate(w) { kept.append(w) }
        }
        return kept
    }

    /// Orders candidates in-view first (when the heading is usable), then nearest first, and caps the list.
    public static func rank(_ candidates: [Candidate], capture: CaptureContext, limit: Int = maxCandidates) -> [RankedCandidate] {
        guard let origin = capture.coordinate else { return [] }
        let heading = capture.usableHeading
        // usableHeading non-nil implies headingAccuracy non-nil.
        let halfWidth = heading != nil
            ? FieldOfView.coneHalfWidth(horizontalFOV: capture.horizontalFOV, headingAccuracy: capture.headingAccuracy ?? 0)
            : 0

        let ranked = candidates.map { c -> RankedCandidate in
            let bearing = GeoMath.bearing(from: origin, to: c.coordinate)
            let inView = heading.map { FieldOfView.isInView(bearing: bearing, heading: $0, halfWidth: halfWidth) }
            return RankedCandidate(candidate: c, distance: GeoMath.distance(origin, c.coordinate), bearing: bearing, inView: inView)
        }
        let sorted = ranked.sorted { a, b in
            if a.inView != b.inView { return a.inView == true }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.candidate.id < b.candidate.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }
}
