import MyGuideCore

/// Every word on the «Turer» tab and its preview (tours spec 5, 6), in the language it is given: the iPhone's
/// (`UILanguage.current`). Numbers come from `TourFormat`.
enum ToursTexts {
    // MARK: Tab and builder

    static func tab(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Turer" : "Tours"
    }

    static func loopTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Rundtur" : "Round trip"
    }

    static func loopDetail(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fra der du står og tilbake, innom de beste stedene."
            : "From where you stand and back, past the best places."
    }

    static func destinationTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Til et sted" : "To a place"
    }

    static func destinationDetail(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Innom de beste stedene på veien, med høyst 25 % omvei."
            : "Past the best places on the way, with at most a 25 % detour."
    }

    /// A duration chip: «30 min», «1 t», «1 t 30 min».
    static func duration(minutes: Int, _ language: StoryLanguage) -> String {
        TourFormat.duration(Double(minutes) * 60, language: language)
    }

    static func durationLabel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varighet" : "Duration"
    }

    static func searchPlaceholder(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Søk etter et sted" : "Search for a place"
    }

    static func clearSearch(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Tøm søket" : "Clear search"
    }

    static func noResults(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fant ingen steder med det navnet." : "No places found by that name."
    }

    static func searchFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Søket virker ikke akkurat nå. Sjekk nettet og prøv igjen."
            : "Search isn't working right now. Check your connection and try again."
    }

    static func destinationNotFound(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fant ikke det stedet på kartet. Velg et annet." : "Couldn't find that place on the map. Pick another."
    }

    static func chosenDestination(_ name: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Mål: \(name)" : "Destination: \(name)"
    }

    static func makeTour(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lag tur" : "Make tour"
    }

    static func chooseDestinationFirst(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Velg et mål først." : "Choose a destination first."
    }

    // MARK: Progress (spec 6)

    static func locating(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner posisjonen din …" : "Finding your position …"
    }

    static func findingPlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner steder …" : "Finding places …"
    }

    static func routing(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lager rute …" : "Making the route …"
    }

    static func routingTakesTime(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gangrutene hentes én etappe om gangen; det kan ta litt tid."
            : "Walking routes come one leg at a time; this can take a while."
    }

    static func cancel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avbryt" : "Cancel"
    }

    // MARK: Failures

    static func locationDenied(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Aktiver posisjon for å lage en tur herfra." : "Turn on location to make a tour from here."
    }

    static func noPosition(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fant ikke posisjonen din ennå." : "Couldn't find your position yet."
    }

    static func placesFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fikk ikke hentet steder. Sjekk nettet og prøv igjen."
            : "Couldn't fetch places. Check your connection and try again."
    }

    static func tryAgain(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Prøv igjen" : "Try again"
    }

    static func openSettings(_ language: StoryLanguage) -> String { AroundTexts.openSettings(language) }

    // MARK: Preview (spec 5, 6)

    static func previewTitle(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Turen din" : "Your tour"
    }

    /// «Rundtur på 1 t 30 min».
    static func loopHeading(minutes: Int, _ language: StoryLanguage) -> String {
        let length = duration(minutes: minutes, language)
        return language == .norwegian ? "Rundtur på \(length)" : "Round trip of \(length)"
    }

    /// «Til Pantheon».
    static func destinationHeading(_ name: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Til \(name)" : "To \(name)"
    }

    static func newTour(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ny tur" : "New tour"
    }

    static func start(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Start turen" : "Start the tour"
    }

    static func walkDirect(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gå direkte" : "Walk there directly"
    }

    static func remove(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fjern" : "Remove"
    }

    /// VoiceOver for «Fjern»: «Fjern Pantheon».
    static func removeLabel(_ name: String, _ language: StoryLanguage) -> String {
        "\(remove(language)) \(name)"
    }

    static func approximate(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Omtrentlig rute" : "Approximate route"
    }

    static func approximateDetail(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fikk ikke hentet alle gangrutene. De stiplede strekene er rette linjer, og tidene er anslag."
            : "Some walking routes weren't available. The dashed lines are straight, and their times are estimates."
    }

    static func partialSources(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Noen kilder svarte ikke, så turen kan mangle steder."
            : "Some sources didn't answer, so the tour may miss places."
    }

    /// Spec 5's honest text: «Ingen severdigheter passer inn i 30 minutter herfra».
    static func noStopsLoop(minutes: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen severdigheter passer inn i \(minutes) minutter herfra."
            : "No sights fit into \(minutes) minutes from here."
    }

    static func tryLonger(minutes: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Prøv \(minutes) minutter" : "Try \(minutes) minutes"
    }

    static func noStopsAToB(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen severdigheter passer på veien dit innen 25 % omvei."
            : "No sights fit on the way there within a 25 % detour."
    }

    /// An A→B whose ends are under 200 m apart: «Målet er bare 150 m unna, så turen har ingen stopp.»
    static func destinationTooClose(_ distance: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Målet er bare \(distance) unna, så turen har ingen stopp."
            : "The destination is only \(distance) away, so the tour has no stops."
    }

    static func allRemoved(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Du har fjernet alle stoppene." : "You've removed every stop."
    }

    /// The walk to a stop: «12 min å gå».
    static func walkTo(_ duration: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(duration) å gå" : "\(duration) walk"
    }

    /// The last leg's row: «Tilbake til start» for a loop, «Fram til målet» for A→B.
    static func finalLeg(isLoop: Bool, _ language: StoryLanguage) -> String {
        switch (isLoop, language) {
        case (true, .norwegian): "Tilbake til start"
        case (true, .english): "Back to the start"
        case (false, .norwegian): "Fram til målet"
        case (false, .english): "On to the destination"
        }
    }

    static func stopNumber(_ number: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Stopp \(number)" : "Stop \(number)"
    }

    static func nextStop(_ language: StoryLanguage) -> String {
        language == .norwegian ? "første stopp" : "first stop"
    }

    static func startPin(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Start" : "Start"
    }

    static func destinationPin(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Mål" : "Destination"
    }

    static func mapLabel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kart over turen" : "Map of the tour"
    }
}
