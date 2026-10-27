import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingReadinessTests {
    @Test func readyWhenEverythingIsAllowed() {
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: true).isEmpty)
    }

    @Test func listsEveryProblemInOrder() {
        #expect(WalkingReadiness.problems(location: .whenInUse, notifications: .denied, hasAPIKey: false) == [
            "Allow location “Always” so walking mode keeps working with the phone locked.",
            "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.",
            "Add your OpenAI API key in Settings first.",
        ])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .timeSensitiveOff, hasAPIKey: true) == [
            "Location is off for MyGuide. Turn it on in Settings to use walking mode.",
            "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.",
        ])
        #expect(WalkingReadiness.problems(location: .notDetermined, notifications: .notDetermined, hasAPIKey: true).isEmpty)
    }

    @Test func eachProblemAloneGivesOneMessage() {
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: false)
            == ["Add your OpenAI API key in Settings first."])
        #expect(WalkingReadiness.problems(location: .always, notifications: .timeSensitiveOff, hasAPIKey: true)
            == ["Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus."])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .allowed, hasAPIKey: true)
            == ["Location is off for MyGuide. Turn it on in Settings to use walking mode."])
    }
}
