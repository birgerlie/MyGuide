import SwiftUI

@main
struct MyGuideWatchApp: App {
    @State private var check = WatchCheckModel()

    var body: some Scene {
        WindowGroup {
            WatchCheckView(model: check)
        }
    }
}
