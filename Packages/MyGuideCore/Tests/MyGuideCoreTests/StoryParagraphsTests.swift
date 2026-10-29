import Testing
@testable import MyGuideCore

/// Story text split into paragraphs for spacing on screen.
@Suite struct StoryParagraphsTests {
    @Test func blankLineSeparatesParagraphs() {
        #expect(StoryParagraphs.split("Første avsnitt.\n\nAndre avsnitt.") == ["Første avsnitt.", "Andre avsnitt."])
    }

    @Test func singleLineBreakAlsoSeparates() {
        #expect(StoryParagraphs.split("En.\nTo.") == ["En.", "To."])
    }

    @Test func runsOfBreaksAndWhitespaceLinesGiveNoEmptyParagraphs() {
        #expect(StoryParagraphs.split("En.\n \n\n\t\nTo.") == ["En.", "To."])
    }

    @Test func windowsLineBreaks() {
        #expect(StoryParagraphs.split("En.\r\n\r\nTo.") == ["En.", "To."])
    }

    @Test func paragraphsAreTrimmed() {
        #expect(StoryParagraphs.split("  En.  \n\n  To. ") == ["En.", "To."])
    }

    @Test func oneParagraphStaysWhole() {
        #expect(StoryParagraphs.split("Bare ett avsnitt, med komma.") == ["Bare ett avsnitt, med komma."])
    }

    @Test func emptyAndWhitespaceOnlyGiveNothing() {
        #expect(StoryParagraphs.split("") == [])
        #expect(StoryParagraphs.split(" \n\n ") == [])
    }

    @Test func streamingTextKeepsItsUnfinishedLastParagraph() {
        #expect(StoryParagraphs.split("Ferdig avsnitt.\n\nHalvt avs") == ["Ferdig avsnitt.", "Halvt avs"])
        // A break that has just arrived adds no empty paragraph.
        #expect(StoryParagraphs.split("Ferdig avsnitt.\n") == ["Ferdig avsnitt."])
    }

    @Test func innerSpacesAreKept() {
        #expect(StoryParagraphs.split("Ord  med  mellomrom.") == ["Ord  med  mellomrom."])
    }
}
