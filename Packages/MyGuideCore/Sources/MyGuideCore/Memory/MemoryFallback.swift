import Foundation

/// Why memory is held in RAM only for this run: the persistent store could not be opened at launch.
public enum MemoryFallback: Sendable, Equatable {
    /// The store failed to open for any other reason.
    case storeFailed
    /// The app was launched in the background (a location wake) before the phone's first unlock, so the protected
    /// store file could not be read. Closing and reopening the app opens it again.
    case lockedAtBackgroundLaunch

    /// The reason for a store that failed to open, from whether protected data was available at that moment.
    public static func reason(protectedDataAvailable: Bool) -> MemoryFallback {
        protectedDataAvailable ? .storeFailed : .lockedAtBackgroundLaunch
    }

    /// The banner text in the memory-warning place. The background-launch text comes in the story language; the
    /// general one stays as it always was.
    public func notice(language: StoryLanguage) -> String {
        switch self {
        case .storeFailed:
            "Memory is unavailable — stories won't be kept after you close the app."
        case .lockedAtBackgroundLaunch:
            language == .norwegian
                ? "Historikken kunne ikke åpnes da appen startet i bakgrunnen. Lukk og åpne MyGuide for å lagre igjen."
                : "History couldn't be opened when the app started in the background. Close and reopen MyGuide to save again."
        }
    }
}
