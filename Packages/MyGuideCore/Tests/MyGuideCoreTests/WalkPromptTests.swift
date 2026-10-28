import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkPromptTests {
    static let origin = Coordinate(latitude: 0, longitude: 0)
    static func place(_ id: String, _ name: String, _ kind: String, north: Double, tier: PlaceTier, summary: String? = nil) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: name, coordinate: .at(north: north), kind: kind, summary: summary), tier: tier)
    }
    static let gate = place("osm:node/1", "Michaelertor", "historic=city_gate", north: 50, tier: .top, summary: "Gate of the palace.")
    static let church = place("osm:node/2", "Peterskirche", "amenity=place_of_worship", north: 80, tier: .good)
    static let plaque = place("osm:node/3", "Mozart plaque", "historic=memorial", north: 30, tier: .wikiOnly)
    static let castle = place("osm:node/4", "Hofburg", "historic=castle", north: 200, tier: .top)
    static let facts = [gate, church, plaque, castle]
    static let buzz = Buzz(id: UUID(), place: gate, distance: 50, bearing: 0, title: "Michaelertor", detail: "50 m left", usedOverride: false)
    static let prior = PriorStory(placeID: "osm:node/1", level: .first, text: "Told before.", toldAt: .now)

    @Test func buzzInputHasEveryRequiredLine() {
        let text = PromptBuilder.walkBuzzInput(buzz: Self.buzz, course: 90, facts: Self.facts, position: Self.origin, priors: [Self.prior])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("The listener is walking, not looking at a photo. Tell the story of the place they are passing."))
        #expect(lines.contains("Place: Michaelertor (historic=city_gate), 50 m left."))
        #expect(lines.contains("Summary: Gate of the palace."))
        #expect(lines.contains("Already told:"))
        #expect(lines.contains("- [osm:node/1] level 1: Told before."))
        // gate is tier .top: buzz first level 75 words; 75·60/150 = 30 s.
        #expect(Self.gate.tier == .top)
        #expect(lines.last == "Length: about 75 words (30 seconds spoken), 2–3 points")
    }
    @Test func buzzNeighboursAreTierThenDistanceWithoutTheBuzzedPlace() throws {
        let text = PromptBuilder.walkBuzzInput(buzz: Self.buzz, course: nil, facts: Self.facts, position: Self.origin, priors: [])
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "Other places nearby:"))
        // castle .top 200 m, church .good 80 m, plaque .wikiOnly 30 m; the gate (50 m) is excluded.
        #expect(Array(lines[(start + 1)...(start + 3)]) == ["- Hofburg (historic=castle), 200 m",
                                                          "- Peterskirche (amenity=place_of_worship), 80 m",
                                                          "- Mozart plaque (historic=memorial), 30 m"])
        #expect(lines[start + 4] == "Already told: nothing yet")
        #expect(!text.contains("- Michaelertor"))
    }
    @Test func buzzNeighboursAreCappedAtFour() {
        let many = (0..<7).map { Self.place("osm:node/1\($0)", "P\($0)", "k", north: Double(100 + $0 * 10), tier: .good) }
        let text = PromptBuilder.walkBuzzInput(buzz: Self.buzz, course: nil, facts: many, position: Self.origin, priors: [])
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- P") }.count == 4)
        #expect(text.contains("- P3 (k), 130 m") && !text.contains("- P4 "))
    }
    @Test func buzzWithoutSummaryOrNeighboursOmitsThoseLines() {
        let bare = Self.place("osm:node/9", "Bare", "k", north: 40, tier: .good)
        let b = Buzz(id: UUID(), place: bare, distance: 40, bearing: 0, title: "Bare", detail: "40 m away", usedOverride: false)
        let text = PromptBuilder.walkBuzzInput(buzz: b, course: nil, facts: [bare], position: Self.origin, priors: [])
        #expect(!text.contains("Summary:") && !text.contains("Other places nearby:"))
    }
    @Test func stopInputListsOnlyPlacesWithin150m() throws {
        let text = PromptBuilder.walkStopInput(address: Address(line: "Michaelerplatz 1", city: "Wien"), facts: Self.facts,
                                               position: Self.origin, priors: [Self.prior])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("The listener has stopped walking and is standing here for a while. Tell a short story about this spot."))
        #expect(lines.contains("Where: Michaelerplatz 1, Wien"))
        let start = try #require(lines.firstIndex(of: "Places within 150 m:"))
        // gate .top 50 m, church .good 80 m, plaque .wikiOnly 30 m; the castle (200 m) is out.
        #expect(Array(lines[(start + 1)...(start + 3)]) == ["- Michaelertor (historic=city_gate), 50 m",
                                                          "- Peterskirche (amenity=place_of_worship), 80 m",
                                                          "- Mozart plaque (historic=memorial), 30 m"])
        #expect(!text.contains("Hofburg"))
        #expect(lines.contains("- [osm:node/1] level 1: Told before."))
        // best listed tier is .top (gate): stop = min(75, 50) = 50 words; 50·60/150 = 20 s.
        #expect(lines.last == "Length: about 50 words (20 seconds spoken), 2–3 points")
    }
    @Test func stopFactsAreCappedAtFive() {
        let many = (0..<8).map { Self.place("osm:node/2\($0)", "Q\($0)", "k", north: Double(10 + $0 * 10), tier: .good) }
        #expect(PromptBuilder.stopFacts(many, position: Self.origin).count == 5)
    }
    @Test func missingAddressIsAnUnknownStreet() {
        for address in [nil, Address()] as [Address?] {
            let text = PromptBuilder.walkStopInput(address: address, facts: [], position: Self.origin, priors: [])
            #expect(text.contains("Where: unknown street") && !text.contains("Places within"))
        }
    }
    @Test func continuationNamesTheLevelsTold() {
        let story = WalkStory(id: UUID(), kind: .buzz, place: Self.gate.candidate, position: Self.origin, course: nil,
                              language: .english, title: "T", levels: ["First text."], createdAt: .now, detail: "50 m left")
        let text = PromptBuilder.walkContinuationInput(story: story, level: .more, priors: [])
        // level .more: 200 words; 200·60/150 = 80 s.
        #expect(text.contains("Length: about 200 words (80 seconds spoken), 3–4 points"))
        #expect(text.contains("Place: Michaelertor (historic=city_gate), 50 m left."))
        #expect(text.contains("Level 1: First text."))
        let stop = WalkStory(id: UUID(), kind: .stop, place: nil, position: Self.origin, course: nil, language: .english,
                             title: "T", levels: ["A", "B"], createdAt: .now, address: Address(line: "Graben"))
        let stopText = PromptBuilder.walkContinuationInput(story: stop, level: .evenMore, priors: [Self.prior])
        // level .evenMore: 300 words; 300·60/150 = 120 s = 2 minutes.
        #expect(stopText.contains("about 300 words (2 minutes spoken), as many as the facts carry") && stopText.contains("Where: Graben"))
        #expect(stopText.contains("Level 2: B") && stopText.contains("- [osm:node/1] level 1: Told before."))
    }
    @Test func schemaIsStrictWithTitleAndStory() throws {
        let data = try JSONEncoder().encode(PromptBuilder.walkStorySchema)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["additionalProperties"] as? Bool == false)
        #expect((json["required"] as? [String]) == ["title", "story"])
        #expect(Set((json["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["title", "story"])
    }
}
