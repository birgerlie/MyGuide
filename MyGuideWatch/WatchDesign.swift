import MyGuideCore
import SwiftUI

/// The design package's colours on the watch, the same hex values as `Theme.Colour` on the phone. The watch uses the
/// system font for legibility (design package), so there are no font names here. The watch is always dark: forest
/// green behind, ivory text, an ivory primary button with forest text, stone secondary buttons and coral marks.
enum WatchColour {
    static let forest = Color(hex: 0x123D38)
    static let ivory = Color(hex: 0xFFF8E9)
    static let coral = Color(hex: 0xEC795D)
    static let stone = Color(hex: 0xDDD8CD)
}

/// A full-width command button: the primary one ivory with forest text (forest would vanish into the forest
/// background), the secondary ones stone with forest text.
struct WatchButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(WatchColour.forest)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(primary ? WatchColour.ivory : WatchColour.stone, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

/// Every word on the watch, in the watch's own language (spec 17): Norwegian when its first preferred language is
/// Norwegian (nb, no or nn), English otherwise, by the same rule as the phone's screen texts
/// (`StoryLanguage.matching`). The phone does not send its language to the watch. The phone's reason for a failed
/// start arrives in English and is shown with `problem(_:)`.
enum WatchTexts {
    /// Read once: watchOS ends the app when the watch's language changes.
    static let norwegian = StoryLanguage.matching(preferredLanguages: Locale.preferredLanguages) == .norwegian

    static var title: String { norwegian ? "Guidet tur" : "Guided walk" }
    static var check: String { norwegian ? "Sjekk" : "Check" }

    // MARK: Commands

    static var start: String { "Start" }
    static var stop: String { norwegian ? "Stopp" : "Stop" }
    static var pause: String { "Pause" }
    static var resume: String { norwegian ? "Fortsett" : "Resume" }

    static var starting: String { norwegian ? "Starter …" : "Starting…" }
    static var pausing: String { norwegian ? "Pauser …" : "Pausing…" }
    static var resuming: String { norwegian ? "Fortsetter …" : "Resuming…" }
    static var stopping: String { norwegian ? "Stopper …" : "Stopping…" }

    /// The phone's walk state in words: "Går · 2 varsler" / "Walking · 2 buzzes".
    static func label(_ state: GuidedWalkState?) -> String {
        guard let state else { return off }
        let no = norwegian
        switch state.phase {
        case .off: return off
        case .starting: return starting
        case .walking:
            let count = state.buzzCount
            return no ? "Går · \(count) \(count == 1 ? "varsel" : "varsler")"
                : "Walking · \(count) \(count == 1 ? "buzz" : "buzzes")"
        case .pausedAuto: return no ? "Pause · står stille" : "Paused · not moving"
        case .pausedManual: return no ? "Pause" : "Paused"
        }
    }

    static var off: String { norwegian ? "Av" : "Off" }

    /// The phone's reason for a failed start (English on the wire) in the watch's language; a text it does not know
    /// is shown as it came.
    static func problem(_ text: String) -> String {
        WalkingReadiness.localized(text, language: norwegian ? .norwegian : .english)
    }

    // MARK: Walk notes and errors

    static var notReachable: String {
        norwegian ? "Telefonen svarer ikke. Åpne MyGuide på telefonen." : "Phone not reachable. Open MyGuide on your phone."
    }

    static var notSaved: String { norwegian ? "Ikke lagret i Helse" : "Not saved to Health" }
    static var workoutEnded: String { norwegian ? "Treningsøkten ble avsluttet" : "Workout ended" }

    static var linkNotActive: String { norwegian ? "Telefonkoblingen er ikke aktiv" : "Phone link not active" }
    static var phoneNotReachable: String { norwegian ? "Telefonen svarer ikke" : "Phone not reachable" }
    static var unexpectedReply: String { norwegian ? "Uventet svar fra telefonen" : "Unexpected reply from the phone" }

    static var notAuthorized: String {
        norwegian ? "Har ikke lov til å lagre treningsøkter" : "Not allowed to save workouts"
    }

    static var endedWhileStarting: String {
        norwegian ? "Treningsøkten ble avsluttet mens den startet" : "The workout ended while starting"
    }

    // MARK: Buzz

    private static var language: StoryLanguage { norwegian ? .norwegian : .english }
    /// The card's heading, as on the phone's notification: "Sted i nærheten" / "Nearby place".
    static var nearbyPlace: String { NotificationText.nearbyLabel(language) }
    static var listen: String { norwegian ? "Lytt" : "Listen" }
    static var listenSent: String { norwegian ? "Sendt til telefonen" : "Sent to your phone" }

    // MARK: Check

    static var notStarted: String { norwegian ? "Ikke startet" : "Not started" }
    static var notTried: String { norwegian ? "Ikke prøvd" : "Not tried" }
    static var startHapticTest: String { norwegian ? "Start vibrasjonstest" : "Start haptic test" }
    static var notDuringWalk: String {
        norwegian ? "Ikke tilgjengelig under en guidet tur." : "Not available during a guided walk."
    }
    static var pingPhone: String { norwegian ? "Ping telefonen" : "Ping phone" }
    static var pinging: String { norwegian ? "Pinger …" : "Pinging…" }
    static func pong(ms: Int) -> String { norwegian ? "Svar på \(ms) ms" : "Pong in \(ms) ms" }
    static func pingFailed(_ description: String) -> String {
        "\(norwegian ? "Feilet" : "Failed"): \(description)"
    }

    static func testFailed(_ description: String) -> String {
        "\(norwegian ? "Testen feilet" : "Test failed"): \(description)"
    }

    static var testRunning: String {
        norwegian
            ? "Testen kjører. Senk armen: dobbel vibrasjon hvert 30. sekund i 2 min."
            : "Test running. Lower your wrist: a double buzz every 30 s for 2 min."
    }

    static var buzzesDone: String { norwegian ? "Testen kjører. Vibrasjonene er ferdige." : "Test running. Buzzes done." }
    static var stopped: String { norwegian ? "Stoppet" : "Stopped" }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
