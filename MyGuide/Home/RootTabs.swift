import MyGuideCore
import SwiftUI

/// The app's three tabs (spec 14; «Turer» from the tours spec 6).
enum RootTab: Hashable {
    /// The «Rundt deg» map, the camera and the stories opened from them.
    case explore
    /// Planning a tour: a loop or A→B, and its preview.
    case tours
    /// The diary, with History and Settings reached from its top bar.
    case diary
}

/// The tab bar: «Utforsk» (map symbol), «Turer» (walking figure) and «Dagbok» (book symbol), named in the iPhone's
/// language. The tabs' contents and their navigation stacks belong to `HomeScreen`, which owns the shared location
/// provider for all of them.
struct RootTabs<Explore: View, Tours: View, Diary: View>: View {
    @Binding var selection: RootTab
    let language: StoryLanguage
    @ViewBuilder let explore: () -> Explore
    @ViewBuilder let tours: () -> Tours
    @ViewBuilder let diary: () -> Diary

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: RootTab.explore) {
                explore()
            } label: {
                Label(AroundTexts.exploreTab(language), systemImage: "map")
            }
            Tab(value: RootTab.tours) {
                tours()
            } label: {
                Label(ToursTexts.tab(language), systemImage: "figure.walk.motion")
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
