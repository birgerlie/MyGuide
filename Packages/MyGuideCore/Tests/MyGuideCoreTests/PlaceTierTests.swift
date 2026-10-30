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
        // 30 sitelinks inclusive: top; 29 good; 10 inclusive good, 9 Wiki-only (spec 20.2.1).
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 30)) == .top)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 29)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 10)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 9)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: 0)) == .wikiOnly)
        #expect(PlaceTiers.goodSitelinks == 10)
        // A non-street area is dropped whatever its sitelinks (spec 20.2.6).
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 100)) == nil)
        // Unknown is always dropped (spec 20.4.5): Rione Campo Marzio (terrain, 44) goes out.
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 44)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 20)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 0)) == nil)
        // No facts: today's rule (an article without tags is Wiki-only).
        #expect(PlaceTiers.tier(for: Self.wiki(nil)) == .wikiOnly)
        // A class without a sitelink count (never written by the cache) counts as 0 sitelinks.
        #expect(PlaceTiers.tier(for: Self.wiki(.place, sitelinks: nil)) == .wikiOnly)
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
        // Spec 20.6, 20.2.6, 20.4.5: settlements, other areas and unknown items are dropped; streets below 20
        // sitelinks too; a 20-sitelink street is not.
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.settlement, sitelinks: 344)))
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.area, sitelinks: 68)))
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.street, sitelinks: 19)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.street, sitelinks: 20)))
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.unknown, sitelinks: 19)))
        // Spec 20.4.5: an unknown item is dropped whatever its sitelinks.
        #expect(PlaceTiers.isDroppedByClass(Self.wiki(.unknown, sitelinks: 44)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.natural, sitelinks: 1)))
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.settlement, sitelinks: 344, tags: ["place": "city"])))
        // A blank name is dropped by the name rule, not by its class.
        #expect(!PlaceTiers.isDroppedByClass(Self.wiki(.nonPlace, sitelinks: 5, name: " ")))
    }

    // MARK: - Spec 20.6: areas and settlements without tags

    @Test func wikipediaOnlyStreetNeedsTwentySitelinksAndAreasAreDropped() {
        // A street is Wiki-only from 20 sitelinks inclusive (Via del Corso, 30), dropped below (19); a settlement
        // (Rome 344, the rione Pigna 21) or another area (Province of Rome 68) is dropped whatever its sitelinks.
        #expect(PlaceTiers.tier(for: Self.wiki(.street, sitelinks: 30)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.street, sitelinks: 20)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.wiki(.street, sitelinks: 19)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.street, sitelinks: nil)) == nil)
        #expect(PlaceTiers.tier(for: Self.wiki(.area, sitelinks: 68)) == nil)
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
    @Test func osmItemWithFewerThanTenSitelinksIsAtMostWikiOnly() {
        // Spec 20.3.4: Tempio C (historic=ruins, top by tags, 1 sitelink) and the Museo Nazionale del Palazzo di
        // Venezia (museum with an article, top by tags, 8) → Wiki-only; 9 → Wiki-only, 10 → the tag tier again.
        // Without facts (nil) the tags decide.
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .place, sitelinks: 1)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "museum"], wiki: "it:X", .place, sitelinks: 8)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .unknown, sitelinks: 9)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"], .place, sitelinks: 10)) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], .place, sitelinks: 9)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], .place, sitelinks: 10)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "ruins"])) == .top)
        // A Wiki-only tag tier stays Wiki-only; the never-list still vetoes.
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:X", .place, sitelinks: 3)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "bank"], wiki: "it:X", .place, sitelinks: 3)) == nil)
        #expect(PlaceTiers.osmMinSitelinks == 10)
    }
    @Test func osmItemWithoutWikidataIsKeptAsWikiOnlyUnlessAHistoricLandmark() {
        // Spec 20.6.4 (replacing the 20.3.4 drop): Fox Gallery (tourism=gallery), a church, a memorial, a palace
        // without Wikidata id are kept, at most Wiki-only; an empty id is no id; an article (which would lift a good
        // tag tier to top) does not lift past Wiki-only. historic=castle, ruins, archaeological_site and monument keep
        // their tag tier (top).
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wikidata: nil)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wikidata: "")) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"], wiki: "no:X", wikidata: nil)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], wikidata: nil)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.c(["historic": "memorial"], wikidata: nil)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "palace"], wikidata: nil)) == .wikiOnly)
        for value in ["castle", "ruins", "archaeological_site", "monument"] {
            #expect(PlaceTiers.tier(for: Self.osm(["historic": value], wikidata: nil)) == .top, "\(value)")
        }
        // Kept only when the tag rules give a tier at all: the never-list, a plain historic=yes and a plaque without
        // an article stay out.
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "bank"], wiki: "no:X", wikidata: nil)) == nil)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "yes"], wikidata: nil)) == nil)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "memorial", "memorial": "plaque"], wikidata: nil)) == nil)
        // With an id (facts or not) a gallery stays good.
        #expect(PlaceTiers.tier(for: Self.osm(["tourism": "gallery"])) == .good)
        // A Wikipedia-only candidate is not an OSM candidate: no Wikidata id keeps today's Wiki-only.
        #expect(PlaceTiers.tier(for: Self.c(nil, kind: "wikipedia", id: "wiki:en/123", wikidata: nil)) == .wikiOnly)
    }

    // MARK: - Spec 20.2.2: hills and islands are at most good

    @Test func naturalPlacesAreAtMostGood() {
        // Capitoline Hill (68 sitelinks) and Tiber Island (35) are good, not top; one with 9 sitelinks Wiki-only.
        #expect(PlaceTiers.tier(for: Self.wiki(.natural, sitelinks: 68)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.natural, sitelinks: 10)) == .good)
        #expect(PlaceTiers.tier(for: Self.wiki(.natural, sitelinks: 9)) == .wikiOnly)
        // With OSM tags that would make it top (historic=monument with an article), the item caps it at good; a
        // lower tag tier is kept.
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "monument"], wiki: "it:Campidoglio", .natural, sitelinks: 68))
                == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["place": "square"], wiki: "it:X", .natural, sitelinks: 68)) == .wikiOnly)
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "bank"], wiki: "it:X", .natural, sitelinks: 68)) == nil)
    }

    // MARK: - Spec 20.4.5: unknown is dropped for Wikipedia-only items; OSM tags still decide

    @Test func unknownOSMItemsKeepTheirTagTier() {
        // A church whose item is `unknown` (20 sitelinks) is good by its tags; a castle top; a plain historic=yes
        // with an article Wiki-only. Only the Wikipedia-only `unknown` is dropped, and listed as dropped.
        #expect(PlaceTiers.tier(for: Self.osm(["amenity": "place_of_worship"], .unknown, sitelinks: 20)) == .good)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "castle"], .unknown, sitelinks: 44)) == .top)
        #expect(PlaceTiers.tier(for: Self.osm(["historic": "yes"], wiki: "it:X", .unknown, sitelinks: 44)) == .wikiOnly)
        #expect(!PlaceTiers.isDroppedByClass(Self.osm(["historic": "castle"], .unknown, sitelinks: 44)))
        #expect(PlaceTiers.tier(for: Self.wiki(.unknown, sitelinks: 44)) == nil)
    }
}
