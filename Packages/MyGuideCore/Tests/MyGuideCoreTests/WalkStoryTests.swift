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
}
