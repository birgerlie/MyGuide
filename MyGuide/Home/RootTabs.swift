import MyGuideCore
import SwiftUI

/// The app's two tabs (spec 14). «Turer» comes with the tour modes; a dead tab is worse than none.
enum RootTab: Hashable {
    /// The «Rundt deg» map, the camera and the stories opened from them.
    case explore
    /// The diary, with History and Settings reached from its top bar.
    case diary
}

/// The tab bar: «Utforsk» (map symbol) and «Dagbok» (book symbol), named in the iPhone's language. The tabs'
/// contents and their navigation stacks belong to `HomeScreen`, which owns the shared location provider for both.
struct RootTabs<Explore: View, Diary: View>: View {
    @Binding var selection: RootTab
    let language: StoryLanguage
    @ViewBuilder let explore: () -> Explore
    @ViewBuilder let diary: () -> Diary

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: RootTab.explore) {
                explore()
            } label: {
                Label(AroundTexts.exploreTab(language), systemImage: "map")
            }
            Tab(value: RootTab.diary) {
                diary()
            } label: {
                Label(AroundTexts.diaryTab(language), systemImage: "book.closed")
            }
        }
        .tint(Theme.Colour.accent)
    }
}
