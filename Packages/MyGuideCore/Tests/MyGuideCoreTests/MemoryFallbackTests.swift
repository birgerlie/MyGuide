import Testing
@testable import MyGuideCore

@Suite struct MemoryFallbackTests {
    @Test func reasonFollowsProtectedDataAvailability() {
        #expect(MemoryFallback.reason(protectedDataAvailable: false) == .lockedAtBackgroundLaunch)
        #expect(MemoryFallback.reason(protectedDataAvailable: true) == .storeFailed)
    }

    @Test func backgroundLaunchNoticeInTheStoryLanguage() {
        #expect(MemoryFallback.lockedAtBackgroundLaunch.notice(language: .norwegian)
                == "Historikken kunne ikke åpnes da appen startet i bakgrunnen. Lukk og åpne MyGuide for å lagre igjen.")
        #expect(MemoryFallback.lockedAtBackgroundLaunch.notice(language: .english)
                == "History couldn't be opened when the app started in the background. Close and reopen MyGuide to save again.")
    }

    @Test func generalNoticeIsUnchanged() {
        let text = "Memory is unavailable — stories won't be kept after you close the app."
        #expect(MemoryFallback.storeFailed.notice(language: .english) == text)
        #expect(MemoryFallback.storeFailed.notice(language: .norwegian) == text)
    }
}
