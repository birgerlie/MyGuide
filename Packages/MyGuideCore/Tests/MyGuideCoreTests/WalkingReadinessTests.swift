import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingReadinessTests {
    @Test func readyWhenEverythingIsAllowed() {
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: true).isEmpty)
    }

    @Test func listsEveryProblemInOrder() {
        #expect(WalkingReadiness.problems(location: .whenInUse, notifications: .denied, hasAPIKey: false).map(\.rawValue) == [
            "Allow location “Always” so walking mode keeps working with the phone locked.",
            "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.",
            "Add your OpenAI API key in Settings first.",
        ])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .timeSensitiveOff, hasAPIKey: true).map(\.rawValue) == [
            "Location is off for MyGuide. Turn it on in Settings to use walking mode.",
            "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.",
        ])
        #expect(WalkingReadiness.problems(location: .notDetermined, notifications: .notDetermined, hasAPIKey: true).isEmpty)
    }

    @Test func eachProblemAloneGivesOneMessage() {
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: false)
            == [.noAPIKey])
        #expect(WalkingReadiness.problems(location: .always, notifications: .allowed, hasAPIKey: false).map(\.rawValue)
            == ["Add your OpenAI API key in Settings first."])
        #expect(WalkingReadiness.problems(location: .always, notifications: .timeSensitiveOff, hasAPIKey: true)
            == [.timeSensitiveOff])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .allowed, hasAPIKey: true)
            == [.locationOff])
        #expect(WalkingReadiness.problems(location: .whenInUse, notifications: .allowed, hasAPIKey: true)
            == [.locationNotAlways])
        #expect(WalkingReadiness.problems(location: .always, notifications: .denied, hasAPIKey: true)
            == [.notificationsOff])
        #expect(WalkingReadiness.problems(location: .always, notifications: .timeSensitiveOff, hasAPIKey: true).map(\.rawValue)
            == ["Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus."])
        #expect(WalkingReadiness.problems(location: .denied, notifications: .allowed, hasAPIKey: true).map(\.rawValue)
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

@Suite struct WalkingProblemTests {
    /// The rawValue travels to the watch (`GuidedWalkState.problem`): an older watch build looks the English sentence
    /// up, so these must stay today's sentences, character for character.
    @Test func rawValuesAreTodaysSentences() {
        #expect(WalkingProblem.locationOff.rawValue
                == "Location is off for MyGuide. Turn it on in Settings to use walking mode.")
        #expect(WalkingProblem.locationNotAlways.rawValue
                == "Allow location “Always” so walking mode keeps working with the phone locked.")
        #expect(WalkingProblem.notificationsOff.rawValue
                == "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.")
        #expect(WalkingProblem.timeSensitiveOff.rawValue
                == "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.")
        #expect(WalkingProblem.noAPIKey.rawValue == "Add your OpenAI API key in Settings first.")
        #expect(WalkingProblem.setUpOnPhone.rawValue == "Open MyGuide on your phone to finish setting up.")
        #expect(WalkingProblem.allCases.count == 6)
    }

    @Test func englishTextIsTheRawValue() {
        for problem in WalkingProblem.allCases {
            #expect(problem.text(.english) == problem.rawValue, "\(problem)")
        }
    }

    @Test func norwegianTexts() {
        #expect(WalkingProblem.locationOff.text(.norwegian)
                == "Posisjon er slått av for MyGuide. Slå den på i Innstillinger for å bruke gåmodus.")
        #expect(WalkingProblem.locationNotAlways.text(.norwegian)
                == "Tillat posisjon «Alltid», så virker gåmodus også med telefonen låst.")
        #expect(WalkingProblem.notificationsOff.text(.norwegian)
                == "Varsler er slått av, så MyGuide kan ikke gi deg beskjed. Slå dem på i Innstillinger.")
        #expect(WalkingProblem.timeSensitiveOff.text(.norwegian)
                == "Slå på tidsensitive varsler for MyGuide, så kommer varslene gjennom Fokus.")
        #expect(WalkingProblem.noAPIKey.text(.norwegian) == "Legg inn OpenAI-nøkkelen din i Innstillinger først.")
        #expect(WalkingProblem.setUpOnPhone.text(.norwegian) == "Åpne MyGuide på telefonen for å gjøre ferdig oppsettet.")
    }

    @Test func receivedTextIsLookedUpByItsSentence() {
        #expect(WalkingProblem.text(received: "Add your OpenAI API key in Settings first.", language: .norwegian)
                == "Legg inn OpenAI-nøkkelen din i Innstillinger først.")
        #expect(WalkingProblem.text(received: WalkingProblem.setUpOnPhone.rawValue, language: .english)
                == "Open MyGuide on your phone to finish setting up.")
    }

    @Test func unknownReceivedTextIsShownAsItCame() {
        // A newer phone may send a problem this build does not know; it is shown as received, in both languages.
        #expect(WalkingProblem.text(received: "Something else.", language: .norwegian) == "Something else.")
        #expect(WalkingProblem.text(received: "Something else.", language: .english) == "Something else.")
        #expect(WalkingProblem.text(received: "", language: .norwegian) == "")
        // Lookup is exact: a sentence with a changed character is unknown.
        #expect(WalkingProblem.text(received: "add your OpenAI API key in Settings first.", language: .norwegian)
                == "add your OpenAI API key in Settings first.")
    }
}
