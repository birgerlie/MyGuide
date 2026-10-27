import Foundation

/// Plain-language text for errors shown to the user.
public enum UserFacingMessage {
    /// Returns "" for `CancellationError`: the UI must treat cancellation as silence, never show it as an error.
    public static func message(for error: Error) -> String {
        if error is CancellationError { return "" }
        switch error {
        case let e as OpenAIError:
            switch e {
            case .missingAPIKey: return "Add your OpenAI API key in Settings first."
            case .invalidAPIKey: return "OpenAI rejected the API key. Check it in Settings."
            case .quotaExceeded: return "Your OpenAI account is out of credit or over its limit."
            case .rateLimited: return "OpenAI is busy right now. Try again in a moment."
            case .server(403): return "OpenAI denied access. Check that your API key's project can use this model."
            case .server(let code): return "OpenAI had a problem (error \(code)). Try again."
            case .network: return "No connection. Check mobile data and try again."
            case .refused, .malformedResponse: return "Couldn't tell a story about this photo."
            case .modelRetired: return "This app's AI model has been retired — update the app."
            // Worded for images, but it reads correctly for a blocked story too.
            case .contentBlocked: return "OpenAI wouldn't make this image."
            }
        case let e as PhotoStoryError:
            switch e {
            case .noPosition: return "This photo has no location. Use where you are now?"
            case .noFurtherLevel: return "That's the whole story for this place."
            }
        case let e as ImageProcessingError:
            switch e {
            case .unreadableImage, .encodeFailed: return "Couldn't read this photo."
            }
        default:
            return "Something went wrong: \(error.localizedDescription)"
        }
    }
}
