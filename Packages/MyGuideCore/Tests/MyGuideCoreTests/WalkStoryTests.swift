import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkStoryTests {
    @Test func onlyABuzzStoryCanBeSkipped() {
        let buzz = WalkStory(id: UUID(), kind: .buzz, place: Candidate(id: "osm:node/1", name: "Gate", coordinate: .at(), kind: "historic=city_gate"), position: .at(),
                             course: nil, language: .english, title: "Buzz", levels: ["one"], createdAt: .now)
        var stop = buzz
        stop.kind = .stop
        stop.place = nil
        #expect(buzz.canSkip)
        #expect(!stop.canSkip)
    }

    @Test func chosenCannotSkip() {
        let chosen = WalkStory(id: UUID(), kind: .chosen, place: Candidate(id: "osm:node/1", name: "Gate", coordinate: .at(), kind: "historic=city_gate"),
                               position: .at(), course: nil, language: .english, title: "Chosen", levels: ["one"], createdAt: .now)
        #expect(!chosen.canSkip)
        #expect(WalkStory.Kind(rawValue: "chosen") == .chosen && WalkStory.Kind.chosen.rawValue == "chosen")
    }

    @Test func chosenBuzzHasNoCourseDetail() {
        // The place is 100 m due north of the position: GeoMath distance 100 m, bearing 0; BuzzText rounds 100 to
        // the nearest 10 -> 100, and with no course the line is "100 m away".
        let position = Coordinate.at()
        let place = WalkingPlace(candidate: Candidate(id: "osm:node/9", name: "Gate", coordinate: .at(north: 100),
                                                      kind: "historic=city_gate"), tier: .good)
        let buzz = Buzz(chosen: place, position: position)
        #expect(buzz.detail == "100 m away" && buzz.title == "Gate" && !buzz.usedOverride)
        #expect(buzz.place == place)
        #expect(abs(buzz.distance - GeoMath.distance(position, place.candidate.coordinate)) < 1e-9)
        #expect(abs(buzz.distance - 100) < 0.5)
        #expect(abs(buzz.bearing) < 1e-6)
        #expect(Buzz(chosen: place, position: position).id != buzz.id)
        // 36 m due east of the position: rounds to 40, still no direction word.
        let east = WalkingPlace(candidate: Candidate(id: "osm:node/10", name: "Well", coordinate: .at(east: 36),
                                                     kind: "amenity=drinking_water"), tier: .good)
        let near = Buzz(chosen: east, position: position)
        #expect(near.detail == "40 m away" && abs(near.bearing - 90) < 0.01)
    }
}
