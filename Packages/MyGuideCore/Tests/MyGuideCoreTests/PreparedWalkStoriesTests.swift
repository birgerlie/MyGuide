import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PreparedWalkStoriesTests {
    static func story(_ id: UUID = UUID(), levels: [String] = ["One."]) -> WalkStory {
        WalkStory(id: id, kind: .buzz, place: nil, position: Coordinate(latitude: 59.91, longitude: 10.75), course: nil,
                  language: .english, title: "Gate", levels: levels, createdAt: Date(timeIntervalSince1970: 0))
    }
    static let file1 = URL(filePath: "/tmp/a-1-en.mp3"), file2 = URL(filePath: "/tmp/a-2-en.mp3")

    @Test func storesAndReadsBack() {
        var p = PreparedWalkStories()
        let s = Self.story()
        p.store(s)
        p.setAudio(Self.file1, id: s.id, level: 1)
        #expect(p.story(s.id) == s)
        #expect(p.audio(s.id, level: 1) == Self.file1)
        #expect(p.audio(s.id, level: 2) == nil)
        #expect(p.story(UUID()) == nil)
    }
    @Test func keepsTheFiveNewest() {
        // Six stored with limit 5: 6 − 5 = 1 dropped, the first; the other five stay, oldest first.
        var p = PreparedWalkStories()
        let ids = (0..<6).map { _ in UUID() }
        for id in ids { p.store(Self.story(id)) }
        #expect(PreparedWalkStories.limit == 5)
        #expect(p.story(ids[0]) == nil)
        #expect(p.ids == Array(ids[1...]))
        // Five stored: 5 − 5 = 0 dropped.
        var q = PreparedWalkStories()
        for id in ids.prefix(5) { q.store(Self.story(id)) }
        #expect(q.ids == Array(ids.prefix(5)))
    }
    @Test func refreshingAStoryMakesItNewestAndKeepsItsAudio() {
        var p = PreparedWalkStories()
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { p.store(Self.story(id)) }
        p.setAudio(Self.file1, id: ids[0], level: 1)
        p.store(Self.story(ids[0], levels: ["One.", "Two."]))
        #expect(p.ids.last == ids[0])
        #expect(p.audio(ids[0], level: 1) == Self.file1)
        #expect(p.story(ids[0])?.levels.count == 2)
        // A sixth story now drops ids[1], the oldest after the refresh (5 + 1 − 5 = 1 dropped).
        p.store(Self.story())
        #expect(p.story(ids[1]) == nil && p.story(ids[0]) != nil)
    }
    @Test func audioForALevelTheStoryLacksOrAnUnknownStoryIsIgnored() {
        var p = PreparedWalkStories()
        let s = Self.story()
        p.store(s)
        p.setAudio(Self.file2, id: s.id, level: 2)     // the story has one level
        p.setAudio(Self.file1, id: s.id, level: 0)
        p.setAudio(Self.file1, id: UUID(), level: 1)
        #expect(p.audio(s.id, level: 2) == nil && p.audio(s.id, level: 0) == nil)
        #expect(p.ids == [s.id])
    }
    @Test func removeForgetsTheStory() {
        var p = PreparedWalkStories()
        let s = Self.story()
        p.store(s)
        p.setAudio(Self.file1, id: s.id, level: 1)
        p.remove(s.id)
        #expect(p.story(s.id) == nil && p.audio(s.id, level: 1) == nil && p.ids.isEmpty)
        p.remove(UUID())                                // unknown: no effect
        #expect(p.ids.isEmpty)
    }
}
