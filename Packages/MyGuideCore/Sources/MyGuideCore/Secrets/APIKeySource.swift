import Foundation

/// The user's own OpenAI key, as entered in Settings and kept in the Keychain. With one, the app talks straight to
/// OpenAI; without one, it goes through the guide server (spec 8).
public enum APIKeySource {
    /// `value` trimmed of whitespace and newlines at both ends; nil, or blank after trimming, is no key.
    public static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
