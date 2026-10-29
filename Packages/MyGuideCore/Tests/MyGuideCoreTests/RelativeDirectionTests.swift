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

@Suite struct ListAgeLineTests {
    @Test func noLineUpToTenMinutes() {
        // Spec 5: marked only when older than 10 minutes (600 s); 600 s itself is not older.
        #expect(AroundText.listAgeLine(seconds: nil, language: .norwegian) == nil)
        #expect(AroundText.listAgeLine(seconds: 0, language: .norwegian) == nil)
        #expect(AroundText.listAgeLine(seconds: 600, language: .english) == nil)
    }

    @Test func minutesUnderTwoHours() {
        // 601 s → ⌊601 / 60⌋ = 10 min; 3 599 s → ⌊59.98⌋ = 59 min; 7 199 s → ⌊119.98⌋ = 119 min.
        #expect(AroundText.listAgeLine(seconds: 601, language: .norwegian) == "Steder fra for 10 min siden")
        #expect(AroundText.listAgeLine(seconds: 601, language: .english) == "Places from 10 min ago")
        #expect(AroundText.listAgeLine(seconds: 3_599, language: .norwegian) == "Steder fra for 59 min siden")
        #expect(AroundText.listAgeLine(seconds: 7_199, language: .english) == "Places from 119 min ago")
    }

    @Test func hoursUnderTwoDays() {
        // 7 200 s → 7 200 / 3 600 = 2 h; 172 799 s → ⌊47.9997⌋ = 47 h.
        #expect(AroundText.listAgeLine(seconds: 7_200, language: .norwegian) == "Steder fra for 2 timer siden")
        #expect(AroundText.listAgeLine(seconds: 7_200, language: .english) == "Places from 2 hours ago")
        #expect(AroundText.listAgeLine(seconds: 172_799, language: .norwegian) == "Steder fra for 47 timer siden")
    }

    @Test func daysFromTwoDays() {
        // 172 800 s → 172 800 / 86 400 = 2 days; 950 400 s → 11 days.
        #expect(AroundText.listAgeLine(seconds: 172_800, language: .norwegian) == "Steder fra for 2 dager siden")
        #expect(AroundText.listAgeLine(seconds: 172_800, language: .english) == "Places from 2 days ago")
        #expect(AroundText.listAgeLine(seconds: 950_400, language: .english) == "Places from 11 days ago")
    }

    @Test func unknownAgesHaveNoLine() {
        // A negative age (list dated in the future) and a non-finite one say nothing rather than something wrong.
        #expect(AroundText.listAgeLine(seconds: -5, language: .norwegian) == nil)
        #expect(AroundText.listAgeLine(seconds: .infinity, language: .norwegian) == nil)
        #expect(AroundText.listAgeLine(seconds: .nan, language: .english) == nil)
    }

    @Test func hugeAgesAreClampedNotTrapped() {
        // Clamped to 1e9 s: ⌊1e9 / 60⌋ = 16 666 666 min; ⌊16 666 666 / 1 440⌋ = 11 574 days.
        #expect(AroundText.listAgeLine(seconds: 1e300, language: .english) == "Places from 11574 days ago")
    }
}
