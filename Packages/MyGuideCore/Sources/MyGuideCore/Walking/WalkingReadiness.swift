import Foundation

/// What stands between the owner and walking mode (design 7.8), as the problems to show.
public enum WalkingReadiness {
    public enum Location: Sendable { case always, whenInUse, denied, notDetermined }
    public enum Notifications: Sendable { case allowed, timeSensitiveOff, denied, notDetermined }

    /// The problems, in this order, for whatever is missing. Empty → ready.
    /// `.notDetermined` gives no problem: the controller asks for that permission first.
    public static func problems(location: Location, notifications: Notifications, hasAPIKey: Bool) -> [WalkingProblem] {
        var problems: [WalkingProblem] = []
        switch location {
        case .denied: problems.append(.locationOff)
        case .whenInUse: problems.append(.locationNotAlways)
        case .always, .notDetermined: break
        }
        switch notifications {
        case .denied: problems.append(.notificationsOff)
        case .timeSensitiveOff: problems.append(.timeSensitiveOff)
        case .allowed, .notDetermined: break
        }
        if !hasAPIKey { problems.append(.noAPIKey) }
        return problems
    }

    /// Whether walking mode may start. "Always" missing does not block (it still works while the app is in use),
    /// and neither does Time Sensitive being off (buzzes still arrive outside Focus); a denied location or
    /// notifications, or a missing key, do. `.notDetermined` does not block here: the controller asks first.
    public static func canStart(location: Location, notifications: Notifications, hasAPIKey: Bool) -> Bool {
        location != .denied && notifications != .denied && hasAPIKey
    }
}

/// Something that keeps walking mode from starting, or that it lacks while on. The rawValue is the English sentence,
/// which is what travels to the watch (`GuidedWalkState.problem`): a watch build of any age looks it up by that
/// sentence, so a rawValue never changes.
public enum WalkingProblem: String, Sendable, CaseIterable {
    case locationOff = "Location is off for MyGuide. Turn it on in Settings to use walking mode."
    case locationNotAlways = "Allow location “Always” so walking mode keeps working with the phone locked."
    case notificationsOff = "Notifications are off, so MyGuide can't buzz you. Turn them on in Settings."
    case timeSensitiveOff = "Turn on Time Sensitive notifications for MyGuide so buzzes get through Focus."
    case noAPIKey = "Add your OpenAI API key in Settings first."
    /// A start from the watch that cannot start without prompts on the phone (spec 5.3).
    case setUpOnPhone = "Open MyGuide on your phone to finish setting up."

    /// The problem in the screen language (`UILanguage` on the phone, `WatchTexts` on the watch). English is the
    /// rawValue itself.
    public func text(_ language: StoryLanguage) -> String {
        switch language {
        case .english: rawValue
        case .norwegian:
            switch self {
            case .locationOff: "Posisjon er slått av for MyGuide. Slå den på i Innstillinger for å bruke gåmodus."
            case .locationNotAlways: "Tillat posisjon «Alltid», så virker gåmodus også med telefonen låst."
            case .notificationsOff: "Varsler er slått av, så MyGuide kan ikke gi deg beskjed. Slå dem på i Innstillinger."
            case .timeSensitiveOff: "Slå på tidsensitive varsler for MyGuide, så kommer varslene gjennom Fokus."
            case .noAPIKey: "Legg inn OpenAI-nøkkelen din i Innstillinger først."
            case .setUpOnPhone: "Åpne MyGuide på telefonen for å gjøre ferdig oppsettet."
            }
        }
    }

    /// A problem as it came from the phone, in the screen language. A sentence this build does not know (from a newer
    /// phone) is shown as it came.
    public static func text(received: String, language: StoryLanguage) -> String {
        WalkingProblem(rawValue: received)?.text(language) ?? received
    }
}
