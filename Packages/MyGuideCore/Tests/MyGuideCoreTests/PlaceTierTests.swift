import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PlaceTierTests {
    static func c(_ tags: [String: String]?, kind: String = "x", name: String = "Place", wiki: String? = nil,
                  summary: String? = nil, id: String = "osm:node/1") -> Candidate {
        Candidate(id: id, name: name, coordinate: .init(latitude: 0, longitude: 0), kind: kind,
                  summary: summary, wikipediaTitle: wiki, wikidata: nil, tags: tags)
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
}
