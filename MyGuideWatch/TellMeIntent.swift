import AppIntents

/// Bound to the Action button through a Shortcut: asks the phone to tell the story now.
struct TellMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell me"
    static let description = IntentDescription("Asks MyGuide on your phone to tell you about what is around you.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Task 15 changes this to "walk.tell".
        try await PhoneLink.shared.tell(["type": "check.tell"])
        return .result()
    }
}
