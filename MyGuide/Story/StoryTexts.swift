import Foundation
import MyGuideCore

/// The camera and story screens' texts, in the language they are given: the iPhone's (`UILanguage.current`, spec 17).
enum ScreenText {
    static func lookingAt(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Hva ser du på?" : "What are you looking at?"
    }

    static func findPlace(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finn stedet" : "Find the place"
    }

    static func finding(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Finner stedet …" : "Finding the place …"
    }

    static func writing(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Skriver fortellingen …" : "Writing the story …"
    }

    static func notSure(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Jeg er ikke sikker på hvilket sted dette er." : "I'm not sure which place this is."
    }

    static func morePlaces(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Prøv igjen med flere steder" : "Try again with more places"
    }

    static func listen(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lytt" : "Listen"
    }

    static func stop(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Stopp" : "Stop"
    }

    static func readAloud(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Les opp automatisk" : "Read aloud automatically"
    }

    /// "Kanskje: Pantheon · 120 m mot nordøst" / "Maybe: Pantheon · 120 m north-east"; without a position, the name.
    static func maybe(_ card: PlaceCard, _ language: StoryLanguage) -> String {
        let prefix = language == .norwegian ? "Kanskje" : "Maybe"
        guard let where_ = distanceAndDirection(card, language) else { return "\(prefix): \(card.name)" }
        return "\(prefix): \(card.name) · \(where_)"
    }

    /// "120 m mot nordøst" / "120 m north-east" (distance rounded as walking mode does); nil without a position.
    static func distanceAndDirection(_ card: PlaceCard, _ language: StoryLanguage) -> String? {
        guard let distance = card.distance, let bearing = card.bearing else { return nil }
        return "\(BuzzText.roundedDistance(distance)) m \(direction(bearing, language))"
    }

    /// The compass point of the bearing (a guess is always ahead, so the side would say nothing), in Norwegian as
    /// "mot …". A bearing that is not finite counts as north.
    static func direction(_ bearing: Double, _ language: StoryLanguage) -> String {
        let point = CompassPoint(degrees: bearing)
        return language == .norwegian ? "mot \(point.words(.norwegian))" : point.words(.english)
    }

    // MARK: Story screen

    /// The status over the place name. Only a "certain" identification says "found"; a streaming identification
    /// (confidence not passed) and "likely" say "likely", and the list's guess says "maybe".
    static func statusLabel(_ mark: PlaceCard.Mark, confidence: SubjectConfidence?,
                            _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        switch mark {
        case .guess: return no ? "Kanskje" : "Maybe"
        case .unsure: return unsureLabel(language)
        case .identified:
            if confidence == .certain { return no ? "Sted funnet" : "Place found" }
            return no ? "Trolig sted" : "Likely place"
        }
    }

    static func unsureLabel(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Usikkert sted" : "Uncertain place"
    }

    /// "Roma, Italia · 120 m mot nordøst": the address's city and country, then distance and direction; either part
    /// alone; nil with neither.
    static func whereLine(_ card: PlaceCard, address: Address?, _ language: StoryLanguage) -> String? {
        let parts = [PlaceLocationLine.text(address), distanceAndDirection(card, language)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func shortStory(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kort fortelling" : "Short story"
    }

    /// The label over a deeper level: index 1 is "Mer", index 2 "Enda mer".
    static func moreLabel(_ index: Int, _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        return index <= 1 ? (no ? "Mer" : "More") : (no ? "Enda mer" : "Even more")
    }

    /// "Mer om Pantheon" / "Enda mer om Pantheon"; without a name (not sure), "Fortell mer" / "Fortell enda mer".
    static func more(_ level: StoryLevel, name: String?, _ language: StoryLanguage) -> String {
        let no = language == .norwegian
        let even = level == .evenMore
        if let name, !name.isEmpty {
            return no ? (even ? "Enda mer om \(name)" : "Mer om \(name)")
                : (even ? "Even more about \(name)" : "More about \(name)")
        }
        return no ? (even ? "Fortell enda mer" : "Fortell mer") : (even ? "Tell me even more" : "Tell me more")
    }

    static func sources(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kilder" : "Sources"
    }

    static func listenToStory(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lytt til fortellingen" : "Listen to the story"
    }

    static func savedInDiary(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Lagret i dagboken" : "Saved in your diary"
    }

    static func saveFailed(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke lagre i dagboken" : "Couldn't save to your diary"
    }

    static func couldNotPlay(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Kunne ikke spille av lyden" : "Couldn't play audio"
    }

    /// A failure with no words of its own (a cancellation nobody asked for, or background time running out).
    static func somethingWentWrong(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Noe gikk galt. Prøv igjen." : "Something went wrong. Try again."
    }

    static func retry(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Prøv igjen" : "Retry"
    }

    static func showThen(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Vis hvordan det så ut" : "Show me how it looked"
    }

    static func useWhereIAm(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Bruk der jeg er nå" : "Use where I am now"
    }

    static func waitingForGPS(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Venter på GPS …" : "Waiting for a GPS fix…"
    }

    static func noPlaceSources(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Ingen stedskilder. Fortellingen bygger bare på bildet og posisjonen."
            : "No place sources. The story is based only on the photo and the position."
    }

    static func aiNote(_ language: StoryLanguage) -> String {
        language == .norwegian
            ? "Fortellingen er skrevet av en AI-modell (OpenAI) ut fra bildet, posisjonen og kildene over. Den kan ta feil."
            : "The story is written by an AI model (OpenAI) from the photo, the position and the sources above. It can be wrong."
    }

    static func done(_ language: StoryLanguage) -> String {
        language == .norwegian ? "Ferdig" : "Done"
    }

    static func sourceName(_ kind: StorySource.Kind, _ language: StoryLanguage) -> String {
        switch kind {
        case .wikipedia: "Wikipedia"
        case .openStreetMap: "OpenStreetMap"
        case .wikidata: "Wikidata"
        case .imageCredit: language == .norwegian ? "Bilde" : "Photo"
        case .appleMaps: language == .norwegian ? "Apple Kart (adresse og steder)" : "Apple Maps (address and places)"
        }
    }
}
