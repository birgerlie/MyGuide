import MyGuideCore
import os
import SwiftData
import SwiftUI

@main
struct MyGuideApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let container: ModelContainer
    @State private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    /// A fixed id for the debug check of the walk story link at launch.
    private static let linkProbe = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    init() {
        // Before any screen or background work reads the setting: the first launch stores its default once.
        AppServices.settleStoryLanguage()
        let container: ModelContainer
        var fallback: MemoryFallback?
        do {
            container = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                           migrationPlan: MemoryMigrationPlan.self)
        } catch {
            // Stories still work without a store; they just won't be remembered this run.
            AppServices.logMemoryFailure("persistent store unavailable, using in-memory", error)
            // A location wake can launch the app before the phone's first unlock, when the store file is still
            // protected. The store is not reopened later in this process; the banner asks the owner to relaunch.
            let reason = MemoryFallback.reason(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
            if reason == .lockedAtBackgroundLaunch {
                AppServices.memoryLog.error("persistent store unavailable: protected data unavailable at launch (launched in the background before first unlock)")
            }
            fallback = reason
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // An in-memory store failing means the schema itself is broken: a programmer error.
            container = try! ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                            migrationPlan: MemoryMigrationPlan.self, configurations: config)
        }
        self.container = container
        let services = AppServices(memory: MemoryStore(context: container.mainContext), memoryFallback: fallback)
        _services = State(initialValue: services)
        // Set before the app finishes launching, so an action that cold-launches the app is not dropped.
        AppDelegate.responseHandler = { response in
            // The Walking check owns category CHECK; walking mode owns BUZZ, MORE, STORY_FAILED and STOP.
            switch response.notification.request.content.categoryIdentifier {
            case WalkingCheckModel.category: services.walkingCheck.handle(response)
            case BuzzNotifier.category, BuzzNotifier.moreCategory, BuzzNotifier.failedCategory,
                BuzzNotifier.stopCategory:
                services.walking.handle(response)
            default: break
            }
        }
        Theme.Font.verifyBundled()
        // The widget's copy of the walk story link must keep `WalkLink`'s format; checked in debug builds only.
        assert(WalkingActivityAttributes.storyURL(Self.linkProbe) == WalkLink.url(for: Self.linkProbe),
               "WalkingActivityAttributes.storyURL drifted from WalkLink.url(for:)")
        // The action titles are in the iPhone's language, fixed for the process: registered once, here.
        Task { await BuzzNotifier.registerCategories() }
        services.walking.endLeftoverActivities()
    }

    var body: some Scene {
        WindowGroup {
            HomeScreen(services: services)
            .tint(Theme.Colour.accent)
            .background(Theme.Colour.background.ignoresSafeArea())
            // Foreground and background during a walk go into the walk log.
            .onChange(of: scenePhase) {
                services.walking.noteScenePhase($1)
                if $1 == .active { services.noteBecameActive() }
            }
            // myguide://walk/<id>, from the Live Activity: open that walk story.
            .onOpenURL { url in
                if let id = WalkLink.storyID(from: url) { services.walking.stories.open(id) }
            }
        }
        .modelContainer(container)
    }
}
