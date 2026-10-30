import Testing
@testable import MyGuideCore

@Suite struct NorthArrowTests {
    @Test func firstHeadingIsShownAtOnce() {
        // Nothing shown: 37 → 37; −10 → normalized 350.
        #expect(NorthArrow.next(shown: nil, heading: 37) == 37)
        #expect(NorthArrow.next(shown: nil, heading: -10) == 350)
    }

    @Test func movesOnlyFromTenDegrees() {
        // Shown 37: 46.9 → offset 9.9 < 10 → stays 37; 47 → 10 ≥ 10 → 47; 27 → −10 → 27; 27.5 → −9.5 → 37.
        #expect(NorthArrow.next(shown: 37, heading: 46.9) == 37)
        #expect(NorthArrow.next(shown: 37, heading: 47) == 47)
        #expect(NorthArrow.next(shown: 37, heading: 27) == 27)
        #expect(NorthArrow.next(shown: 37, heading: 27.5) == 37)
    }

    @Test func wrapsAroundNorth() {
        // Shown 355: 4 → offset 9 → stays 355; 5 → 10 → 5. Shown 3: 353.5 → −9.5 → 3; 353 → −10 → 353.
        #expect(NorthArrow.next(shown: 355, heading: 4) == 355)
        #expect(NorthArrow.next(shown: 355, heading: 5) == 5)
        #expect(NorthArrow.next(shown: 3, heading: 353.5) == 3)
        #expect(NorthArrow.next(shown: 3, heading: 353) == 353)
        // Shown 0, heading 370 → normalized 10 → offset 10 → 10.
        #expect(NorthArrow.next(shown: 0, heading: 370) == 10)
    }

    @Test func aHeadingThatIsNotFiniteKeepsWhatIsShown() {
        #expect(NorthArrow.next(shown: 120, heading: .nan) == 120)
        #expect(NorthArrow.next(shown: nil, heading: .infinity) == nil)
    }
}
