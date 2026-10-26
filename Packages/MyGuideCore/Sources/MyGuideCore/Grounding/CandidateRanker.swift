import Foundation

public enum CandidateRanker {
    public static let maxCandidates = 15
    /// Candidates with the same name closer than this (metres) are the same place.
    public static let duplicateRadius = 50.0

    /// Merges OpenStreetMap and Wikipedia candidates. OSM candidates come first and keep their identity;
    /// a Wikipedia candidate with the same wikidata id or article title is folded into the OSM one
    /// (supplying its summary if the OSM one has none). Same-name candidates within `duplicateRadius` are dropped.
    public static func merge(osm: [Candidate], wiki: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []

        /// Adds `c` unless a same-name twin is already kept; a dropped candidate donates missing fields to its twin.
        func add(_ c: Candidate) {
            let name = c.name.lowercased()
            guard let twin = kept.firstIndex(where: {
                $0.name.lowercased() == name && GeoMath.distance($0.coordinate, c.coordinate) <= duplicateRadius
            }) else {
                kept.append(c)
                return
            }
            if kept[twin].summary == nil { kept[twin].summary = c.summary }
            if kept[twin].wikidata == nil { kept[twin].wikidata = c.wikidata }
            if kept[twin].wikipediaTitle == nil { kept[twin].wikipediaTitle = c.wikipediaTitle }
        }

        // Every OSM candidate may match (differently named parts of one site share an article);
        // matched articles are consumed only after the loop.
        var consumed = Set<Int>()
        for var o in osm {
            for (i, w) in wiki.enumerated() {
                let sameQ = o.wikidata != nil && o.wikidata == w.wikidata
                let sameTitle = o.wikipediaTitle != nil && o.wikipediaTitle == w.wikipediaTitle
                guard sameQ || sameTitle else { continue }
                consumed.insert(i)
                if o.summary == nil { o.summary = w.summary }
            }
            add(o)
        }
        for (i, w) in wiki.enumerated() where !consumed.contains(i) { add(w) }
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
