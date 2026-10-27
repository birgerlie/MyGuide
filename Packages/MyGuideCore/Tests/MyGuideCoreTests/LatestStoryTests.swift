import Foundation
import Testing
@testable import MyGuideCore

@Suite struct LatestStoryTests {
    static let photoID = UUID(), walkID = UUID()
    // 1_000_000 s since 1970 is 1970-01-12 13:46:40 UTC; the walk times below are offsets from it.
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func noStoriesIsNil() {
        #expect(LatestStory.newest(photo: nil, walk: nil) == nil)
    }
    @Test func onlyAPhotoStory() {
        #expect(LatestStory.newest(photo: (Self.photoID, Self.t0), walk: nil) == .photo(Self.photoID))
    }
    @Test func onlyAWalkStory() {
        #expect(LatestStory.newest(photo: nil, walk: (Self.walkID, Self.t0)) == .walk(Self.walkID))
    }
    // Photo at t0, walk at t0 + 1 s: the walk is newer by one second.
    @Test func newerWalkBeatsOlderPhoto() {
        let r = LatestStory.newest(photo: (Self.photoID, Self.t0), walk: (Self.walkID, Self.t0 + 1))
        #expect(r == .walk(Self.walkID))
    }
    // Photo at t0 + 3600 (one hour after), walk at t0: the photo is newer by an hour.
    @Test func newerPhotoBeatsOlderWalk() {
        let r = LatestStory.newest(photo: (Self.photoID, Self.t0 + 3600), walk: (Self.walkID, Self.t0))
        #expect(r == .photo(Self.photoID))
    }
    // Same instant: documented tie-break, the photo story wins.
    @Test func tieGoesToThePhoto() {
        let r = LatestStory.newest(photo: (Self.photoID, Self.t0), walk: (Self.walkID, Self.t0))
        #expect(r == .photo(Self.photoID))
    }
    // Photo only 1 ms older than the walk is still older (no rounding to seconds).
    @Test func subSecondDifferenceCounts() {
        let r = LatestStory.newest(photo: (Self.photoID, Self.t0), walk: (Self.walkID, Self.t0 + 0.001))
        #expect(r == .walk(Self.walkID))
    }

    // MARK: - Told ref

    static let other = UUID()
    // Photo's EXIF date is t0 - 86_400 (a day before); it was told at t0 + 10. Candidates: that photo and a walk at t0.
    @Test func justToldLibraryPhotoWinsViaRef() {
        let ref = LatestStoryRef(story: .photo(Self.photoID), toldAt: Self.t0 + 10)
        let r = LatestStory.newest(told: ref, photo: (Self.photoID, Self.t0 - 86_400), walk: (Self.walkID, Self.t0))
        #expect(r == .photo(Self.photoID))
    }
    // Ref told at t0 + 10 is newer than both candidates (t0 + 5, t0 + 9).
    @Test func refNewerThanBothWins() {
        let ref = LatestStoryRef(story: .walk(Self.other), toldAt: Self.t0 + 10)
        let r = LatestStory.newest(told: ref, photo: (Self.photoID, Self.t0 + 5), walk: (Self.walkID, Self.t0 + 9))
        #expect(r == .walk(Self.other))
    }
    // Candidate at t0 + 11 is strictly newer than ref (t0 + 10): fallback rule decides.
    @Test func strictlyNewerCandidateBeatsRef() {
        let ref = LatestStoryRef(story: .photo(Self.photoID), toldAt: Self.t0 + 10)
        #expect(LatestStory.newest(told: ref, photo: nil, walk: (Self.walkID, Self.t0 + 11)) == .walk(Self.walkID))
    }
    @Test func refWinsATie() {
        let ref = LatestStoryRef(story: .photo(Self.photoID), toldAt: Self.t0)
        #expect(LatestStory.newest(told: ref, photo: nil, walk: (Self.walkID, Self.t0)) == .photo(Self.photoID))
    }
    @Test func missingRefFallsBackToTheRule() {
        let r = LatestStory.newest(told: nil, photo: (Self.photoID, Self.t0), walk: (Self.walkID, Self.t0 + 1))
        #expect(r == .walk(Self.walkID))
    }
    @Test func refAloneWithNoCandidates() {
        let ref = LatestStoryRef(story: .walk(Self.walkID), toldAt: Self.t0)
        #expect(LatestStory.newest(told: ref, photo: nil, walk: nil) == .walk(Self.walkID))
    }

    @Test func refRoundTripsThroughDefaults() throws {
        let name = "LatestStoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LatestStoryRef.load(from: defaults) == nil)
        LatestStoryRef.record(.walk(Self.walkID), at: Self.t0, in: defaults)
        #expect(LatestStoryRef.load(from: defaults) == LatestStoryRef(story: .walk(Self.walkID), toldAt: Self.t0))
        LatestStoryRef.record(.photo(Self.photoID), at: Self.t0 + 1, in: defaults)
        #expect(LatestStoryRef.load(from: defaults)?.story == .photo(Self.photoID))
    }
    @Test func unreadableRefIsNil() throws {
        let name = "LatestStoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("nonsense".utf8), forKey: LatestStoryRef.defaultsKey)
        #expect(LatestStoryRef.load(from: defaults) == nil)
        defaults.set(Data(#"{"kind":"x","id":"\#(Self.photoID.uuidString)","toldAt":0}"#.utf8), forKey: LatestStoryRef.defaultsKey)
        #expect(LatestStoryRef.load(from: defaults) == nil)
    }

    // MARK: - Path rules

    @Test func cameraEntryBecomesTheStoryAndKeepsWhatIsOnTop() {
        #expect(StoryPath.replacingCamera(in: ["camera"], camera: "camera", with: "story") == ["story"])
        #expect(StoryPath.replacingCamera(in: ["camera", "walk"], camera: "camera", with: "story") == ["story", "walk"])
    }
    @Test func cameraGoneDropsThePhoto() {
        #expect(StoryPath.replacingCamera(in: [String](), camera: "camera", with: "story") == nil)
        #expect(StoryPath.replacingCamera(in: ["walk"], camera: "camera", with: "story") == nil)
    }
    @Test func pickedStoryGoesUnderWhatIsOpen() {
        #expect(StoryPath.underneath([], story: "story") == ["story"])
        #expect(StoryPath.underneath(["walk"], story: "story") == ["story", "walk"])
        #expect(StoryPath.underneath(["story", "walk"], story: "story") == ["story", "walk"])
    }
}
