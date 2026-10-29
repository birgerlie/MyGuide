import Foundation

/// Fixed notification copy in both story languages.
public enum NotificationText {
    private static func pick(_ l: StoryLanguage, nb: String, en: String) -> String {
        l == .norwegian ? nb : en
    }

    public static func listen(_ l: StoryLanguage) -> String { pick(l, nb: "Lytt", en: "Listen") }
    public static func skip(_ l: StoryLanguage) -> String { pick(l, nb: "Hopp over", en: "Skip") }
    public static func more(_ l: StoryLanguage) -> String { pick(l, nb: "Mer", en: "More") }
    public static func moreBody(_ l: StoryLanguage) -> String {
        pick(l, nb: "Trykk Mer for neste del.", en: "Tap More for the next part.")
    }
    public static func failedTitle(_ l: StoryLanguage) -> String {
        pick(l, nb: "Fikk ikke hentet fortellingen", en: "Couldn't get the story")
    }
    public static func nearbyLabel(_ l: StoryLanguage) -> String { pick(l, nb: "Sted i nærheten", en: "Nearby place") }
    public static func nextPartLabel(_ l: StoryLanguage) -> String { pick(l, nb: "Neste del", en: "Next part") }
    public static func stoppedLabel(_ l: StoryLanguage) -> String { pick(l, nb: "Her du stoppet", en: "Where you stopped") }

    /// "Foto: Author, Licence, Wikimedia Commons"; empty parts are left out, nil when there is neither author nor licence.
    public static func photoCredit(author: String?, licence: String?, _ l: StoryLanguage) -> String? {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        let parts = [clean(author), clean(licence)].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return (pick(l, nb: "Foto: ", en: "Photo: ") + (parts + ["Wikimedia Commons"]).joined(separator: ", "))
    }
}
