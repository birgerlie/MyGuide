import Foundation
import Testing
@testable import MyGuideCore

@Suite struct RecentStoryTests {
    static let utc = TimeZone(identifier: "UTC")!
    // 1 000 000 s after 1970 = 11 d 13 h 46 m 40 s, so 13:46 UTC; + 12 min = 13:58.
    static let at = Date(timeIntervalSince1970: 1_000_000 + 12 * 60)

    // MARK: - firstSentence

    @Test func firstSentenceKeepsTheTerminatingPunctuation() {
        #expect(RecentStories.firstSentence("Built in 1697. It burned.") == "Built in 1697.")
        #expect(RecentStories.firstSentence("Is it old? Yes.") == "Is it old?")
        #expect(RecentStories.firstSentence("Look up! A spire.") == "Look up!")
    }
    @Test func firstSentenceReturnsTheWholeTextWithoutASentenceEnd() {
        #expect(RecentStories.firstSentence("No full stop") == "No full stop")
        // Punctuation not followed by whitespace is not a sentence end.
        #expect(RecentStories.firstSentence("Version 3.14 of the plan") == "Version 3.14 of the plan")
        // A final full stop with nothing after it has no following whitespace and is kept as part of the whole text.
        #expect(RecentStories.firstSentence("Only one.") == "Only one.")
        #expect(RecentStories.firstSentence("") == "")
    }
    @Test func firstSentenceCutsAtAnAbbreviation() {
        #expect(RecentStories.firstSentence("Visit St. Olav church.") == "Visit St.")
    }
    @Test func firstSentenceTreatsNewlineAsWhitespaceAfterPunctuation() {
        #expect(RecentStories.firstSentence("First line.\nSecond.") == "First line.")
    }
    @Test func longSingleSentenceIsTruncatedTo160() {
        // 60 words of "word" + space: 300 characters with no sentence end; cut at the last space at or before 160.
        let text = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let out = RecentStories.firstSentence(text)
        // 160 characters = 32 × "word " (5 each), so the window of 161 ends with a space at index 159; head is 31 words
        // plus "word" = 159 characters, plus "…" = 160.
        #expect(out.count <= RecentStories.sentenceLimit + 1)
        #expect(out.hasSuffix("…"))
        #expect(out.count == 160)
    }
    @Test func sentenceExactlyAtTheLimitIsNotTruncated() {
        let text = String(repeating: "a", count: 160)
        #expect(RecentStories.firstSentence(text) == text)
        #expect(RecentStories.firstSentence(text + "b").count == 161)
    }
    @Test func longFirstSentenceFollowedByMoreIsStillTruncated() {
        let long = String(repeating: "word ", count: 60) + "end. Next."
        let out = RecentStories.firstSentence(long)
        #expect(out.hasSuffix("…") && out.count <= 161)
    }

    // MARK: - line

    @Test func lineFormatForAPreparedBuzzStory() {
        let s = RecentStory(toldAt: Self.at, placeName: "Akershus Fortress", level: .first, text: "Built in 1697. It burned.", prepared: true)
        #expect(RecentStories.line(s, timeZone: Self.utc) == "- 13:58 Akershus Fortress level 1: \"Built in 1697.\" (prepared)")
    }
    @Test func lineFormatForAStopStoryUsesThisSpot() {
        let s = RecentStory(toldAt: Self.at, placeName: nil, level: .evenMore, text: "A quiet corner! Nothing more.", prepared: false)
        #expect(RecentStories.line(s, timeZone: Self.utc) == "- 13:58 this spot level 3: \"A quiet corner!\"")
    }
    @Test func lineUsesTheGivenTimeZone() {
        // 13:58 UTC; Oslo on 1970-01-12 is UTC+1 (CET), so 14:58.
        let s = RecentStory(toldAt: Self.at, placeName: "X", level: .more, text: "T.", prepared: false)
        #expect(RecentStories.line(s, timeZone: TimeZone(identifier: "Europe/Oslo")!) == "- 14:58 X level 2: \"T.\"")
    }

    // MARK: - priorsNotRecent

    @Test func priorsNotRecentDropsEqualLevelAndTextOnly() {
        let recent = [RecentStory(toldAt: Self.at, placeName: "A", level: .first, text: "same", prepared: false)]
        let priors = [
            PriorStory(placeID: "p", level: .first, text: "same", toldAt: Self.at),
            PriorStory(placeID: "p", level: .more, text: "same", toldAt: Self.at),
            PriorStory(placeID: "p", level: .first, text: "other", toldAt: Self.at),
        ]
        let kept = RecentStories.priorsNotRecent(priors, recent: recent)
        #expect(kept == [priors[1], priors[2]])
        #expect(RecentStories.priorsNotRecent(priors, recent: []) == priors)
        #expect(RecentStories.priorsNotRecent([], recent: recent).isEmpty)
    }
}
