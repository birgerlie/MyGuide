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

    @Test func canStart() {
        // Only "Always" missing, or nothing missing, may start; anything else blocks.
        #expect(WalkingReadiness.canStart(location: .always, notifications: .allowed, hasAPIKey: true))
        #expect(WalkingReadiness.canStart(location: .whenInUse, notifications: .allowed, hasAPIKey: true))
        #expect(WalkingReadiness.canStart(location: .always, notifications: .timeSensitiveOff, hasAPIKey: true))
        #expect(!WalkingReadiness.canStart(location: .whenInUse, notifications: .denied, hasAPIKey: true))
        #expect(!WalkingReadiness.canStart(location: .denied, notifications: .allowed, hasAPIKey: true))
        #expect(!WalkingReadiness.canStart(location: .always, notifications: .allowed, hasAPIKey: false))
        #expect(!WalkingReadiness.canStart(location: .whenInUse, notifications: .allowed, hasAPIKey: false))
    }
}

@Suite struct WalkingReadinessLocalizedTests {
    @Test func everyProblemHasANorwegianText() {
        let all = WalkingReadiness.problems(location: .denied, notifications: .denied, hasAPIKey: false)
            + WalkingReadiness.problems(location: .whenInUse, notifications: .timeSensitiveOff, hasAPIKey: true)
        #expect(all.count == 5)
        for problem in all {
            let nb = WalkingReadiness.localized(problem, language: .norwegian)
            #expect(nb != problem, "\(problem)")
            #expect(WalkingReadiness.localized(problem, language: .english) == problem)
        }
        #expect(WalkingReadiness.localized("Add your OpenAI API key in Settings first.", language: .norwegian)
                == "Legg inn OpenAI-nøkkelen din i Innstillinger først.")
    }

    @Test func setupProblemHasANorwegianText() {
        #expect(WalkingReadiness.setupProblem == "Open MyGuide on your phone to finish setting up.")
        #expect(WalkingReadiness.localized(WalkingReadiness.setupProblem, language: .norwegian)
                == "Åpne MyGuide på telefonen for å gjøre ferdig oppsettet.")
        #expect(WalkingReadiness.localized(WalkingReadiness.setupProblem, language: .english)
                == WalkingReadiness.setupProblem)
    }

    @Test func unknownTextIsUnchanged() {
        #expect(WalkingReadiness.localized("Something else.", language: .norwegian) == "Something else.")
    }
}
