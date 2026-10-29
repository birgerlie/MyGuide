import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PlaceSymbolTests {
    private func place(kind: String = "wikipedia", tags: [String: String]? = nil) -> Candidate {
        Candidate(id: "osm:node/1", name: "P", coordinate: Coordinate(latitude: 0, longitude: 0), kind: kind, tags: tags)
    }

    @Test func fortifiedAndRoyalBuildings() {
        for tags in [["historic": "castle"], ["historic": "palace"], ["historic": "fort"], ["historic": "city_gate"],
                     ["historic": "citywalls"], ["building": "castle"], ["building": "palace"],
                     ["castle_type": "palace"]] {
            #expect(PlaceSymbol.systemName(for: place(tags: tags)) == "building.columns", "\(tags)")
        }
    }

    @Test func churches() {
        for tags in [["historic": "church"], ["building": "cathedral"], ["building": "church"],
                     ["amenity": "place_of_worship"], ["historic": "monastery"]] {
            #expect(PlaceSymbol.systemName(for: place(tags: tags)) == "building.2", "\(tags)")
        }
    }

    @Test func monumentsMemorialsStatues() {
        for tags in [["historic": "monument"], ["historic": "memorial"], ["historic": "memorial", "memorial": "statue"],
                     ["memorial": "statue"]] {
            #expect(PlaceSymbol.systemName(for: place(tags: tags)) == "figure.stand", "\(tags)")
        }
    }

    @Test func museumsAndGalleries() {
        #expect(PlaceSymbol.systemName(for: place(tags: ["tourism": "museum"])) == "photo.artframe")
        #expect(PlaceSymbol.systemName(for: place(tags: ["tourism": "gallery"])) == "photo.artframe")
    }

    @Test func ruinsSitesBattlefields() {
        for tags in [["historic": "ruins"], ["historic": "archaeological_site"], ["historic": "battlefield"]] {
            #expect(PlaceSymbol.systemName(for: place(tags: tags)) == "mountain.2", "\(tags)")
        }
    }

    @Test func towers() {
        #expect(PlaceSymbol.systemName(for: place(tags: ["historic": "tower"])) == "antenna.radiowaves.left.and.right")
        #expect(PlaceSymbol.systemName(for: place(tags: ["man_made": "tower"])) == "antenna.radiowaves.left.and.right")
    }

    @Test func everythingElseIsAPin() {
        // Wikipedia-only (no tags), an attraction, a manor and an empty tag set have no symbol of their own.
        #expect(PlaceSymbol.systemName(for: place()) == "mappin")
        #expect(PlaceSymbol.systemName(for: place(tags: ["tourism": "attraction"])) == "mappin")
        #expect(PlaceSymbol.systemName(for: place(tags: ["historic": "manor"])) == "mappin")
        #expect(PlaceSymbol.systemName(for: place(tags: [:])) == "mappin")
        // Values under keys that do not describe the kind of place are ignored.
        #expect(PlaceSymbol.systemName(for: place(tags: ["name": "tower", "description": "church"])) == "mappin")
    }

    @Test func kindIsUsedWithoutTags() {
        // Groundings stored before tags existed carry only the "key=value" kind.
        #expect(PlaceSymbol.systemName(for: place(kind: "historic=fort")) == "building.columns")
        #expect(PlaceSymbol.systemName(for: place(kind: "tourism=museum")) == "photo.artframe")
        // A kind under a key that does not describe the place, or without "=", is ignored.
        #expect(PlaceSymbol.systemName(for: place(kind: "name=tower")) == "mappin")
        #expect(PlaceSymbol.systemName(for: place(kind: "castle")) == "mappin")
    }

    @Test func tableOrderDecidesMixedTags() {
        // A castle that is also a museum shows as a castle; a church with a museum as a church; a ruined church as a
        // church (churches come before ruins); a tower monument as a monument.
        #expect(PlaceSymbol.systemName(for: place(tags: ["historic": "castle", "tourism": "museum"])) == "building.columns")
        #expect(PlaceSymbol.systemName(for: place(tags: ["building": "church", "tourism": "museum"])) == "building.2")
        #expect(PlaceSymbol.systemName(for: place(tags: ["historic": "ruins", "building": "church"])) == "building.2")
        #expect(PlaceSymbol.systemName(for: place(tags: ["historic": "monument", "man_made": "tower"])) == "figure.stand")
    }
}
