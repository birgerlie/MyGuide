import Foundation
import MyGuideCore

/// The language of the screen (spec 17): Norwegian when the app runs in Norwegian, English for any other. Buttons,
/// labels, status lines, notification actions and titles, the Live Activity and error messages use it; stories,
/// prompts, Wikipedia and the content lines that belong to a story (the factual line, the place kind, the photo
/// credit) use the story language instead.
///
/// "Runs in Norwegian" is the localization iOS picked for the app bundle (`Bundle.main.preferredLocalizations`), so
/// the app's own texts match what iOS shows for it (permission prompts, dates): a device set to Danish, then Norwegian
/// Bokmål gets Norwegian, and the app's own language in Settings counts. Without a usable bundle localization the
/// iPhone's first preferred language decides (nb, no or nn → Norwegian).
///
/// It is read once per process: iOS ends the app when the device language or the app's own language in Settings
/// changes, so it cannot change under a running app.
enum UILanguage {
    nonisolated static let current = StoryLanguage.screen(bundleLocalization: Bundle.main.preferredLocalizations.first,
                                                          preferredLanguages: Locale.preferredLanguages)
}
