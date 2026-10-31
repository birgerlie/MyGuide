import MyGuideCore

/// Every word on Settings and its sub-screens (Story timings, Buzz log, Walk log and one walk), in the language it is
/// given: the iPhone's (`UILanguage.current`, spec 17). Log content (the walk log's event lines, a buzz's kind and
/// outcome, timing numbers) stays as data.
enum SettingsTexts {
    static func title(_ language: StoryLanguage) -> String { AroundTexts.settings(language) }

    // MARK: API key

    static func keySection(_ language: StoryLanguage) -> String {
        language == .norwegian ? "OpenAI API-nøkkel" : "OpenAI API key"
    }

    static func keySaved(suffix: String?, _ language: StoryLanguage) -> String {
        let saved = language == .norwegian ? "Nøkkel lagret" : "Key saved"
        return suffix.map { "\(saved) ••••\($0)" } ?? saved
    }

    /// No key of the user's own, and App Attest works: stories go through the guide server (spec 8).
    static func guideServer(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Historiene går via MyGuide-serveren." : "Stories go through the MyGuide server."
    }

    static func noKey(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen nøkkel lagret" : "No key saved"
    }

    static func save(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lagre" : "Save"
    }

    static func removeKey(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fjern nøkkel" : "Remove key"
    }

    static func keyFooter(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lagres bare i nøkkelringen på denne iPhonen." : "Stored only in this iPhone's Keychain."
    }

