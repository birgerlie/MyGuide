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
        (PhotoStoryError.noPosition, "This photo has no location. Use where you are now?"),
        (ImageProcessingError.unreadableImage, "Couldn't read this photo."),
        (CancellationError(), ""),
    ])
    func messages(error: Error, expected: String) { #expect(UserFacingMessage.message(for: error) == expected) }

    @Test func unknownErrorFallsBackToDescription() {
        struct Odd: LocalizedError { var errorDescription: String? { "odd thing" } }
        #expect(UserFacingMessage.message(for: Odd()) == "Something went wrong: odd thing")
    }
}
