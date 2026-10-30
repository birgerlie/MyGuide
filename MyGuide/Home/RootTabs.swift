import MyGuideCore
import SwiftUI

/// The app's tabs (spec 14, amended 2026-10-30; «Turer» holds the free walk and the tours spec 6's tours).
enum RootTab: Hashable {
    /// The «Rundt deg» map and the stories opened from it.
    case explore
    /// Never selected: tapping it opens the camera on the Utforsk stack.
    case camera
    /// «Turer» / «Walks»: a free walk, or planning a tour (a loop or A→B) and its preview.
    case tours
    /// The diary, with History and Settings reached from its top bar.
    case diary

    /// Whether the system can show and hide a line over the tab bar (`tabViewBottomAccessory(isEnabled:)`, iOS 26.1).
    /// Without it, the walking line sits in the «Rundt deg» sheet instead.
    static var hasAccessory: Bool {
        if #available(iOS 26.1, *) { true } else { false }
    }
}

/// The tab bar: «Utforsk» (map symbol), «Kamera» (camera symbol), «Turer» / «Walks» (a walking figure, with motion
/// lines while `accessoryEnabled`, i.e. a walk or a tour runs) and «Dagbok» (book symbol), named in the iPhone's
/// language, with the walking line over it while `accessoryEnabled` (iOS 26.1 and later; see
/// `RootTab.hasAccessory`). «Kamera» is an action, not a place: tapping it calls `openCamera` and leaves the selection
/// as it was, so the tab is never shown as selected. The tabs' contents and their navigation stacks belong to `HomeScreen`,
/// which owns the shared location provider for all of them.
struct RootTabs<Explore: View, Tours: View, Diary: View, Accessory: View>: View {
    @Binding var selection: RootTab
    let language: StoryLanguage
    let openCamera: () -> Void
    let accessoryEnabled: Bool
    @ViewBuilder let explore: () -> Explore
    @ViewBuilder let tours: () -> Tours
    @ViewBuilder let diary: () -> Diary
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: accessoryEnabled) { accessory() }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(value: RootTab.explore) {
                explore()
            } label: {
                Label(AroundTexts.exploreTab(language), systemImage: "map")
            }
            Tab(value: RootTab.camera) {
                // Never shown: the selection never becomes `.camera`.
                Theme.Colour.background.ignoresSafeArea()
            } label: {
                Label(AroundTexts.cameraTab(language), systemImage: "camera")
            }
            .accessibilityLabel(AroundTexts.cameraLabel(language))
            Tab(value: RootTab.tours) {
                tours()
            } label: {
                Label(ToursTexts.tab(language), systemImage: accessoryEnabled ? "figure.walk.motion" : "figure.walk")
            }
            Tab(value: RootTab.diary) {
                diary()
            } label: {
                Label(AroundTexts.diaryTab(language), systemImage: "book.closed")
            }
        }
        .tint(Theme.Colour.accent)
    }

    /// The selection as the tab bar sees it: «Kamera» opens the camera instead of being selected.
    private var tabSelection: Binding<RootTab> {
        Binding(get: { selection }, set: { tab in
            if tab == .camera { openCamera() } else { selection = tab }
        })
    }
}
