import Foundation
import Testing
@testable import MyGuideCore

@Suite struct FailureCategoryTests {
    @Test func failureMapping() {
        #expect(FailureCategory(OpenAIError.network("x")) == .noNetwork)
        #expect(FailureCategory(URLError(.notConnectedToInternet)) == .noNetwork)
        #expect(FailureCategory(URLError(.networkConnectionLost)) == .noNetwork)
        #expect(FailureCategory(URLError(.cannotFindHost)) == .noNetwork)
        #expect(FailureCategory(URLError(.dataNotAllowed)) == .noNetwork)
        #expect(FailureCategory(URLError(.internationalRoamingOff)) == .noNetwork)
        #expect(FailureCategory(URLError(.cannotConnectToHost)) == .noNetwork)
        #expect(FailureCategory(URLError(.dnsLookupFailed)) == .noNetwork)
        #expect(FailureCategory(URLError(.secureConnectionFailed)) == .noNetwork)
        #expect(FailureCategory(URLError(.timedOut)) == .timedOut)
        #expect(FailureCategory(OpenAIError.missingAPIKey) == .noKey)
        #expect(FailureCategory(OpenAIError.invalidAPIKey) == .noKey)
        #expect(FailureCategory(OpenAIError.quotaExceeded) == .aiFailed)
        #expect(FailureCategory(OpenAIError.rateLimited("x")) == .aiFailed)
        #expect(FailureCategory(OpenAIError.server(500)) == .aiFailed)
        #expect(FailureCategory(OpenAIError.refused("x")) == .aiFailed)
        #expect(FailureCategory(OpenAIError.malformedResponse) == .aiFailed)
        #expect(FailureCategory(OpenAIError.modelRetired) == .aiFailed)
        #expect(FailureCategory(OpenAIError.contentBlocked) == .aiFailed)
        // other URL errors and foreign errors are .other
        #expect(FailureCategory(URLError(.badURL)) == .other)
        #expect(FailureCategory(URLError(.badServerResponse)) == .other)
        #expect(FailureCategory(URLError(.serverCertificateUntrusted)) == .other)
        #expect(FailureCategory(CancellationError()) == .other)
        #expect(FailureCategory(GroundingFetchError.malformed) == .other)
    }

    @Test func failureTextsBothLanguages() {
        let table: [(FailureCategory, String, String)] = [
            (.noNetwork, "Ingen nettilgang.", "No connection."),
            (.aiFailed, "AI-tjenesten feilet. Prøv igjen.", "The AI service failed. Try again."),
            (.noKey, "Mangler API-nøkkel. Legg den inn i Innstillinger.", "No API key. Add it in Settings."),
            (.timedOut, "Det tok for lang tid. Prøv igjen.", "It took too long. Try again."),
            (.other, "Noe gikk galt. Prøv igjen.", "Something went wrong. Try again."),
        ]
        for (cat, nb, en) in table {
            #expect(cat.text(.norwegian) == nb)
            #expect(cat.text(.english) == en)
        }
    }
}
