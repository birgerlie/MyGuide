import Testing
import Foundation
@testable import MyGuideCore

@Suite struct CaptureHUDTests {
    static let fix8 = LocationFix(coordinate: Coordinate(latitude: 59.91, longitude: 10.75), accuracy: 8)

    @Test func fullLine() {
        // 312° → Int((312 + 22.5) / 45) = Int(7.43) = 7 → north-west → "NW"
        #expect(CaptureHUD.text(fix: Self.fix8, compass: CompassReading(heading: 312, accuracy: 10))
                == "GPS ±8 m · 312° NW ±10°")
        // accuracy 7.6 rounds to 8; heading 44.4 rounds to 44, (44.4 + 22.5) / 45 = 1.49 → 1 → north-east; acc 4.5 rounds to 5
        let rounded = LocationFix(coordinate: Self.fix8.coordinate, accuracy: 7.6)
        #expect(CaptureHUD.text(fix: rounded, compass: CompassReading(heading: 44.4, accuracy: 4.5))
                == "GPS ±8 m · 44° NE ±5°")
    }

    @Test func headingJustBelowNorthShowsZero() {
        // 359.6 rounds to 360 → shown as 0; (359.6 + 22.5) / 45 = 8.49 → 8 % 8 = 0 → north → "N"
        #expect(CaptureHUD.text(fix: Self.fix8, compass: CompassReading(heading: 359.6, accuracy: 3))
                == "GPS ±8 m · 0° N ±3°")
    }

    @Test func missingParts() {
        #expect(CaptureHUD.text(fix: nil, compass: CompassReading(heading: 90, accuracy: 10))
                == "No GPS fix · 90° E ±10°")
        #expect(CaptureHUD.text(fix: Self.fix8, compass: nil) == "GPS ±8 m · Compass unavailable")
        #expect(CaptureHUD.text(fix: nil, compass: nil) == "No GPS fix · Compass unavailable")
    }

    @Test func invalidHeadingAccuracyIsUnavailable() {
        // CompassReading maps CoreLocation's negative accuracy to nil; the core then ignores the heading.
        let invalid = CompassReading(trueHeading: 120, magneticHeading: 118, headingAccuracy: -1)
        #expect(CaptureHUD.text(fix: Self.fix8, compass: invalid) == "GPS ±8 m · Compass unavailable")
        #expect(CaptureHUD.text(fix: Self.fix8, compass: CompassReading(heading: .nan, accuracy: 5))
                == "GPS ±8 m · Compass unavailable")
    }

    @Test func headingAccuracyAboveUsableLimitIsUnreliable() {
        // 45 is the limit itself (FieldOfView.maxUsableHeadingAccuracy) and is still usable
        #expect(CaptureHUD.text(fix: Self.fix8, compass: CompassReading(heading: 312, accuracy: 45))
                == "GPS ±8 m · 312° NW ±45°")
        // 45.1 > 45 → the core ignores the heading, so the HUD must not show degrees
        #expect(CaptureHUD.text(fix: Self.fix8, compass: CompassReading(heading: 312, accuracy: 45.1))
                == "GPS ±8 m · Compass unreliable")
        #expect(CaptureHUD.text(fix: nil, compass: CompassReading(heading: 312, accuracy: 60))
                == "No GPS fix · Compass unreliable")
    }

    @Test func allEightAbbreviations() {
        // centres of each 45° sector: 0, 45, …, 315
        let expected = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        for (i, abbreviation) in expected.enumerated() {
            #expect(CaptureHUD.abbreviatedCompassPoint(Double(i) * 45) == abbreviation)
        }
    }
}
