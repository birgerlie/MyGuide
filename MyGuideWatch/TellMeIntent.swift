import AppIntents
import MyGuideCore

/// Bound to the Action button through a Shortcut. It sends `check.tell`, which today drives the phone's Walking check
/// tone, not a story.
struct TellMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell me"
    static let description = IntentDescription("Asks MyGuide on your phone to tell you about what is around you.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // The phone plays the Walking check's test tone (`WalkingCheckModel.handleWatchTell`) and tells no story,
        // whatever the title says. Pointing it at a walk story is the owner's decision.
        try await PhoneLink.shared.tell(["type": WatchMessage.checkTell])
        return .result()
    }
}
