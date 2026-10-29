import Foundation

/// What stands between the owner and walking mode (design 7.8), as the messages to show.
public enum WalkingReadiness {
    public enum Location: Sendable { case always, whenInUse, denied, notDetermined }
    public enum Notifications: Sendable { case allowed, timeSensitiveOff, denied, notDetermined }

    /// Exact messages, in this order, for whatever is missing. Empty → ready.
    /// `.notDetermined` gives no message: the controller asks for that permission first.
    public static func problems(location: Location, notifications: Notifications, hasAPIKey: Bool) -> [String] {
        var problems: [String] = []
        switch location {
        case .denied:
            problems.append("Location is off for MyGuide. Turn it on in Settings to use walking mode.")
        case .whenInUse:
            problems.append("Allow location “Always” so walking mode keeps working with the phone locked.")
        case .always, .notDetermined:
            break
        }
        switch notifications {
        case .denied:
            problems.append("Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.")
        case .timeSensitiveOff:
            problems.append("Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.")
        case .allowed, .notDetermined:
            break
        }
        if !hasAPIKey { problems.append("Add your OpenAI API key in Settings first.") }
        return problems
    }

    /// The problem of a start from the watch that cannot start without prompts on the phone (spec 5.3). It travels to
    /// the watch in English, like the rest, and the watch shows it with `localized` in its own language.
    public static let setupProblem = "Open MyGuide on your phone to finish setting up."

    /// A problem from `problems` (or `setupProblem`) in the story language: the English text itself, or its Norwegian version. A text
    /// that is not one of `problems`' is returned unchanged.
    public static func localized(_ problem: String, language: StoryLanguage) -> String {
        guard language == .norwegian else { return problem }
        return norwegian[problem] ?? problem
    }

    private static let norwegian: [String: String] = [
        "Location is off for MyGuide. Turn it on in Settings to use walking mode.":
            "Posisjon er slått av for MyGuide. Slå den på i Innstillinger for å bruke gåmodus.",
        "Allow location “Always” so walking mode keeps working with the phone locked.":
            "Tillat posisjon «Alltid», så virker gåmodus også med telefonen låst.",
        "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings.":
            "Varsler er slått av, så MyGuide kan ikke gi deg beskjed. Slå dem på i Innstillinger.",
        "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus.":
            "Slå på tidsensitive varsler for MyGuide, så kommer varslene gjennom Fokus.",
        "Add your OpenAI API key in Settings first.":
            "Legg inn OpenAI-nøkkelen din i Innstillinger først.",
        setupProblem:
            "Åpne MyGuide på telefonen for å gjøre ferdig oppsettet.",
    ]

    /// Whether walking mode may start. "Always" missing does not block (it still works while the app is in use),
    /// and neither does Time Sensitive being off (buzzes still arrive outside Focus); a denied location or
    /// notifications, or a missing key, do. `.notDetermined` does not block here: the controller asks first.
    public static func canStart(location: Location, notifications: Notifications, hasAPIKey: Bool) -> Bool {
        location != .denied && notifications != .denied && hasAPIKey
    }
}