    static func saveKeyFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke lagre nøkkelen" : "Couldn't save the key"): \(error)"
    }

    static func removeKeyFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke fjerne nøkkelen" : "Couldn't remove the key"): \(error)"
    }

    static func readKeychainFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke lese nøkkelringen" : "Couldn't read the Keychain"): \(error)"
    }

    // MARK: Language

    static func languageSection(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Språk" : "Language"
    }

    static func storyLanguage(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fortellingsspråk" : "Story language"
    }

    static func languageFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Gjelder nye bilder. Fortellinger som alt er fortalt, beholder språket sitt. "
                + "Skjermtekstene følger iPhonens språk."
            : "Applies to new photos. Stories already told keep their language. "
                + "Screen texts follow the iPhone's language."
    }

    // MARK: Photo stories

    static func photoStoriesSection(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fotofortellinger" : "Photo stories"
    }

    static func readAloudFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Av: ingen tale hentes; trykk Lytt for å høre fortellingen. Gjelder alle nivåer. Gåmodus har egne innstillinger."
            : "Off: no speech is fetched; tap Listen to hear the story. Applies to every level. Walking mode has its own settings."
    }

    static func prepareBackgroundPlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Forbered steder i bakgrunnen" : "Prepare places in the background"
    }

    static func prepareBackgroundPlacesFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Henter stedene rundt deg når du har flyttet deg, også med appen lukket, så kameraet svarer raskere. Krever posisjon «Alltid»."
            : "Fetches the places around you when you have moved, also with the app closed, so the camera answers faster. Needs location access Always."
    }

    // MARK: Walking

    static func walkingSection(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Gåmodus" : "Walking"
    }

    static func buzzesPerHour(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Varsler i timen: \(count)" : "Buzzes per hour: \(count)"
    }

    static func walkingFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Høyst så mange varsler i timen i gåmodus. En endring gjelder også under en tur."
            : "At most this many buzzes an hour in walking mode. A change also applies during a walk."
    }

    // MARK: Usage

    static func usageSection(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Forbruk" : "Usage"
    }

    /// "Denne måneden: $0.42 (3 forespørsler)" / "This month: $0.42 (1 request)".
    static func thisMonth(_ dollars: String, requests: Int, _ language: StoryLanguage) -> String {
        if language == .norwegian {
            return "Denne måneden: \(dollars) (\(requests) \(requests == 1 ? "forespørsel" : "forespørsler"))"
        }
        return "This month: \(dollars) (\(requests) \(requests == 1 ? "request" : "requests"))"
    }

    static func allTime(_ dollars: String, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Totalt: \(dollars)" : "All time: \(dollars)"
    }

    static func unpriced(_ language: StoryLanguage) -> String {
        language == .norwegian ? "noe av forbruket har ingen pris" : "some usage not priced"
    }

    static func usageUnavailable(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Forbruket er ikke tilgjengelig" : "Usage unavailable"
    }

    static func usageFooter(asOf: String, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Mislykkede forespørsler telles ikke. Priser per \(asOf)."
            : "Failed requests are not counted. Prices as of \(asOf)."
    }

    // MARK: Screens

    static func storyTimings(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Tidsbruk for fortellinger" : "Story timings"
    }

    static func buzzLog(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varsellogg" : "Buzz log"
    }

    static func walkLog(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Turlogg" : "Walk log"
    }

    static func deviceCheck(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Enhetssjekk" : "Device check"
    }

    static func walkingCheck(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Sjekk av gåmodus" : "Walking check"
    }

    static func delete(_ language: StoryLanguage) -> String { DiaryTexts.delete(language) }

    static func none(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen" : "None"
    }

    // MARK: Story timings

    static func noTimings(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen fotofortellinger er tidsmålt ennå." : "No photo stories timed yet."
    }

    static func list(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Liste" : "List"
    }

    static func yes(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ja" : "Yes"
    }

    static func age(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Alder" : "Age"
    }

    static func distanceFromYou(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avstand fra deg" : "Distance from you"
    }

    /// "Stedsliste i nærheten (Norsk)" / "Nearby list (English)": the list's own language in brackets.
    static func nearbyListSection(listLanguage: StoryLanguage, _ language: StoryLanguage) -> String {
        let name = listLanguage == .norwegian ? "Norsk" : "English"
        return language == .norwegian ? "Stedsliste i nærheten (\(name))" : "Nearby list (\(name))"
    }

    static func nearbyListFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Avstand fra listens midtpunkt; \u{2014} uten posisjon fra det siste minuttet."
            : "Distance from the list's centre; \u{2014} without a position from the last minute."
    }

    static func startToFirstStep(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Start til første steg" : "Start to first step"
    }

    static func startToLikelyPlace(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Start til trolig sted" : "Start to likely place"
    }

    static func placeSearch(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stedssøk" : "Place search"
    }

    static func articleText(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Artikkeltekst" : "Article text"
    }

    static func requestToFirstWords(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Forespørsel til første ord" : "Request to first words"
    }

    static func requestToCompleteStory(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Forespørsel til ferdig fortelling" : "Request to complete story"
    }

    static func speechRequest(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Taleforespørsel" : "Speech request"
    }

    static func listAge(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Listens alder" : "List age"
    }

    static func articleCharacters(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Artikkeltegn" : "Article characters"
    }

    static func freshList(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Fersk liste" : "Fresh list"
    }

    /// "3 av 12" / "3 of 12".
    static func countOf(_ count: Int, _ total: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) av \(total)" : "\(count) of \(total)"
    }

    static func medianSection(_ count: Int, _ language: StoryLanguage) -> String {
        if language == .norwegian { return "Median av \(count) \(count == 1 ? "fortelling" : "fortellinger")" }
        return "Median of \(count) \(count == 1 ? "story" : "stories")"
    }

    static func medianFooter(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Start er når fortellingen begynner, når bildet er tatt eller valgt; kameraets egen tid er ikke med. Hver median gjelder fortellingene som har verdien; antallet vises når noen mangler den. Kjøringer med \u{201C}Prøv igjen med flere steder\u{201D} registreres ikke."
            : "Start is when the story begins, once the photo is taken or picked; the camera's own time is not included. Each median is over the stories that have the value; the count is shown when some lack it. \u{201C}Try again with more places\u{201D} runs are not recorded."
    }

    static func lastSection(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "Siste \(count)" : "Last \(count)"
    }

    /// "fersk, 120 s gammel" / "not fresh, no list".
    static func listState(fresh: Bool, ageS: Int?, _ language: StoryLanguage) -> String {
        if language == .norwegian {
            let age = ageS.map { "\($0) s gammel" } ?? "ingen liste"
            return "\(fresh ? "fersk" : "ikke fersk"), \(age)"
        }
        let age = ageS.map { "\($0) s old" } ?? "no list"
        return "\(fresh ? "fresh" : "not fresh"), \(age)"
    }

    /// The labels of an entry's one-line timings: step, guess, search, article, first words, story, speech and the
    /// article length.
    struct TimingLabels {
        let step, guess, search, article, firstWords, story, speech, articleChars: String
    }

    static func timingLabels(_ language: StoryLanguage) -> TimingLabels {
        language == .norwegian
            ? TimingLabels(step: "steg", guess: "gjetning", search: "søk", article: "artikkel", firstWords: "første ord",
                           story: "fortelling", speech: "tale", articleChars: "artikkeltegn")
            : TimingLabels(step: "step", guess: "guess", search: "search", article: "article", firstWords: "first words",
                           story: "story", speech: "speech", articleChars: "article chars")
    }

    // MARK: Buzz log

    static func noBuzzes(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen varsler ennå" : "No buzzes yet"
    }

    static func byKind(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Etter type" : "By kind"
    }

    static func kindCounts(buzzes: Int, heard: Int, skipped: Int, ignored: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "\(buzzes) varsler · \(heard) hørt · \(skipped) hoppet over · \(ignored) oversett"
            : "\(buzzes) buzzes · \(heard) heard · \(skipped) skipped · \(ignored) ignored"
    }

    static func newest(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Nyeste" : "Newest"
    }

    static func newestFooter(shown: Int, of total: Int, _ language: StoryLanguage) -> String {
        language == .norwegian
            ? "De nyeste \(shown) av \(total). Eksporten har alle."
            : "The newest \(shown) of \(total). The export has them all."
    }

    static func buzzLogFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke lese eller eksportere varselloggen" : "Couldn't read or export the buzz log"): \(error)"
    }

    // MARK: Walk log

    static func noWalks(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ingen turer logget ennå" : "No walks logged yet"
    }

    /// "1 h 05 min · 1.3 km · 4 stedsvarsler".
    static func walkLine(duration: String, distance: String, buzzes: Int, _ language: StoryLanguage) -> String {
        "\(duration) · \(distance) · \(buzzes) \(language == .norwegian ? "stedsvarsler" : "place buzzes")"
    }

    static func inProgress(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Pågår" : "In progress"
    }

    static func endedWithoutStop(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Endte uten stopp" : "Ended without a stop"
    }

    static func failures(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) feil" : "\(count) failures"
    }

    static func unreadable(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Uleselig" : "Unreadable"
    }

    static func unreadableError(_ error: Error, _ language: StoryLanguage) -> String {
        "\(unreadable(language)): \(error)"
    }

    static func walkLogsFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke lese turloggene" : "Couldn't read the walk logs"): \(error)"
    }

    static func walkLogDeleteFailed(_ error: Error, _ language: StoryLanguage) -> String {
        "\(language == .norwegian ? "Kunne ikke slette turloggen" : "Couldn't delete the walk log"): \(error)"
    }

    // MARK: One walk

    static func walk(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Tur" : "Walk"
    }

    static func hideFixes(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skjul posisjonsmålinger" : "Hide fixes"
    }

    static func timeline(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Tidslinje" : "Timeline"
    }

    static func stopMarker(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stopp" : "Stop"
    }

    static func pausedMarker(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Pause" : "Paused"
    }

    static func summary(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Sammendrag" : "Summary"
    }

    static func distance(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Avstand" : "Distance"
    }

    static func duration(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varighet" : "Duration"
    }

    static func fetches(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hentinger" : "Fetches"
    }

    /// "12 (1 feilet)" / "12 (1 failed)".
    static func fetchCount(_ fetches: Int, failed: Int, _ language: StoryLanguage) -> String {
        "\(fetches) (\(failed) \(language == .norwegian ? "feilet" : "failed"))"
    }

    static func places(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Steder" : "Places"
    }

    static func buzzes(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stedsvarsler" : "Place buzzes"
    }

    /// iOS's own word for notifications; buzzes are «Stedsvarsler».
    static func notifications(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Varslinger" : "Notifications"
    }

    static func failuresLabel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Feil" : "Failures"
    }

    static func pauses(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Pauser" : "Pauses"
    }

    /// The same word in both languages.
    static func status(_ language: StoryLanguage) -> String { "Status" }

    static func unreadableLines(_ count: Int, _ language: StoryLanguage) -> String {
        language == .norwegian ? "\(count) uleselige linjer" : "\(count) unreadable lines"
    }

    static func stopReason(_ reason: WalkStopReason, _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        switch reason {
        // The automatic ones read as the auto-off notification does (`AutoOff.message`).
        case .user: return no ? "Du stoppet gåmodus." : "You stopped walking mode."
        case .timeLimit: return no ? "Gåmodus slo seg av etter 4 timer." : "Walking mode turned off after 4 hours."
        case .lowBattery:
            return no ? "Gåmodus slo seg av: batteriet er under 15 %." : "Walking mode turned off: battery below 15%."
        case .pausedTooLong:
            return no ? "Gåmodus slo seg av etter en time uten at du gikk."
                : "Walking mode turned off after an hour without walking."
        case .locationDenied:
            return no ? "Gåmodus stoppet: ingen tilgang til posisjon." : "Walking mode stopped: location access denied."
        }
    }
}
