import Foundation

public enum CandidateRanker {
    public static let maxCandidates = 15
    /// Candidates with the same name closer than this (metres) are the same place.
    public static let duplicateRadius = 50.0

    /// Merges OpenStreetMap and Wikipedia candidates. OSM candidates come first and keep their identity;
    /// a Wikipedia candidate with the same wikidata id or article title is folded into the OSM one
    /// (supplying its summary if the OSM one has none). Same-name candidates within `duplicateRadius` are dropped.
    /// Lookups are bucketed (by lowercased name, wikidata id and article title) so a tour area's thousands of places
    /// merge in linear time; the result is the same as comparing every pair in order.
    public static func merge(osm: [Candidate], wiki: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        /// Indices into `kept` by lowercased name, in insertion order, so the first twin still wins.
        var keptByName: [String: [Int]] = [:]

        /// Adds `c` unless a same-name twin is already kept; a dropped candidate donates missing fields to its twin.
        func add(_ c: Candidate) {
            let name = c.name.lowercased()
            guard let twin = keptByName[name]?.first(where: {
                GeoMath.distance(kept[$0].coordinate, c.coordinate) <= duplicateRadius
            }) else {
                keptByName[name, default: []].append(kept.count)
                kept.append(c)
                return
            }
            if kept[twin].summary == nil {
                kept[twin].summary = c.summary
                kept[twin].summaryLanguage = c.summaryLanguage
            }
            if kept[twin].wikidata == nil { kept[twin].wikidata = c.wikidata }
            if kept[twin].wikipediaTitle == nil { kept[twin].wikipediaTitle = c.wikipediaTitle }
            if kept[twin].tags == nil { kept[twin].tags = c.tags }
        }

        var wikiByQ: [String: [Int]] = [:], wikiByTitle: [String: [Int]] = [:]
        for (i, w) in wiki.enumerated() {
            if let q = w.wikidata { wikiByQ[q, default: []].append(i) }
            if let title = w.wikipediaTitle { wikiByTitle[title, default: []].append(i) }
        }

        // Every OSM candidate may match (differently named parts of one site share an article);
        // matched articles are consumed only after the loop.
        var consumed = Set<Int>()
        for var o in osm {
            let byQ = o.wikidata.flatMap { wikiByQ[$0] } ?? []
            let byTitle = o.wikipediaTitle.flatMap { wikiByTitle[$0] } ?? []
            // In article order, as a pairwise scan would meet them: the first match supplies a missing summary.
            for i in Set(byQ + byTitle).sorted() {
                consumed.insert(i)
                if o.summary == nil {
                    o.summary = wiki[i].summary
                    o.summaryLanguage = wiki[i].summaryLanguage
                }
            }
            add(o)
        }
        for (i, w) in wiki.enumerated() where !consumed.contains(i) { add(w) }
        return kept
    }

    /// Orders candidates in-view first (when the heading is usable); within each view group, places with
    /// Wikipedia backing (wikidata, article title or summary) before those without, so plaques cannot crowd
    /// out landmarks; then nearest first. Caps the list.
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
            let aBacked = hasWikiBacking(a.candidate), bBacked = hasWikiBacking(b.candidate)
            if aBacked != bBacked { return aBacked }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.candidate.id < b.candidate.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// True when the candidate has something to tell beyond its name; empty strings do not count.
    static func hasWikiBacking(_ c: Candidate) -> Bool {
        [c.wikidata, c.wikipediaTitle, c.summary].contains { !($0?.isEmpty ?? true) }
    }
}
