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
}
