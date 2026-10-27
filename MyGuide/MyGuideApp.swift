import MyGuideCore
import os
import SwiftData
import SwiftUI

@main
struct MyGuideApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let container: ModelContainer
    @State private var services: AppServices

    init() {
        let container: ModelContainer
        var persistent = true
        do {
            container = try ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self),
                                           migrationPlan: MemoryMigrationPlan.self)
        } catch {
            // Stories still work without a store; they just won't be remembered this run.
            AppServices.logMemoryFailure("persistent store unavailable, using in-memory", error)
            persistent = false
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // An in-memory store failing means the schema itself is broken: a programmer error.
            container = try! ModelContainer(for: Schema(versionedSchema: MemorySchemaV2.self),
                                            migrationPlan: MemoryMigrationPlan.self, configurations: config)
        }
        self.container = container
        let services = AppServices(memory: MemoryStore(context: container.mainContext),
                                   memoryIsPersistent: persistent)
        _services = State(initialValue: services)
        // Set before the app finishes launching, so an action that cold-launches the app is not dropped.
        AppDelegate.responseHandler = { response in
            // The Walking check owns category CHECK; later walking categories are handled alongside it.
            if response.notification.request.content.categoryIdentifier == WalkingCheckModel.category {
                services.walkingCheck.handle(response)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CaptureScreen(services: services)
            }
        }
        .modelContainer(container)
    }
}
