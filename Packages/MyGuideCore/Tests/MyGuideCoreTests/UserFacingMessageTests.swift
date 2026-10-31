import Foundation
import Testing
@testable import MyGuideCore

@Suite struct UserFacingMessageTests {
    @Test(arguments: [
        (OpenAIError.missingAPIKey as Error, "Add your OpenAI API key in Settings first."),
        (OpenAIError.invalidAPIKey, "OpenAI rejected the API key. Check it in Settings."),
        (OpenAIError.quotaExceeded, "Your OpenAI account is out of credit or over its limit."),
        (OpenAIError.rateLimited("x"), "OpenAI is busy right now. Try again in a moment."),
        (OpenAIError.server(503), "OpenAI had a problem (error 503). Try again."),
        (OpenAIError.server(403), "OpenAI denied access. Check that your API key's project can use this model."),
        (OpenAIError.network("offline"), "No connection. Check mobile data and try again."),
        (OpenAIError.refused("no"), "Couldn't tell a story about this photo."),
        (OpenAIError.malformedResponse, "Couldn't tell a story about this photo."),
        (OpenAIError.modelRetired, "This app's AI model has been retired — update the app."),
        (OpenAIError.contentBlocked, "OpenAI wouldn't make this image."),
        (OpenAIError.dailyQuota, "Today's free stories are used up. Try again tomorrow."),
        (OpenAIError.serverBudget, "The guide is taking a break right now. Try again later."),
        (OpenAIError.attestUnavailable, "Add your own OpenAI API key in Settings."),
        (PhotoStoryError.noPosition, "This photo has no location. Use where you are now?"),
        (ImageProcessingError.unreadableImage, "Couldn't read this photo."),
        (PhotoStoryError.noFurtherLevel, "That's the whole story for this place."),
        (ImageProcessingError.encodeFailed, "Couldn't read this photo."),
        (DayStoryError.noPhotos, "None of this day's photos could be read."),
        (CancellationError(), ""),
    ])
    func messages(error: Error, expected: String) { #expect(UserFacingMessage.message(for: error) == expected) }

    @Test func unknownErrorFallsBackToDescription() {
        struct Odd: LocalizedError { var errorDescription: String? { "odd thing" } }
        #expect(UserFacingMessage.message(for: Odd()) == "Something went wrong: odd thing")
    }

    @Test(arguments: [
        (OpenAIError.missingAPIKey as Error, "Legg inn OpenAI-nøkkelen din i Innstillinger først."),
        (OpenAIError.invalidAPIKey, "OpenAI avviste API-nøkkelen. Sjekk den i Innstillinger."),
        (OpenAIError.quotaExceeded, "OpenAI-kontoen din er tom for kreditt eller over grensen."),
        (OpenAIError.rateLimited("x"), "OpenAI er opptatt akkurat nå. Prøv igjen om litt."),
        (OpenAIError.server(503), "OpenAI hadde et problem (feil 503). Prøv igjen."),
        (OpenAIError.server(403), "OpenAI nektet tilgang. Sjekk at prosjektet til API-nøkkelen kan bruke denne modellen."),
        (OpenAIError.network("offline"), "Ingen forbindelse. Sjekk mobildata og prøv igjen."),
        (OpenAIError.refused("no"), "Kunne ikke fortelle om dette bildet."),
        (OpenAIError.malformedResponse, "Kunne ikke fortelle om dette bildet."),
        (OpenAIError.modelRetired, "AI-modellen i denne appen er tatt ut av bruk – oppdater appen."),
        (OpenAIError.contentBlocked, "OpenAI ville ikke lage dette bildet."),
        (OpenAIError.dailyQuota, "Dagens gratis historier er brukt opp. Prøv igjen i morgen."),
        (OpenAIError.serverBudget, "Guiden tar en pause akkurat nå. Prøv igjen senere."),
        (OpenAIError.attestUnavailable, "Legg inn en egen OpenAI-nøkkel i Innstillinger."),
        (PhotoStoryError.noPosition, "Dette bildet har ingen posisjon. Bruke der du er nå?"),
        (PhotoStoryError.noFurtherLevel, "Det er hele fortellingen om dette stedet."),
        (ImageProcessingError.unreadableImage, "Kunne ikke lese dette bildet."),
        (ImageProcessingError.encodeFailed, "Kunne ikke lese dette bildet."),
        (DayStoryError.noPhotos, "Ingen av dagens bilder kunne leses."),
        (CancellationError(), ""),
    ])
    func norwegianMessages(error: Error, expected: String) {
        #expect(UserFacingMessage.message(for: error, language: .norwegian) == expected)
    }

    /// The English overload and `language: .english` are the same text for every kind of error.
    @Test(arguments: [
        OpenAIError.missingAPIKey as Error, OpenAIError.server(500), PhotoStoryError.noPosition,
        DayStoryError.noPhotos, ImageProcessingError.unreadableImage, CancellationError(),
    ])
    func englishIsTheDefault(error: Error) {
        #expect(UserFacingMessage.message(for: error, language: .english) == UserFacingMessage.message(for: error))
    }

    @Test func unknownErrorFallsBackToDescriptionInNorwegian() {
        struct Odd: LocalizedError { var errorDescription: String? { "odd thing" } }
        #expect(UserFacingMessage.message(for: Odd(), language: .norwegian) == "Noe gikk galt: odd thing")
    }
}
