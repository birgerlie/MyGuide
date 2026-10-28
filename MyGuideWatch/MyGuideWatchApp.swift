import SwiftUI

@main
struct MyGuideWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GuidedWalkView(model: delegate.walk, check: delegate.check)
        }
        .onChange(of: scenePhase) { _, phase in
            // The application context brings the newest state whenever the app becomes active (spec 6.3).
            if phase == .active { PhoneLink.shared.deliverReceivedContext() }
        }
    }
}
