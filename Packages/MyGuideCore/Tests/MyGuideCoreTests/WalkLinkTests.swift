import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkLinkTests {
    static let id = UUID(uuidString: "6F1C2A3B-0000-4000-8000-000000000001")!

    @Test func roundTrips() {
        let url = WalkLink.url(for: Self.id)
        #expect(url.absoluteString == "myguide://walk/6F1C2A3B-0000-4000-8000-000000000001")
        #expect(WalkLink.storyID(from: url) == Self.id)
        // A fresh random id survives too.
        let other = UUID()
        #expect(WalkLink.storyID(from: WalkLink.url(for: other)) == other)
    }
    @Test func acceptsLowercaseIDs() {
        let url = URL(string: "myguide://walk/6f1c2a3b-0000-4000-8000-000000000001")!
        #expect(WalkLink.storyID(from: url) == Self.id)
    }
    @Test func rejectsOtherLinks() {
        let good = Self.id.uuidString
        for text in ["https://walk/\(good)", "myguide://story/\(good)", "myguide://walk", "myguide://walk/",
                     "myguide://walk/not-a-uuid", "myguide://walk/\(good)/more", "myguide:///\(good)", "myguide://walk/\(good)x"] {
            #expect(WalkLink.storyID(from: URL(string: text)!) == nil, "\(text)")
        }
    }
}
