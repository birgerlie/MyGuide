import MyGuideCore

/// Every word on the «Rundt deg» screen and its tab bar, in the story language (spec 6.5, 14, 16).
enum AroundTexts {
    static func appName() -> String { "MyGuide" }

    static func title(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Rundt deg" : "Around you"
    }

    // MARK: Tabs

    static func exploreTab(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Utforsk" : "Explore"
    }

    static func diaryTab(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Dagbok" : "Diary"
    }

    static func history(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Historikk" : "History"
    }

    static func locate(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Vis meg på kartet" : "Show me on the map"
    }

    static func settings(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Innstillinger" : "Settings"
    }

    // MARK: States (spec 6.5, 16.6)

    static func loading(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner steder rundt deg …" : "Finding places around you …"
    }

    static func locating(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner posisjonen din …" : "Finding your position …"
    }

    static func noPlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen steder å fortelle om her ennå." : "Nothing to tell about here yet."
    }

    static func uncertainPosition(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Usikker posisjon" : "Uncertain position"
    }

    static func locationDenied(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Aktiver posisjon for å se steder rundt deg" : "Turn on location to see places around you"
    }

    static func openSettings(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Åpne Innstillinger" : "Open Settings"
    }

    // MARK: Card

    static func listen(_ language: StoryLanguage) -> String { ScreenText.listen(language) }

    static func stop(_ language: StoryLanguage) -> String { ScreenText.stop(language) }

    static func takePhoto(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ta et bilde" : "Take a photo"
    }

    static func openStoryHint(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Åpner fortellingen om stedet." : "Opens the story about the place."
    }

    static func selected(_ language: StoryLanguage) -> String {
        language == .norwegian ? "valgt" : "selected"
    }

    /// The marker's VoiceOver label: "Pantheon" or "Pantheon, valgt".
    static func markerLabel(_ name: String, isSelected: Bool, _ language: StoryLanguage) -> String {
        isSelected ? "\(name), \(selected(language))" : name
    }

    // MARK: Camera button (spec 14, 16.5)

    static func lookingAt(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hva ser jeg på?" : "What am I looking at?"
    }

    static func cameraLabel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ta bilde for å identifisere et sted" : "Take a photo to identify a place"
    }

    // MARK: Walking (spec 14, 16.4)

    static func goForAWalk(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gå en tur" : "Go for a walk"
    }

    static func continueWalk(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fortsett turen" : "Continue the walk"
    }

    static func walkLine(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Få beskjed om interessante steder underveis" : "Get told about interesting places on the way"
    }

    /// The same word in both languages.
    static func pause(_ language: StoryLanguage) -> String { "Pause" }

    static func stopWalk(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avslutt turen" : "End the walk"
    }

    static func more(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Mer" : "More"
    }

    static func skip(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hopp over" : "Skip"
    }

    // MARK: Expanded sheet (spec 16.3)

    static func nearbyPlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Steder i nærheten" : "Places nearby"
    }

    static func recentlyDiscovered(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Sist oppdaget" : "Recently discovered"
    }

    static func showMore(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Vis flere steder" : "Show more places"
    }

    static func showLess(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Vis færre" : "Show less"
    }

    /// "120 m", rounded as walking mode rounds distances (10 m steps).
    static func distance(_ metres: Double) -> String {
        "\(BuzzText.roundedDistance(metres)) m"
    }

    static func openFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke åpne fortellingen" : "Couldn't open the story"
    }

    static func openFailedMessage(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Denne fortellingen kunne ikke åpnes." : "This story couldn't be opened."
    }

    static func ok(_ language: StoryLanguage) -> String { "OK" }
}
