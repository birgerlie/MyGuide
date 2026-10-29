import MyGuideCore

/// Every word on History, in the story language (spec 15). `corrupt` is also the diary's text for a story that cannot
/// be opened.
enum HistoryTexts {
    static func title(_ language: StoryLanguage) -> String { AroundTexts.history(language) }

    static func emptyTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen fortellinger ennå" : "No stories yet"
    }

    static func emptyDescription(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ta bilde av noe, så blir fortellingen om det lagret her."
            : "Photograph something and its story will be kept here."
    }

    static func failedTitle(_ language: StoryLanguage) -> String { DiaryTexts.failedTitle(language) }

    static func ok(_ language: StoryLanguage) -> String { DiaryTexts.ok(language) }

    static func corrupt(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Denne fortellingen kunne ikke åpnes." : "This story couldn't be opened."
    }

    static func deleteFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke slette fortellingen." : "Couldn't delete the story."
    }
}
