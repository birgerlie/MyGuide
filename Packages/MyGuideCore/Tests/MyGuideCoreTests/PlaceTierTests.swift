import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PlaceTierTests {
    /// An OSM candidate with a Wikidata id but no facts, so the tag rules alone decide (spec 20.5 makes a good-tagged
    /// place without article and without Wikidata id Wiki-only; `wikidata: nil` tests that).
    static func c(_ tags: [String: String]?, kind: String = "x", name: String = "Place", wiki: String? = nil,
                  summary: String? = nil, id: String = "osm:node/1", wikidata: String? = "Q1") -> Candidate {
        Candidate(id: id, name: name, coordinate: .init(latitude: 0, longitude: 0), kind: kind,
                  summary: summary, wikipediaTitle: wiki, wikidata: wikidata, tags: tags)
    }
    @Test func top() {
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "city_gate"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "ruins"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship", "building": "cathedral"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle", "castle_type": "palace"])) == .top)
    }
    @Test func goodAndLift() {
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "museum"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "museum"], wiki: "en:Albertina")) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "place_of_worship"], summary: "A church.")) == .top)
    }
    @Test func wikiOnlyNeedsAnArticleAndIsNeverLifted() {
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "plaque"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "plaque"], wiki: "de:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "yes"], wiki: "de:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "artwork"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["man_made": "bridge"], wiki: "en:Charles Bridge")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["place": "square"], wiki: "en:Graben")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia", id: "wiki:en/123")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia", wiki: "en:Y")) == .wikiOnly)
    }
    @Test func neverEvenWithAnArticle() {
        #expect(PlaceTiers.tier(for: Self.c(["shop": "books"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "bank"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["railway": "station"], wiki: "en:Wien Mitte")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["public_transport": "station"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "hotel"], wiki: "en:Hotel Sacher")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "school"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["office": "government"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "castle"], name: "  ")) == nil)
    }

    // Additions: remaining rule branches, boundaries and rule order.
    @Test func goodBranchesNotCoveredAbove() {
        #expect(PlaceTiers.tier(for: Self.c(["historic": "manor"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "church"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "monastery"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "archaeological"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "attraction"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "gallery"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "building", "heritage": "2"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "building"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["place": "square", "historic": "yes"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["place": "square", "historic": "yes"], wiki: "en:X")) == .top)
    }
    @Test func topBranchesNotCoveredAbove() {
        for h in ["castle", "palace", "city_gate", "citywalls", "ruins", "archaeological_site", "monument", "fort", "tower", "battlefield"] {
            #expect(PlaceTiers.tier(for: Self.c(["historic": h])) == .top)
        }
        for b in ["cathedral", "palace", "castle"] {
            #expect(PlaceTiers.tier(for: Self.c(["building": b])) == .top)
        }
        #expect(PlaceTiers.tier(for: Self.c(["castle_type": "palace"])) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["castle_type": "stately"])) == nil)
    }
    @Test func neverListIsExhaustiveAndBeatsTop() {
        for a in ["restaurant", "cafe", "bar", "pub", "fast_food", "ice_cream", "biergarten", "bank", "atm", "school", "college",
                  "university", "kindergarten", "hospital", "clinic", "pharmacy", "embassy", "police", "post_office", "parking", "fuel"] {
            #expect(PlaceTiers.tier(for: Self.c(["amenity": a, "historic": "castle"], wiki: "en:X")) == nil)
        }
        for t in ["hotel", "hostel", "guest_house", "motel", "apartment", "camp_site"] {
            #expect(PlaceTiers.tier(for: Self.c(["tourism": t, "historic": "castle"], wiki: "en:X")) == nil)
        }
        for r in ["station", "halt", "stop", "tram_stop", "subway_entrance"] {
            #expect(PlaceTiers.tier(for: Self.c(["railway": r], wiki: "en:X")) == nil)
        }
        for b in ["train_station", "transportation", "office", "commercial", "retail", "hotel", "school", "university", "hospital"] {
            #expect(PlaceTiers.tier(for: Self.c(["building": b], wiki: "en:X")) == nil)
        }
        #expect(PlaceTiers.tier(for: Self.c(["highway": "bus_stop"], wiki: "en:X")) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["shop": "gift", "historic": "castle"])) == nil)
        // A railway that is not a station-like value (e.g. a historic tram line) is not excluded.
        #expect(PlaceTiers.tier(for: Self.c(["railway": "tram"], wiki: "en:X")) == .wikiOnly)
    }
    @Test func wikiOnlyRemainingKinds() {
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "theatre"], wiki: "en:Burgtheater")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["amenity": "fountain"], wiki: "en:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["highway": "pedestrian"], wiki: "en:Graben")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "artwork"], wiki: "en:X")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["place": "square"])) == nil)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "plaque"], summary: "Text")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia")) == nil)
    }
    @Test func minorMemorialsAreNeverGoodOrTop() {
        for kind in ["plaque", "stolperstein", "stolperschwelle"] {
            let tags = ["historic": "memorial", "memorial": kind]
            #expect(PlaceTiers.tier(for: Self.c(tags)) == nil, "\(kind)")
            // An article makes it wikiOnly at most, never lifted to top.
            #expect(PlaceTiers.tier(for: Self.c(tags, wiki: "de:X")) == .wikiOnly, "\(kind)")
            #expect(PlaceTiers.tier(for: Self.c(tags, summary: "Text")) == .wikiOnly, "\(kind)")
            // Whatever else is tagged: a good tag (tourism=attraction) or a top one does not lift it.
            #expect(PlaceTiers.tier(for: Self.c(tags.merging(["tourism": "attraction"]) { a, _ in a })) == nil, "\(kind)")
            #expect(PlaceTiers.tier(for: Self.c(tags.merging(["building": "cathedral"]) { a, _ in a }, wiki: "de:X"))
                    == .wikiOnly, "\(kind)")
            // The never-list still comes first.
            #expect(PlaceTiers.tier(for: Self.c(tags.merging(["shop": "gift"]) { a, _ in a }, wiki: "de:X")) == nil)
        }
        // Other memorials stay good (lifted to top by an article); the memorial value alone, without
        // historic=memorial, is not a minor memorial.
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "statue"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "war_memorial"], wiki: "en:X")) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial", "memorial": "Plaque"])) == .good)
        #expect(PlaceTiers.tier(for: Self.c(["tourism": "attraction", "memorial": "plaque"])) == .good)
    }
    @Test func articleDetection() {
        #expect(PlaceTiers.hasArticle(Self.c([:], wiki: "en:X")))
        #expect(PlaceTiers.hasArticle(Self.c([:], summary: "s")))
        #expect(PlaceTiers.hasArticle(Self.c([:], id: "wiki:en/1")))
        #expect(!PlaceTiers.hasArticle(Self.c([:])))
        #expect(!PlaceTiers.hasArticle(Self.c([:], wiki: "")))
        #expect(!PlaceTiers.hasArticle(Self.c([:], id: "osm:node/1")))
    }
    @Test func tierOrderingAndWalkingPlace() {
        #expect(PlaceTier.top < .good && PlaceTier.good < .wikiOnly)
        let p = WalkingPlace(candidate: Self.c(nil), tier: .good)
        #expect(p == WalkingPlace(candidate: Self.c(nil), tier: .good))
        #expect(p != WalkingPlace(candidate: Self.c(nil), tier: .top))
    }

    // MARK: - Wikidata facts (spec 19.2)

    /// A Wikipedia-only candidate (no tags, wiki id) with optional facts.
    static func wiki(_ placeClass: PlaceClass?, sitelinks: Int? = nil, name: String = "Article",
                     tags: [String: String]? = nil) -> Candidate {
        Candidate(id: "wiki:it/1", name: name, coordinate: .init(latitude: 0, longitude: 0), kind: "wikipedia",
                  summary: "Text.", wikipediaTitle: "it:\(name)", wikidata: "Q1", tags: tags,
                  sitelinks: sitelinks, placeClass: placeClass)
    }
    @Test func wikipediaOnlyTierFromFacts() {
        #expect(PlaceTiers.tier(for: Self.wiki(.nonPlace, sitelinks: 119)) == nil)
        // The threshold is 30 sitelinks inclusive: 30 is top, 29 is good.
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 30)) == .top)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 29)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 0)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 100)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 44)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 0)) == .wikiOnly)
        // No facts: today's rule (an article without tags is Wiki-only).
        #expect(PlaceTiers.tier(for: Self.wiki(nil)) == .wikiOnly)
        // A class without a sitelink count (never written by the cache) counts as 0 sitelinks.
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: nil)) == .good)
        #expect(PlaceTiers.topSitelinks == 30)
    }
    @Test func emptyTagsCountAsNoTags() {
        // Controller ruling: "OSM tags present" is non-nil and non-empty.
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 40, tags: [:])) == .top)
        #expect(PlaceTiers.tier(for: Self.wiki(.nonPlace, sitelinks: 40, tags: [:])) == nil)
        #expect(!PlaceTiers.hasOSMTags(Self.wiki(nil, tags: [:])))
        #expect(!PlaceTiers.hasOSMTags(Self.wiki(nil)))
        #expect(PlaceTiers.hasOSMTags(Self.wiki(nil, tags: ["historic": "yes"])))
    }
    @Test func osmTagsDecideWhateverTheFacts() {
        // A church whose Wikidata item is (also) an organisation: the tags make it good, its article lifts it to top.
        let church = Candidate(id: "osm:way/1", name: "Il Gesù", coordinate: .init(latitude: 0, longitude: 0),
                               kind: "amenity=place_of_worship", wikidata: "Q1",
                               tags: ["amenity": "place_of_worship"], sitelinks: 40, placeClass: .nonPlace)
        #expect(PlaceTiers.tier(for: church) == .good)
        var withArticle = church
        withArticle.wikipediaTitle = "it:Chiesa del Gesù"
        #expect(PlaceTiers.tier(for: withArticle) == .top)
        #expect(!PlaceTiers.isDroppedByClass(church))
        // A `place` item with many sitelinks does not lift a never-listed OSM place: the tags decide.
        let bank = Candidate(id: "osm:node/2", name: "Bank", coordinate: .init(latitude: 0, longitude: 0), kind: "x",
                             wikidata: "Q2", tags: ["amenity": "bank"], sitelinks: 90, placeClass: .place)
        #expect(PlaceTiers.tier(for: bank) == nil)
        // A plain historic=yes without an article stays untiered with a `place` item below 30 sitelinks (spec 20.5
        // lifts one with 30 or more: `osmPlaceWithThirtySitelinksIsAtLeastTop`).
        let stone = Candidate(id: "osm:node/3", name: "Stone", coordinate: .init(latitude: 0, longitude: 0), kind: "x",
                              wikidata: "Q3", tags: ["historic": "yes"], sitelinks: 29, placeClass: .place)
        #expect(PlaceTiers.tier(for: stone) == nil)
    }
    @Test func blankNameNeverBuzzesEvenAsATopPlace() {
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 99, name: "  ")) == nil)
    }
    @Test func droppedByClassOnlyWithoutTags() {
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.nonPlace, sitelinks: 5)))
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.nonPlace, sitelinks: 5, tags: [:])))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.nonPlace, sitelinks: 5, tags: ["historic": "yes"])))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.place, sitelinks: 5)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(nil)))
        // Spec 20.6: settlements and small areas are dropped too; a big area and an unknown item are not.
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.settlement, sitelinks: 344)))
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.area, sitelinks: 19)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.area, sitelinks: 20)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.unknown, sitelinks: 0)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.settlement, sitelinks: 344, tags: ["place": "city"])))
        // A blank name is dropped by the name rule, not by its class.
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.nonPlace, sitelinks: 5, name: " ")))
    }

    // MARK: - Spec 20.6: areas and settlements without tags

    @Test func wikipediaOnlyAreaNeedsTwentySitelinksAndSettlementsAreDropped() {
        // An area is Wiki-only from 20 sitelinks inclusive (Via del Corso, 30), dropped below (19); a settlement
        // (Rome 344, the rione Pigna 21) is dropped whatever its sitelinks.
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 30)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 20)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 19)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: nil)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.settlement, sitelinks: 344)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.settlement, sitelinks: 21)) == nil)
        #expect(PlaceTiers.areaSitelinks == 20)
    }

    // MARK: - Spec 20.5: OSM tags and facts

    /// An OSM candidate with tags, optional article, Wikidata id and facts.
    static func osm(_ tags: [String: String], wiki: String? = nil, wikidata: String? = "Q1",
                    _ placeClass: PlaceClass? = nil, sitelinks: Int? = nil) -> Candidate {
        Candidate(id: "osm:way/1", name: "Place", coordinate: .init(latitude: 0, longitude: 0), kind: "x",
                  wikipediaTitle: wiki, wikidata: wikidata, tags: tags, sitelinks: sitelinks, placeClass: placeClass)
    }
    @Test func osmPlaceWithThirtySitelinksIsAtLeastTop() {
        // Piazza Venezia as an OSM candidate: place=square without historic, an article → Wiki-only by tags; its
        // item is a place with 38 sitelinks → top. 30 is inclusive, 29 keeps the tag tier.
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:Piazza Venezia", .place, sitelinks: 38)) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:X", .place, sitelinks: 30)) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:X", .place, sitelinks: 29)) == .wikiOnly)
        // A church (good by tags, no article) with a 30-sitelink place item → top.
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], .place, sitelinks: 30)) == .top)
        // Even untiered by tags (historic=yes, no article): a well-known place is top.
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "yes"], .place, sitelinks: 50)) == .top)
        // Only a `place` item lifts: a non-place or unknown item with many sitelinks keeps the tag tier.
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], .nonPlace, sitelinks: 90)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:X", .unknown, sitelinks: 90)) == .wikiOnly)
        // The never-list and the minor-memorial rule still veto.
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "bank"], wiki: "it:X", .place, sitelinks: 90)) == nil)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "memorial", "memorial": "plaque"], wiki: "it:X", .place,
                                              sitelinks: 90)) == .wikiOnly)
    }
    @Test func osmTopWithFewerThanFiveSitelinksIsGood() {
        // Tempio C: historic=ruins (top by tags) with 1 sitelink → good. 5 is top again; no facts (nil) stays top.
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .place, sitelinks: 1)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .unknown, sitelinks: 4)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .place, sitelinks: 5)) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"])) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], wikidata: nil)) == .top)
        // Good lifted to top by an article counts as tagged top: 4 sitelinks → good, 8 (Museo Nazionale del
        // Palazzo di Venezia) stays top.
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "museum"], wiki: "it:X", .place, sitelinks: 4)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "museum"], wiki: "it:X", .place, sitelinks: 8)) == .top)
        #expect(PlaceTiers.osmTopMinSitelinks == 5)
    }
    @Test func osmGoodWithoutArticleOrWikidataIsWikiOnly() {
        // Fox Gallery: tourism=gallery, no article, no Wikidata id → Wiki-only. An empty id is no id. With an id
        // (facts or not) it stays good; with an article it is lifted to top as before.
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wikidata: nil)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wikidata: "")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"])) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], .place, sitelinks: 2)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wiki: "it:X", wikidata: nil)) == .top)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial"], wikidata: nil)) == .wikiOnly)
    }
}
