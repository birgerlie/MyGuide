import MyGuideCore

/// Every word on the diary, its rows, the library photo screen, the photo import summary and the day story (spec 15),
/// in the iPhone's language (`UILanguage.current`, spec 17). `countNote` is the exception: it is printed on the day
/// story's summary page, so it is given the story's own language.
enum DiaryTexts {
    static func title(_ language: StoryLanguage) -> String { AroundTexts.diaryTab(language) }

    static func addPhotos(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Legg til bilder" : "Add photos"
    }

    static func addingPhotos(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Legger til bilder …" : "Adding photos …"
    }

    static func ok(_ language: StoryLanguage) -> String { "OK" }

    static func cancel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avbryt" : "Cancel"
    }

    static func delete(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Slett" : "Delete"
    }

    static func close(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lukk" : "Close"
    }

    static func emptyTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen dagbokinnslag ennå" : "No diary entries yet"
    }

    static func emptyDescription(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Fotofortellinger, turfortellinger og bilder du legger til, samles her dag for dag."
            : "Photo stories, walk stories and photos you add are kept here by day."
    }

    static func failedTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Det gikk ikke" : "Couldn't complete that"
    }

    static func loadFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke laste dagboken." : "Couldn't load the diary."
    }

    static func deleteFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke slette bildet." : "Couldn't delete the photo."
    }

    // MARK: Rows

    static func dayStoryButton(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Dagsfortelling" : "Day story"
    }

    /// The kind shown on a walk story the walker chose on the map (a `.buzz` entry with `isChosen`).
    static func chosenOnMap(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Valgt på kartet" : "Chosen on the map"
    }

    /// The row's VoiceOver label: kind, title (and place), time; a library photo has its caption last. A chosen walk
    /// story says "Valgt på kartet" in place of "Turfortelling".
    static func rowLabel(kind: DiaryEntry.Kind, isChosen: Bool = false, title: String, place: String?, caption: String?,
                         time: String, _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        switch kind {
        case .photoStory: return "\(no ? "Fotofortelling" : "Photo story"), \(title), \(time)"
        case .buzz:
            let label = isChosen ? chosenOnMap(language) : (no ? "Turfortelling" : "Walk story")
            return "\(label), \(title)\(place.map { ", \($0)" } ?? ""), \(time)"
        case .stop: return "\(no ? "Fortelling fra stopp" : "Stop story"), \(title), \(time)"
        case .libraryPhoto: return "\(photo(language)), \(time)\(caption.map { ", \($0)" } ?? "")"
        }
    }

    // MARK: Library photo

    static func photo(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Bilde" : "Photo"
    }

    static func photoUnreadable(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Dette bildet kunne ikke åpnes." : "This photo couldn't be opened."
    }

    // MARK: Import summary

    /// "La til 1 bilde" / "Added 3 photos".
    static func importTitle(added: Int, _ language: StoryLanguage) -> String {
        if language == .norwegian { return added == 1 ? "La til 1 bilde" : "La til \(added) bilder" }
        return added == 1 ? "Added 1 photo" : "Added \(added) photos"
    }

    static func skippedNoDate(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) hoppet over (ingen dato)" : "\(count) skipped (no date)"
    }

    static func skippedNoAccess(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "\(count) hoppet over: gi tilgang til bilder i Innstillinger"
            : "\(count) skipped: allow photo access in Settings"
    }

    static func alreadyAdded(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) var lagt til fra før" : "\(count) already added"
    }

    static func unreadable(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) kunne ikke leses" : "\(count) couldn't be read"
    }

    // MARK: Day story

    static func writing(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriver dagsfortellingen …" : "Writing the day story …"
    }

    static func rendering(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gjør klar sidene …" : "Preparing pages …"
    }

    static func saveFailed(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Dagsfortellingen ble skrevet, men kunne ikke lagres."
            : "The day story was written but couldn't be saved."
    }

    static func shareFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke gjøre klar sidene for deling." : "Couldn't prepare the pages to share."
    }

    static func dayStoryUnreadable(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Denne dagsfortellingen kunne ikke åpnes." : "This day story couldn't be opened."
    }

    static func noDayStory(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen dagsfortelling ennå." : "No day story yet."
    }

    static func writeDayStory(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriv dagsfortelling" : "Write day story"
    }

    static func writeAgain(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriv på nytt" : "Write again"
    }

    static func share(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Del" : "Share"
    }

    static func confirmRewriteTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skrive dagsfortellingen på nytt?" : "Write the day story again?"
    }

    static func confirmRewriteMessage(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Den nye fortellingen erstatter denne." : "The new story replaces this one."
    }

    /// The summary page's note when the story was written from some of the day's photos: "3 av 12 bilder".
    static func countNote(sent: Int, total: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(sent) av \(total) bilder" : "\(sent) of \(total) photos"
    }
}
