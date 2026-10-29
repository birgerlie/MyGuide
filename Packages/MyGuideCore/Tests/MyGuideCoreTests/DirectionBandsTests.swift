import Foundation
import Testing
@testable import MyGuideCore

/// Pins the three direction bands at their edges: the buzz line (`BuzzText`, four bands), the prompt's side
/// (`GuideText.side`) and the screen's side (`RelativeDirection`), which share five bands. They differ on purpose at
/// 150: the buzz says "right" there, the five-band rule "behind-right".
@Suite struct DirectionBandsTests {
    /// (offset r, buzz line suffix, prompt side, relative direction). r = bearing − heading, already in (−180, 180].
    /// Buzz: −30...30 ahead; 30...150 right; −150...−30 left; else behind. The closed ranges overlap at ±30: the
    /// first match (ahead) wins.
    /// Five bands: |r| ≤ 30 ahead; ≤ 60 ahead-side; ≤ 120 side; ≤ 150 behind-side; else behind; side = r > 0 right.
    static let edges: [(Double, String, String, RelativeDirection)] = [
        (0, "ahead", "ahead", .ahead),
        (30, "ahead", "ahead", .ahead),                       // |30| ≤ 30; buzz −30...30
        (-30, "ahead", "ahead", .ahead),
        (30.1, "right", "ahead-right", .aheadRight),          // 30.1 in 30...150; |30.1| ≤ 60
        (-30.1, "left", "ahead-left", .aheadLeft),
        (60, "right", "ahead-right", .aheadRight),            // |60| ≤ 60
        (-60, "left", "ahead-left", .aheadLeft),
        (60.1, "right", "to your right", .right),             // |60.1| ≤ 120
        (-60.1, "left", "to your left", .left),
        (120, "right", "to your right", .right),
        (-120, "left", "to your left", .left),
        (120.1, "right", "behind-right", .behindRight),       // |120.1| ≤ 150
        (-120.1, "left", "behind-left", .behindLeft),
        (150, "right", "behind-right", .behindRight),         // buzz 30...150 still right; five bands behind-right
        (-150, "left", "behind-left", .behindLeft),
        (150.1, "behind you", "behind", .behind),             // outside every buzz range; |150.1| > 150
        (-150.1, "behind you", "behind", .behind),
        (180, "behind you", "behind", .behind),
    ]

    @Test func buzzLineAtEveryEdge() {
        for (r, suffix, _, _) in Self.edges {
            // heading 0, so bearing = r wrapped into 0..<360 (−30 → 330), which the band code wraps back to r.
            let bearing = r < 0 ? r + 360 : r
            #expect(BuzzText.detail(distance: 50, bearing: bearing, course: 0) == "50 m \(suffix)", "r = \(r)")
        }
    }

    @Test func promptSideAtEveryEdge() {
        for (r, _, side, _) in Self.edges {
            let bearing = r < 0 ? r + 360 : r
            #expect(GuideText.side(bearing: bearing, direction: 0) == side, "r = \(r)")
        }
    }

    @Test func relativeDirectionAtEveryEdge() {
        for (r, _, _, direction) in Self.edges {
            #expect(RelativeDirection(offset: r) == direction, "r = \(r)")
        }
    }

