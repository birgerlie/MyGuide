import Foundation

/// Where the OpenAI key comes from: the one the owner entered in Settings (Keychain) wins; otherwise a test build may
/// carry one in its Info.plist (`MGBundledOpenAIKey`, from the git-ignored Config/Local.xcconfig).
public enum APIKeySource: Sendable, Equatable {
    case stored(String)
    case bundled(String)

    public var key: String {
        switch self {
        case .stored(let key), .bundled(let key): key
        }
    }

    /// Both values are trimmed; a blank value, or a build variable left unexpanded ("$(…)"), is no key.
    public static func resolve(stored: String?, bundled: String?) -> APIKeySource? {
        if let key = usable(stored) { return .stored(key) }
        if let key = usable(bundled) { return .bundled(key) }
        return nil
    }

    private static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
