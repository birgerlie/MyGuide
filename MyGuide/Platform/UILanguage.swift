import Foundation
import MyGuideCore

/// The language of the screen (spec 17): the iPhone's language when it is Norwegian (nb, no or nn), English for any
/// other. Buttons, labels, status lines, notification actions and titles, the Live Activity and error messages use
/// it; stories, prompts, Wikipedia and the content lines that belong to a story (the factual line, the place kind,
/// the photo credit) use the story language instead.
///
/// It is read once per process: iOS ends the app when the device language or the app's own language in Settings
/// changes, so it cannot change under a running app.
enum UILanguage {
    nonisolated static let current = StoryLanguage.matching(preferredLanguages: Locale.preferredLanguages)
}
