import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GuideTextTests {
    @Test func sides() {
        // r = 90 − 0 = 90 → (60,120] right;  r = 350 − 10 = 340 → −20 → ahead;  r = 200 − 0 = 200 → −160 → behind
        #expect(GuideText.side(bearing: 90, direction: 0) == "to your right")
        #expect(GuideText.side(bearing: 350, direction: 10) == "ahead")
        #expect(GuideText.side(bearing: 200, direction: 0) == "behind")
        // boundaries: r = 30 → ahead; r = 60 → ahead-right; r = 225 → −135 → behind-left; r = 150 → behind-right; r = 151 → behind
        #expect(GuideText.side(bearing: 30, direction: 0) == "ahead")
        #expect(GuideText.side(bearing: 60, direction: 0) == "ahead-right")
        #expect(GuideText.side(bearing: 225, direction: 0) == "behind-left")
        #expect(GuideText.side(bearing: 150, direction: 0) == "behind-right")
        #expect(GuideText.side(bearing: 151, direction: 0) == "behind")
        // mirrored: r = −45 → ahead-left; r = 270 → −90 → to your left; r = 120 → to your right
        #expect(GuideText.side(bearing: 315, direction: 0) == "ahead-left")
        #expect(GuideText.side(bearing: 270, direction: 0) == "to your left")
        #expect(GuideText.side(bearing: 120, direction: 0) == "to your right")
        #expect(GuideText.side(bearing: 45, direction: nil) == "north-east")
        #expect(GuideText.side(bearing: 45, direction: -1) == "north-east")
        #expect(GuideText.side(bearing: 45, direction: .nan) == "north-east")
    }
    @Test func distanceAndSide() {
        // 37 m → nearest 10 = 40
        #expect(GuideText.distanceAndSide(distance: 37, bearing: 270, direction: 0) == "40 m, to your left")
        // 112 m → 110; no direction, bearing 180 → south
        #expect(GuideText.distanceAndSide(distance: 112, bearing: 180, direction: nil) == "110 m, south")
    }
    @Test func streetNames() {
        #expect(GuideText.streetName(fromAddressLine: "Kirkegata 15") == "Kirkegata")
        #expect(GuideText.streetName(fromAddressLine: "15 Main St") == "Main St")
        #expect(GuideText.streetName(fromAddressLine: "Karl Johans gate 22B") == "Karl Johans gate")
        #expect(GuideText.streetName(fromAddressLine: "42") == nil)
        #expect(GuideText.streetName(fromAddressLine: "") == nil)
        #expect(GuideText.streetName(fromAddressLine: nil) == nil)
    }
    @Test func timeIsEnglishAnd24Hour() {
        // 2026-10-28T11:40:00Z = 12:40 CET (UTC+1, after the 2026-10-25 DST change), a Wednesday
        let d = ISO8601DateFormatter().date(from: "2026-10-28T11:40:00Z")!
        #expect(GuideText.time(d, timeZone: TimeZone(identifier: "Europe/Oslo")!) == "12:40 Wednesday")
        #expect(GuideText.clock(d, timeZone: TimeZone(identifier: "UTC")!) == "11:40")
    }
    @Test func osmFactsInFixedOrderAndCut() {
        let long = String(repeating: "a ", count: 150)   // 300 characters
        let text = GuideText.osmFacts(["architect": "Linstow", "start_date": "1697", "historic": "church", "inscription": long])!
        #expect(text.hasPrefix("OSM: start_date=1697; architect=Linstow; inscription="))
        #expect(!text.contains("historic"))
        #expect(text.count < 300)
        #expect(GuideText.osmFacts(["historic": "church"]) == nil)
        #expect(GuideText.osmFacts(nil) == nil)
    }
    @Test func addressWithoutDistrictDecodes() throws {
        let old = #"{"line":"Kirkegata 15","city":"Oslo","country":"Norway"}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(Address.self, from: old)
        #expect(a.district == nil && a.display == "Kirkegata 15, Oslo, Norway")
        #expect(Address(line: "Kirkegata 15", district: "Kvadraturen", city: "Oslo").display == "Kirkegata 15, Kvadraturen, Oslo")
    }
}
