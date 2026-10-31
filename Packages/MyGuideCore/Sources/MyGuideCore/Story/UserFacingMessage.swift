import Foundation

/// Plain-language text for errors shown to the user.
public enum UserFacingMessage {
    /// The message in English. Returns "" for `CancellationError`: the UI must treat cancellation as silence, never
    /// show it as an error.
    public static func message(for error: Error) -> String {
        message(for: error, language: .english)
    }

    /// The message in `language` (the story language, spec 15). Returns "" for `CancellationError`.
    public static func message(for error: Error, language: StoryLanguage) -> String {
        if error is CancellationError { return "" }
        let no = language == .norwegian
        switch error {
        case let e as OpenAIError:
            switch e {
            case .missingAPIKey:
                return no ? "Legg inn OpenAI-nøkkelen din i Innstillinger først." : "Add your OpenAI API key in Settings first."
            case .invalidAPIKey:
                return no ? "OpenAI avviste API-nøkkelen. Sjekk den i Innstillinger."
                    : "OpenAI rejected the API key. Check it in Settings."
            case .quotaExceeded:
                return no ? "OpenAI-kontoen din er tom for kreditt eller over grensen."
                    : "Your OpenAI account is out of credit or over its limit."
            case .rateLimited:
                return no ? "OpenAI er opptatt akkurat nå. Prøv igjen om litt."
                    : "OpenAI is busy right now. Try again in a moment."
            case .server(403):
                return no ? "OpenAI nektet tilgang. Sjekk at prosjektet til API-nøkkelen kan bruke denne modellen."
                    : "OpenAI denied access. Check that your API key's project can use this model."
            case .server(let code):
                return no ? "OpenAI hadde et problem (feil \(code)). Prøv igjen."
                    : "OpenAI had a problem (error \(code)). Try again."
            case .network:
                return no ? "Ingen forbindelse. Sjekk mobildata og prøv igjen."
                    : "No connection. Check mobile data and try again."
            case .refused, .malformedResponse:
                return no ? "Kunne ikke fortelle om dette bildet." : "Couldn't tell a story about this photo."
            case .modelRetired:
                return no ? "AI-modellen i denne appen er tatt ut av bruk – oppdater appen."
                    : "This app's AI model has been retired — update the app."
            // Worded for images, but it reads correctly for a blocked story too.
            case .contentBlocked:
                return no ? "OpenAI ville ikke lage dette bildet." : "OpenAI wouldn't make this image."
            case .dailyQuota:
                return no ? "Dagens gratis historier er brukt opp. Prøv igjen i morgen."
                    : "Today's free stories are used up. Try again tomorrow."
            case .serverBudget:
                return no ? "Guiden tar en pause akkurat nå. Prøv igjen senere."
                    : "The guide is taking a break right now. Try again later."
            case .attestUnavailable:
                return no ? "Legg inn en egen OpenAI-nøkkel i Innstillinger."
                    : "Add your own OpenAI API key in Settings."
            }
        case let e as PhotoStoryError:
            switch e {
            case .noPosition:
                return no ? "Dette bildet har ingen posisjon. Bruke der du er nå?"
                    : "This photo has no location. Use where you are now?"
            case .noFurtherLevel:
                return no ? "Det er hele fortellingen om dette stedet." : "That's the whole story for this place."
            }
        case let e as DayStoryError:
            switch e {
            case .noPhotos:
                return no ? "Ingen av dagens bilder kunne leses." : "None of this day's photos could be read."
            }
        case let e as ImageProcessingError:
            switch e {
            case .unreadableImage, .encodeFailed:
                return no ? "Kunne ikke lese dette bildet." : "Couldn't read this photo."
            }
        default:
            return "\(no ? "Noe gikk galt" : "Something went wrong"): \(error.localizedDescription)"
        }
    }
}