    @Test func theDifferenceIsWrappedFirst() {
        // bearing 10, heading 340: 10 − 340 = −330 → +360 = 30 → ahead in all three.
        #expect(BuzzText.detail(distance: 50, bearing: 10, course: 340) == "50 m ahead")
        #expect(GuideText.side(bearing: 10, direction: 340) == "ahead")
        // bearing 340, heading 10: 330 → −360 = −30 → ahead. bearing 339, heading 10: 329 → −31 → left / ahead-left.
        #expect(BuzzText.detail(distance: 50, bearing: 340, course: 10) == "50 m ahead")
        #expect(BuzzText.detail(distance: 50, bearing: 339, course: 10) == "50 m left")
        #expect(GuideText.side(bearing: 339, direction: 10) == "ahead-left")
        // bearing 0, heading 180: −180 → +360 = 180 → behind (never −180).
        #expect(BuzzText.detail(distance: 50, bearing: 0, course: 180) == "50 m behind you")
        #expect(GuideText.side(bearing: 0, direction: 180) == "behind")
        // Offsets outside (−180, 180]: 390 ≡ 30 ahead; −200 ≡ 160 behind; 540 ≡ 180 behind.
        #expect(RelativeDirection(offset: 390) == .ahead)
        #expect(RelativeDirection(offset: -200) == .behind)
        #expect(RelativeDirection(offset: 540) == .behind)
    }

    @Test func localizedBuzzLineAtEveryEdge() {
        let norwegian = ["ahead": "foran deg", "right": "til høyre", "left": "til venstre", "behind you": "bak deg"]
        for (r, suffix, _, _) in Self.edges {
            let bearing = r < 0 ? r + 360 : r
            #expect(BuzzText.localizedDetail(distance: 50, bearing: bearing, course: 0, language: .english)
                    == "50 m \(suffix)", "r = \(r)")
            #expect(BuzzText.localizedDetail(distance: 50, bearing: bearing, course: 0, language: .norwegian)
                    == "50 m \(norwegian[suffix]!)", "r = \(r)")
        }
        // No usable bearing either: "away" / "unna".
        #expect(BuzzText.detail(distance: 50, bearing: .nan, course: 0) == "50 m away")
        #expect(BuzzText.localizedDetail(distance: 50, bearing: .infinity, course: 0, language: .norwegian) == "50 m unna")
    }

    @Test func buzzSideAtEveryEdge() {
        let sides: [String: BuzzSide] = ["ahead": .ahead, "right": .right, "left": .left, "behind you": .behind]
        for (r, suffix, _, _) in Self.edges {
            let bearing = r < 0 ? r + 360 : r
            #expect(BuzzSide(bearing: bearing, course: 0) == sides[suffix], "r = \(r)")
        }
        // No usable course (nil, negative, not finite) or bearing → away.
        for course in [nil, -1, -0.001, Double.nan, Double.infinity] as [Double?] {
            #expect(BuzzSide(bearing: 10, course: course) == .away, "\(String(describing: course))")
        }
        #expect(BuzzSide(bearing: .nan, course: 0) == .away)
        // Course 0 is usable (north): bearing 0 → ahead.
        #expect(BuzzSide(bearing: 0, course: 0) == .ahead)
    }

    @Test func buzzSideWords() {
        let all: [BuzzSide] = [.ahead, .right, .left, .behind, .away]
        #expect(all.map { $0.words(.english) } == ["ahead", "right", "left", "behind you", "away"])
        #expect(all.map { $0.words(.norwegian) } == ["foran deg", "til høyre", "til venstre", "bak deg", "unna"])
    }

    @Test func relativeDirectionPromptWords() {
        let all: [RelativeDirection] = [.ahead, .aheadLeft, .aheadRight, .left, .right, .behindLeft, .behindRight, .behind]
        // Today's prompt words of GuideText.side, unchanged: the model reads them.
        #expect(all.map(\.promptWord) == [
            "ahead", "ahead-left", "ahead-right", "to your left", "to your right", "behind-left", "behind-right", "behind",
        ])
    }

    @Test func promptSideWithoutADirectionIsTheCompassWord() {
        // No usable direction: the compass word for the bearing; a non-finite bearing counts as 0 → north.
        #expect(GuideText.side(bearing: 200, direction: nil) == "south")
        #expect(GuideText.side(bearing: .nan, direction: nil) == "north")
        #expect(GuideText.side(bearing: .nan, direction: 0) == "north")
        #expect(GuideText.side(bearing: 90, direction: .infinity) == "east")
    }
}
