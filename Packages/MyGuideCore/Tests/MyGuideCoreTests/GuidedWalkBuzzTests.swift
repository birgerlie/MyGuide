import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GuidedWalkBuzzTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let id = UUID(uuidString: "6F2A3C4E-1B2D-4E5F-8A9B-0C1D2E3F4A5B")!
    static let buzz = GuidedWalkBuzz(id: id, name: "Horrea Galbae", line: "50 m til høyre", sentAt: t0)

    // MARK: - The buzz message

    @Test func messageShape() {
        let m = Self.buzz.message
        #expect(m["type"] as? String == "buzz")
        #expect(m["id"] as? String == "6F2A3C4E-1B2D-4E5F-8A9B-0C1D2E3F4A5B")
        #expect(m["name"] as? String == "Horrea Galbae")
        #expect(m["line"] as? String == "50 m til høyre")
        #expect(m["sentAt"] as? Double == 1_000_000)
        #expect(m.count == 5)
    }

    @Test func messageRoundTrip() {
        #expect(GuidedWalkBuzz(message: Self.buzz.message) == Self.buzz)
        let empty = GuidedWalkBuzz(id: Self.id, name: "", line: "", sentAt: Self.t0 + 0.5)
        #expect(GuidedWalkBuzz(message: empty.message) == empty)
    }

    @Test func wrongTypeMissingOrMalformedFieldIsNil() {
        let good = Self.buzz.message
        #expect(GuidedWalkBuzz(message: good) != nil)
        for key in ["type", "id", "name", "line", "sentAt"] {
            var m = good
            m[key] = nil
            #expect(GuidedWalkBuzz(message: m) == nil, "missing \(key)")
        }
        let wrong: [(String, Any)] = [
            ("type", "walk.state"), ("type", GuidedWalkBuzz.tellMessageType), ("id", "not-a-uuid"), ("id", 5),
            ("name", 5), ("line", false), ("sentAt", "1000000"),
        ]
        for (key, value) in wrong {
            var m = good
            m[key] = value
            #expect(GuidedWalkBuzz(message: m) == nil, "\(key) = \(value)")
        }
        // A buzz message is not a walk state or a command.
        #expect(GuidedWalkState(message: good) == nil)
        #expect(GuidedWalkCommand(message: good) == nil)
    }

    // MARK: - Freshness

    @Test func freshUpToMaxAgeInclusive() {
        #expect(GuidedWalkBuzz.maxAge == 120)
        // sentAt t0: age at t0 + 120 is 120 ≤ 120 → fresh; at t0 + 120.001 it is 120.001 > 120 → stale.
        #expect(Self.buzz.isFresh(now: Self.t0))
        #expect(Self.buzz.isFresh(now: Self.t0 + 120))
        #expect(!Self.buzz.isFresh(now: Self.t0 + 120.001))
        #expect(!Self.buzz.isFresh(now: Self.t0 + 3600))
        // The phone's clock a little ahead of the watch's: age −2 s ≤ 120 → fresh.
        #expect(Self.buzz.isFresh(now: Self.t0 - 2))
    }

    // MARK: - «Lytt» from the watch

    @Test func tellMessageRoundTrip() {
        let m = GuidedWalkBuzz.tellMessage(id: Self.id)
        #expect(m["type"] as? String == "buzz.tell")
        #expect(m["id"] as? String == Self.id.uuidString)
        #expect(m.count == 2)
        #expect(GuidedWalkBuzz.tellID(in: m) == Self.id)
    }

    @Test func tellIDIsNilForOtherMessages() {
        #expect(GuidedWalkBuzz.tellID(in: Self.buzz.message) == nil)
        #expect(GuidedWalkBuzz.tellID(in: ["type": "check.tell"]) == nil)
        #expect(GuidedWalkBuzz.tellID(in: ["type": "buzz.tell"]) == nil)
        #expect(GuidedWalkBuzz.tellID(in: ["type": "buzz.tell", "id": "nope"]) == nil)
        #expect(GuidedWalkBuzz.tellID(in: ["type": "buzz.tell", "id": 7]) == nil)
        #expect(GuidedWalkBuzz.tellID(in: [:]) == nil)
        // The tell message is not a buzz, a state or a walk command.
        let tell = GuidedWalkBuzz.tellMessage(id: Self.id)
        #expect(GuidedWalkBuzz(message: tell) == nil)
        #expect(GuidedWalkCommand(message: tell) == nil)
    }

    // MARK: - The buzz notification on the watch

    @Test func notificationBuzzIDOnlyForTheBuzzCategory() {
        #expect(GuidedWalkBuzz.notificationCategory == "BUZZ")
        #expect(GuidedWalkBuzz.notificationIDKey == "buzzID")
        let info: [AnyHashable: Any] = ["buzzID": Self.id.uuidString, "placeID": "osm:node/1"]
        #expect(GuidedWalkBuzz.notificationBuzzID(category: "BUZZ", userInfo: info) == Self.id)
        // The offer of the next part, a failure and a stop story carry buzz ids too, but are not the buzz.
        for other in ["MORE", "STORY_FAILED", "STOP", "CHECK", ""] {
            #expect(GuidedWalkBuzz.notificationBuzzID(category: other, userInfo: info) == nil, "\(other)")
        }
        #expect(GuidedWalkBuzz.notificationBuzzID(category: "BUZZ", userInfo: [:]) == nil)
        #expect(GuidedWalkBuzz.notificationBuzzID(category: "BUZZ", userInfo: ["buzzID": "x"]) == nil)
        #expect(GuidedWalkBuzz.notificationBuzzID(category: "BUZZ", userInfo: ["buzzID": Self.id]) == nil)
    }
}

