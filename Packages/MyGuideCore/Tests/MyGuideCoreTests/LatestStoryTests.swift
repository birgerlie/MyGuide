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
}
