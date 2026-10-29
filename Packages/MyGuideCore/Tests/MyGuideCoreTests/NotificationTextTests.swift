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
}
