import SwiftUI

@main
struct MyGuideApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CaptureScreen(services: services)
            }
        }
    }
}
