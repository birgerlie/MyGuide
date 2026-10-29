import Testing
@testable import MyGuideCore

@Suite struct NotificationTextTests {
    @Test func fixedTexts() {
        let nb = StoryLanguage.norwegian, en = StoryLanguage.english
        #expect(NotificationText.listen(nb) == "Lytt");  #expect(NotificationText.listen(en) == "Listen")
        #expect(NotificationText.skip(nb) == "Hopp over");  #expect(NotificationText.skip(en) == "Skip")
        #expect(NotificationText.more(nb) == "Mer");  #expect(NotificationText.more(en) == "More")
        #expect(NotificationText.moreBody(nb) == "Trykk Mer for neste del.")
        #expect(NotificationText.moreBody(en) == "Tap More for the next part.")
        #expect(NotificationText.failedTitle(nb) == "Fikk ikke hentet fortellingen")
        #expect(NotificationText.failedTitle(en) == "Couldn't get the story")
        #expect(NotificationText.nearbyLabel(nb) == "Sted i nærheten")
        #expect(NotificationText.nearbyLabel(en) == "Nearby place")
        #expect(NotificationText.nextPartLabel(nb) == "Neste del")
        #expect(NotificationText.nextPartLabel(en) == "Next part")
        #expect(NotificationText.stoppedLabel(nb) == "Her du stoppet")
        #expect(NotificationText.stoppedLabel(en) == "Where you stopped")
    }

    @Test func creditVariants() {
        let nb = StoryLanguage.norwegian, en = StoryLanguage.english
        #expect(NotificationText.photoCredit(author: "A", licence: "CC BY-SA 4.0", nb) == "Foto: A, CC BY-SA 4.0, Wikimedia Commons")
        #expect(NotificationText.photoCredit(author: "A", licence: "CC BY-SA 4.0", en) == "Photo: A, CC BY-SA 4.0, Wikimedia Commons")
        #expect(NotificationText.photoCredit(author: "A", licence: nil, nb) == "Foto: A, Wikimedia Commons")
        #expect(NotificationText.photoCredit(author: nil, licence: "CC0", en) == "Photo: CC0, Wikimedia Commons")
        #expect(NotificationText.photoCredit(author: nil, licence: nil, nb) == nil)
        // empty strings count as missing
        #expect(NotificationText.photoCredit(author: "", licence: "  ", en) == nil)
        #expect(NotificationText.photoCredit(author: "", licence: "CC0", en) == "Photo: CC0, Wikimedia Commons")
    }

    // MARK: Stop excerpt (spec 12.9: the first two lines of level 1, up to 2 sentences, at most 160 characters)

    @Test func stopExcerptKeepsTwoSentencesThatFit() {
        // Hand: "Du står ved det gamle torget." = 29, "Her var det marked før." = 23; 29 + 1 + 23 = 53 ≤ 160
        // → both, the third is left out.
        #expect(NotificationText.stopExcerpt("Du står ved det gamle torget. Her var det marked før. I dag er det parkering.")
                == "Du står ved det gamle torget. Her var det marked før.")
    }

    @Test func stopExcerptJoinsParagraphsWithOneSpace() {
        #expect(NotificationText.stopExcerpt("  Den første setningen her.\n\nDen andre setningen her! Tredje.  ")
                == "Den første setningen her. Den andre setningen her!")
    }

    @Test func stopExcerptSingleSentenceAndNoPunctuation() {
        #expect(NotificationText.stopExcerpt("Bare én setning.") == "Bare én setning.")
        #expect(NotificationText.stopExcerpt("ingen punktum her") == "ingen punktum her")
    }

    @Test func stopExcerptDropsSecondSentenceThatWouldPassTheLimit() {
        // Hand: first = 100 chars ("A" × 99 + "."), second = 60 chars ("B" × 59 + "."); 100 + 1 + 60 = 161 > 160
        // → the first alone (100 ≤ 160, uncut).
        let first = String(repeating: "A", count: 99) + "."
        let second = "B" + String(repeating: "b", count: 58) + "."
        #expect(NotificationText.stopExcerpt(first + " " + second) == first)
        // Hand: second one shorter, 59 chars: 100 + 1 + 59 = 160 ≤ 160 → both, exactly 160 characters.
        let shorter = "B" + String(repeating: "b", count: 57) + "."
        let both = NotificationText.stopExcerpt(first + " " + shorter)
        #expect(both == first + " " + shorter)
        #expect(both?.count == 160)
    }

    @Test func stopExcerptCutsALongFirstSentenceAtAWord() {
        // Hand: 40 words "ordet" (5 chars) joined by spaces = 40 × 5 + 39 = 239 chars, one sentence with "." = 240.
        // prefix(160): words start at 0, 6, 12, …; the space before word k is at 6k − 1. The last space at index
        // ≤ 159 is 6 × 26 − 1 = 155 → keep chars 0..<155 = 26 words (26 × 5 + 25 = 155) + "…" = 156 characters.
        let long = Array(repeating: "ordet", count: 40).joined(separator: " ") + "."
        let cut = NotificationText.stopExcerpt(long)
        #expect(cut == Array(repeating: "ordet", count: 26).joined(separator: " ") + "…")
        #expect(cut?.count == 156)
    }

    @Test func stopExcerptDoesNotSplitAtAbbreviations() {
        // "St." and "ca." are not boundaries, so the excerpt's sentences are whole ones.
        // Hand: first "St. Olavs kirke ble bygget ca. 1250 av kongen." = 46; rest "Den brant i 1700. Mer her." →
        // "Den brant i 1700." = 17 < 20 → joined with "Mer her." → 17 + 1 + 8 = 26; 46 + 1 + 26 = 73 ≤ 160 → both.
        #expect(NotificationText.stopExcerpt("St. Olavs kirke ble bygget ca. 1250 av kongen. Den brant i 1700. Mer her.")
                == "St. Olavs kirke ble bygget ca. 1250 av kongen. Den brant i 1700. Mer her.")
    }

    @Test func stopExcerptOfEmptyTextIsNil() {
        #expect(NotificationText.stopExcerpt("") == nil)
        #expect(NotificationText.stopExcerpt(" \n ") == nil)
    }
}
