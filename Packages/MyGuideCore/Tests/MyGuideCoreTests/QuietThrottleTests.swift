import Testing
@testable import MyGuideCore

@Suite struct QuietThrottleTests {
    static func due(_ id: String) -> DuePlace { DuePlace(id: id, name: id, tier: .good, distance: 10, excluded: false) }

    @Test func repeatedNoneDueLogsOnce() {
        var t = QuietThrottle()
        let r1 = t.shouldLog(.noneDue, due: [])
        #expect(r1)
        for _ in 0..<100 {
            let again = t.shouldLog(.noneDue, due: [])
            #expect(!again)
        }
        let a = Self.due("a"), b = Self.due("b")
        let r2 = t.shouldLog(.busy, due: [a])
        #expect(r2)
        let r3 = t.shouldLog(.busy, due: [a])
        #expect(!r3)
        let r4 = t.shouldLog(.busy, due: [a, b])
        #expect(r4)
        t.reset()
        let r5 = t.shouldLog(.busy, due: [a, b])
        #expect(r5)
    }

    @Test func dueOrderIrrelevant() {
        var t = QuietThrottle()
        let r6 = t.shouldLog(.busy, due: [Self.due("a"), Self.due("b")])
        #expect(r6)
        let r7 = t.shouldLog(.busy, due: [Self.due("b"), Self.due("a")])
        #expect(!r7)
    }

    @Test func reasonChangeLogs() {
        var t = QuietThrottle()
        let r8 = t.shouldLog(.busy, due: [Self.due("a")])
        #expect(r8)
        let r9 = t.shouldLog(.skipQuiet, due: [Self.due("a")])
        #expect(r9)
        let r10 = t.shouldLog(.busy, due: [Self.due("a")])
        #expect(r10)
    }

    @Test func resetAfterNothingLogged() {
        var t = QuietThrottle()
        t.reset()
        let r11 = t.shouldLog(.noneDue, due: [])
        #expect(r11)
    }
}
