import Foundation
import Testing
@testable import MyGuideCore

@Suite struct RelativeDirectionTests {
    @Test func bands() {
        #expect(RelativeDirection(offset: 0) == .ahead)
        #expect(RelativeDirection(offset: 30) == .ahead)
        #expect(RelativeDirection(offset: -30) == .ahead)
        #expect(RelativeDirection(offset: 30.1) == .aheadRight)
        #expect(RelativeDirection(offset: 60) == .aheadRight)
        #expect(RelativeDirection(offset: -60) == .aheadLeft)
        #expect(RelativeDirection(offset: 60.1) == .right)
        #expect(RelativeDirection(offset: 120) == .right)
        #expect(RelativeDirection(offset: -120) == .left)
        #expect(RelativeDirection(offset: 120.1) == .behindRight)
        #expect(RelativeDirection(offset: 150) == .behindRight)
        #expect(RelativeDirection(offset: -150) == .behindLeft)
        #expect(RelativeDirection(offset: 151) == .behind)
        #expect(RelativeDirection(offset: -151) == .behind)
        #expect(RelativeDirection(offset: 180) == .behind)
        #expect(RelativeDirection(offset: -180) == .behind)
        // Not yet wrapped input: 350 ≡ −10 → ahead; .nan → ahead is not claimed, it must not crash.
        #expect(RelativeDirection(offset: 350) == .ahead)
        _ = RelativeDirection(offset: .nan)
    }

    @Test func wordsBothLanguages() {
        let all: [RelativeDirection] = [.ahead, .aheadLeft, .aheadRight, .left, .right, .behindLeft, .behindRight, .behind]
        #expect(all.map { $0.words(.norwegian) } == [
            "foran deg", "foran til venstre", "foran til høyre", "til venstre for deg", "til høyre for deg",
            "bak deg til venstre", "bak deg til høyre", "bak deg",
        ])
        #expect(all.map { $0.words(.english) } == [
            "ahead", "ahead to the left", "ahead to the right", "to your left", "to your right",
            "behind you to the left", "behind you to the right", "behind you",
        ])
    }

    @Test func whereLineWithAndWithoutDirection() {
        // distance 47 → BuzzText.roundedDistance 50 (4.7 rounds to 5 tens); relative 10 → ahead.
        #expect(AroundText.whereLine(distance: 47, relative: 10, language: .norwegian) == "50 m · foran deg")
        #expect(AroundText.whereLine(distance: 47, relative: 10, language: .english) == "50 m · ahead")
        // relative −90 → left. 3 m → minimum 10.
        #expect(AroundText.whereLine(distance: 3, relative: -90, language: .norwegian) == "10 m · til venstre for deg")
        #expect(AroundText.whereLine(distance: 47, relative: nil, language: .norwegian) == "i nærheten · 50 m")
        #expect(AroundText.whereLine(distance: 47, relative: nil, language: .english) == "nearby · 50 m")
    }

    @Test func localizedDetailMatchesEnglishBands() {
        // distance 47 → 50, 94 → 90. offset = bearing − course.
        let cases: [(Double, Double, Double?, String, String)] = [
            (47, 10, 0, "50 m foran deg", "50 m ahead"),        // offset 10
            (47, 90, 0, "50 m til høyre", "50 m right"),        // offset 90
            (47, 270, 0, "50 m til venstre", "50 m left"),      // 270 − 0 → −90
            (94, 180, 0, "90 m bak deg", "90 m behind you"),    // offset 180
            (47, 30, 0, "50 m foran deg", "50 m ahead"),        // boundary 30 → ahead
            (47, 150, 0, "50 m til høyre", "50 m right"),       // boundary 150 → right
        ]
        for (d, b, c, nb, en) in cases {
            #expect(BuzzText.localizedDetail(distance: d, bearing: b, course: c, language: .norwegian) == nb)
            #expect(BuzzText.localizedDetail(distance: d, bearing: b, course: c, language: .english) == en)
            #expect(BuzzText.localizedDetail(distance: d, bearing: b, course: c, language: .english)
                    == BuzzText.detail(distance: d, bearing: b, course: c))
        }
        // 210 − 0 = 210 → −150 → left (boundary, as in `detail`); 211 → −149... 151 → behind.
        #expect(BuzzText.localizedDetail(distance: 47, bearing: 210, course: 0, language: .norwegian) == "50 m til venstre")
        #expect(BuzzText.localizedDetail(distance: 47, bearing: 151, course: 0, language: .norwegian) == "50 m bak deg")
        // No usable course: "unna" / "away".
        for course in [nil, -1, Double.nan] as [Double?] {
            #expect(BuzzText.localizedDetail(distance: 47, bearing: 10, course: course, language: .norwegian) == "50 m unna")
            #expect(BuzzText.localizedDetail(distance: 47, bearing: 10, course: course, language: .english) == "50 m away")
        }
    }
}