@Suite struct RecentBuzzIDsTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)
    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    @Test func defaultWindowIsTenMinutes() {
        // 10 min × 60 s = 600 s.
        #expect(RecentBuzzIDs.defaultWindow == 600)
        #expect(RecentBuzzIDs().window == 600)
    }

    @Test func firstShowIsNewRepeatIsNot() {
        var recent = RecentBuzzIDs()
        #expect(!recent.contains(Self.a, now: Self.t0))
        let isNew1 = recent.remember(Self.a, now: Self.t0)
        #expect(isNew1)
        #expect(recent.contains(Self.a, now: Self.t0))
        let isNew2 = recent.remember(Self.a, now: Self.t0 + 1)
        #expect(!isNew2)
        // Another id is independent.
        #expect(!recent.contains(Self.b, now: Self.t0))
        let isNew3 = recent.remember(Self.b, now: Self.t0 + 1)
        #expect(isNew3)
    }

    @Test func rememberedForLessThanTheWindow() {
        var recent = RecentBuzzIDs()
        _ = recent.remember(Self.a, now: Self.t0)
        // Shown at t0: at t0 + 599.999 the age is 599.999 < 600 → still held; at t0 + 600 the age is 600, not < 600 →
        // forgotten.
        #expect(recent.contains(Self.a, now: Self.t0 + 599.999))
        #expect(!recent.contains(Self.a, now: Self.t0 + 600))
        #expect(!recent.contains(Self.a, now: Self.t0 + 3600))
    }

    @Test func aRepeatKeepsTheFirstTime() {
        var recent = RecentBuzzIDs()
        _ = recent.remember(Self.a, now: Self.t0)
        // Repeated at t0 + 300: refused, and the window still runs from t0, so it ends at t0 + 600, not t0 + 900.
        let isNew4 = recent.remember(Self.a, now: Self.t0 + 300)
        #expect(!isNew4)
        #expect(!recent.contains(Self.a, now: Self.t0 + 600))
    }

    @Test func anExpiredIDIsNewAgainAndOldOnesAreForgotten() {
        var recent = RecentBuzzIDs()
        _ = recent.remember(Self.a, now: Self.t0)
        _ = recent.remember(Self.b, now: Self.t0 + 100)
        #expect(recent.count == 2)
        // At t0 + 650: a's age 650 ≥ 600 → pruned and new again; b's age 550 < 600 → kept.
        let isNew5 = recent.remember(Self.a, now: Self.t0 + 650)
        #expect(isNew5)
        #expect(recent.count == 2)
        #expect(recent.contains(Self.b, now: Self.t0 + 650))
        // At t0 + 1300: b's age 1200 and a's age 650 are both ≥ 600 → both pruned; only the new id is held.
        let c = UUID()
        let isNew6 = recent.remember(c, now: Self.t0 + 1300)
        #expect(isNew6)
        #expect(recent.count == 1)
    }

    @Test func aShortWindow() {
        var recent = RecentBuzzIDs(window: 10)
        _ = recent.remember(Self.a, now: Self.t0)
        // Window 10: age 9 < 10 → held; age 10 → not.
        #expect(recent.contains(Self.a, now: Self.t0 + 9))
        #expect(!recent.contains(Self.a, now: Self.t0 + 10))
        let isNew7 = recent.remember(Self.a, now: Self.t0 + 10)
        #expect(isNew7)
    }
}
