import Foundation

/// How a stored API key may be shown: never in full.
public enum APIKeyDisplay {
    /// Shorter keys show no suffix at all, so the visible part is always a small share of the key.
    public static let minimumLengthForSuffix = 12

    /// The last 4 characters for keys of at least `minimumLengthForSuffix` characters, else nil.
    public static func visibleSuffix(of key: String) -> String? {
        key.count >= minimumLengthForSuffix ? String(key.suffix(4)) : nil
    }
}
