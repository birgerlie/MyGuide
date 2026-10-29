import Foundation

/// Coarse reason a story could not be fetched; picks the one-line text in the failure notification.
public enum FailureCategory: Sendable, Equatable {
    case noNetwork, aiFailed, noKey, timedOut, other

    public init(_ error: Error) {
        if let e = error as? OpenAIError {
            switch e {
            case .network: self = .noNetwork
            case .missingAPIKey, .invalidAPIKey: self = .noKey
            default: self = .aiFailed
            }
        } else if let e = error as? URLError {
            switch e.code {
            // Mobile data off for the app, roaming off abroad, no route to the host, DNS or TLS failing on a captive
            // portal: all read to the owner as "no connection".
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                self = .noNetwork
            case .timedOut: self = .timedOut
            default: self = .other
            }
        } else {
            self = .other
        }
    }

    public func text(_ language: StoryLanguage) -> String {
        let nb = language == .norwegian
        switch self {
        case .noNetwork: return nb ? "Ingen nettilgang." : "No connection."
        case .aiFailed: return nb ? "AI-tjenesten feilet. Prøv igjen." : "The AI service failed. Try again."
        case .noKey: return nb ? "Mangler API-nøkkel. Legg den inn i Innstillinger." : "No API key. Add it in Settings."
        case .timedOut: return nb ? "Det tok for lang tid. Prøv igjen." : "It took too long. Try again."
        case .other: return nb ? "Noe gikk galt. Prøv igjen." : "Something went wrong. Try again."
        }
    }
}
