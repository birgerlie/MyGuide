import Foundation
import Testing
@testable import MyGuideCore

/// Spec 17: Norwegian when the iPhone's first preferred language is nb, no or nn; English for anything else.
@Suite struct StoryLanguageTests {
    @Test func norwegianCodesWithAndWithoutRegion() {
        for code in ["nb", "no", "nn", "nb-NO", "no-NO", "nn-NO", "nb_NO", "nb-SJ", "NB-no"] {
            #expect(StoryLanguage.matching(preferredLanguages: [code]) == .norwegian, "\(code)")
        }
    }

    @Test func everyOtherLanguageFallsBackToEnglish() {
        for code in ["en", "en-US", "en-GB", "sv-SE", "da-DK", "de", "it-IT", "zh-Hans-CN", "se-NO", "nl"] {
            #expect(StoryLanguage.matching(preferredLanguages: [code]) == .english, "\(code)")
        }
    }

    /// Only the first language decides: a Norwegian second choice does not win over a German first one.
    @Test func onlyTheFirstLanguageDecides() {
        #expect(StoryLanguage.matching(preferredLanguages: ["de-DE", "nb-NO"]) == .english)
        #expect(StoryLanguage.matching(preferredLanguages: ["nn-NO", "en-US"]) == .norwegian)
    }

    @Test func emptyOrMalformedIsEnglish() {
        #expect(StoryLanguage.matching(preferredLanguages: []) == .english)
        #expect(StoryLanguage.matching(preferredLanguages: [""]) == .english)
        #expect(StoryLanguage.matching(preferredLanguages: ["-"]) == .english)
        // A code that merely starts with the letters is not Norwegian.
        #expect(StoryLanguage.matching(preferredLanguages: ["nbx"]) == .english)
        #expect(StoryLanguage.matching(preferredLanguages: ["non"]) == .english)
    }
}
