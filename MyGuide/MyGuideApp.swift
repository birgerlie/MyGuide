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

    init() {
        let container: ModelContainer
        var persistent = true
        do {
            container = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                           migrationPlan: MemoryMigrationPlan.self)
        } catch {
            // Stories still work without a store; they just won't be remembered this run.
            AppServices.logMemoryFailure("persistent store unavailable, using in-memory", error)
            persistent = false
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // An in-memory store failing means the schema itself is broken: a programmer error.
            container = try! ModelContainer(for: Schema(versionedSchema: MemorySchemaV3.self),
                                            migrationPlan: MemoryMigrationPlan.self, configurations: config)
        }
        self.container = container
        let services = AppServices(memory: MemoryStore(context: container.mainContext),
                                   memoryIsPersistent: persistent)
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
        Task { await BuzzNotifier.registerCategories() }
        services.walking.endLeftoverActivities()
    }

    var body: some Scene {
        WindowGroup {
            HomeScreen(services: services)
            // Foreground and background during a walk go into the walk log.
            .onChange(of: scenePhase) { services.walking.noteScenePhase($1) }
            // myguide://walk/<id>, from the Live Activity: open that walk story.
            .onOpenURL { url in
                if let id = WalkLink.storyID(from: url) { services.walking.stories.open(id) }
            }
        }
        .modelContainer(container)
    }
}
