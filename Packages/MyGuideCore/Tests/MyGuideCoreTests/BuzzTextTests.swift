import Foundation
import Testing
@testable import MyGuideCore

@Suite struct BuzzTextTests {
    @Test func rounding() {
        // nearest 10, halves up, minimum 10: 44→40, 45→50, 119→120, 4→10, 0→10
        #expect(BuzzText.roundedDistance(44) == 40)
        #expect(BuzzText.roundedDistance(45) == 50)
        #expect(BuzzText.roundedDistance(119) == 120)
        #expect(BuzzText.roundedDistance(4) == 10)
        #expect(BuzzText.roundedDistance(0) == 10)
    }
    @Test func sectors() {
        // r = bearing − course in (−180, 180]
        #expect(BuzzText.detail(distance: 50, bearing: 10, course: 0) == "50 m ahead")     // r = 10
        #expect(BuzzText.detail(distance: 50, bearing: 30, course: 0) == "50 m ahead")     // r = 30, boundary
        #expect(BuzzText.detail(distance: 50, bearing: 31, course: 0) == "50 m right")     // r = 31
        #expect(BuzzText.detail(distance: 50, bearing: 150, course: 0) == "50 m right")    // r = 150, boundary
        #expect(BuzzText.detail(distance: 90, bearing: 151, course: 0) == "90 m behind you")
        #expect(BuzzText.detail(distance: 50, bearing: 330, course: 0) == "50 m ahead")    // r = −30
        #expect(BuzzText.detail(distance: 50, bearing: 300, course: 0) == "50 m left")     // r = −60
        #expect(BuzzText.detail(distance: 50, bearing: 210, course: 0) == "50 m left")     // r = −150
        #expect(BuzzText.detail(distance: 50, bearing: 200, course: 0) == "50 m behind you") // r = −160
        #expect(BuzzText.detail(distance: 50, bearing: 180, course: 0) == "50 m behind you") // r = 180
        #expect(BuzzText.detail(distance: 50, bearing: 10, course: 350) == "50 m ahead")   // r = 20 (wrap)
    }
    @Test func noCourse() {
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: nil) == "50 m away")
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: -1) == "50 m away")
        #expect(BuzzText.detail(distance: 52, bearing: 10, course: .nan) == "50 m away")
    }
}
