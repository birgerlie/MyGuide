import Testing
import Foundation
@testable import MyGuideCore

@Suite struct FieldOfViewTests {
    @Test func portraitFOVFromLandscape() {
        // portrait hFOV = 2·atan(tan(F/2)·3/4)
        // F=69.4: tan(34.7°)=0.6924; ·0.75=0.5193; atan=27.44°; ·2 = 54.88°
        // F=90:   tan(45°)=1;        ·0.75=0.75;   atan=36.87°; ·2 = 73.74°
        #expect(abs(FieldOfView.portraitHorizontalFOV(landscapeFOV: 69.4) - 54.88) < 0.05)
        #expect(abs(FieldOfView.portraitHorizontalFOV(landscapeFOV: 90) - 73.74) < 0.05)
    }
    @Test func assumedFOVByAspect() {
        #expect(FieldOfView.assumedHorizontalFOV(pixelWidth: 4032, pixelHeight: 3024) == 69.4)
        #expect(abs(FieldOfView.assumedHorizontalFOV(pixelWidth: 3024, pixelHeight: 4032) - 54.88) < 0.05)
    }
    @Test func coneHalfWidth() {
        // fov/2 + 2·acc: 55/2 + 2·10 = 47.5;  54.88/2 + 2·0 = 27.44
        #expect(FieldOfView.coneHalfWidth(horizontalFOV: 55, headingAccuracy: 10) == 47.5)
        #expect(abs(FieldOfView.coneHalfWidth(horizontalFOV: 54.88, headingAccuracy: 0) - 27.44) < 1e-9)
    }
    @Test func usableHeadingRules() {
        #expect(FieldOfView.usableHeading(120, accuracy: 10) == 120)
        #expect(FieldOfView.usableHeading(120, accuracy: 45) == 120)   // boundary: 45 is usable
        #expect(FieldOfView.usableHeading(120, accuracy: 45.1) == nil)
        #expect(FieldOfView.usableHeading(120, accuracy: nil) == nil)
        #expect(FieldOfView.usableHeading(120, accuracy: -1) == nil)   // CoreLocation "invalid"
        #expect(FieldOfView.usableHeading(nil, accuracy: 5) == nil)
    }
    @Test func inViewAcrossNorth() {
        // heading 350, half 47.5: bearing 30 → diff 40 ≤ 47.5 in; bearing 40 → diff 50 out
        #expect(FieldOfView.isInView(bearing: 30, heading: 350, halfWidth: 47.5))
        #expect(!FieldOfView.isInView(bearing: 40, heading: 350, halfWidth: 47.5))
        #expect(FieldOfView.isInView(bearing: 37.5, heading: 350, halfWidth: 47.5)) // exactly on edge
    }
    @Test func compassPoints() {
        // index = Int((deg + 22.5) / 45) % 8
        // 312 → 334.5/45 = 7.43 → 7 = north-west;  350 → 372.5/45 = 8.28 → 8%8 = 0 = north
        #expect(FieldOfView.compassPoint(312) == "north-west")
        #expect(FieldOfView.compassPoint(350) == "north")
        #expect(FieldOfView.compassPoint(22.4) == "north")
        #expect(FieldOfView.compassPoint(22.5) == "north-east")
        #expect(FieldOfView.compassPoint(180) == "south")
    }
    @Test func compassReadingPrefersTrueHeading() {
        #expect(CompassReading(trueHeading: 12, magneticHeading: 15, headingAccuracy: 5) == .init(heading: 12, accuracy: 5))
        // trueHeading < 0 means "no true heading" (no location yet) → use magnetic
        #expect(CompassReading(trueHeading: -1, magneticHeading: 15, headingAccuracy: 5) == .init(heading: 15, accuracy: 5))
        // headingAccuracy < 0 means invalid → accuracy nil (→ usableHeading nil)
        #expect(CompassReading(trueHeading: 12, magneticHeading: 15, headingAccuracy: -1).accuracy == nil)
    }
}
