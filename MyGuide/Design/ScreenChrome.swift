import SwiftUI

// The design package on the app's list and form screens (spec 15): the diary, History, Settings and its sub-screens,
// and the checks. The theme background and text colour in light and dark mode, Inter for the interface, the screen
// title in Playfair, section labels in spaced capitals (`SectionLabel`, as on the story screen) and stone dividers.
// Developer screens keep their dense layouts; they only take these colours and fonts.

/// The list screens' own design values.
enum ScreenChrome {
    /// A list row's surface: a faint veil of the text colour over the background, so rows read as a secondary surface
    /// on ivory and on forest green alike.
    static let rowFill = Theme.Colour.text.opacity(0.06)
    /// A switch that is on: coral (a marking, design package) in both appearances. The theme accent would be ivory in
    /// dark mode, where the white knob all but vanishes on it; the knob's position still says on or off.
    static let toggleTint = Theme.Colour.coral
    /// The screen title in the navigation bar.
    static let titleFont = Font.custom(Theme.FontName.display, size: 20, relativeTo: .headline)
}

extension View {
    /// The screen's title in Playfair, centred in the navigation bar. `navigationTitle` is kept for the back button
    /// of the next screen and the app switcher.
    func themedTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(ScreenChrome.titleFont)
                        .foregroundStyle(Theme.Colour.text)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }

    /// A `List` or `Form` on the theme background, with Inter and the theme's text colour for everything in it.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.Colour.background.ignoresSafeArea())
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Colour.text)
            .tint(Theme.Colour.accent)
    }

    /// The rows of a section (apply to the `Section` or the `ForEach`): the row surface and stone dividers.
    func themedRows() -> some View {
        listRowBackground(ScreenChrome.rowFill)
            .listRowSeparatorTint(Theme.Colour.stone)
    }
}

/// A list section's header: the story screen's spaced capitals, in the theme's text colour (a grouped list would
/// otherwise grey it).
struct ListSectionHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        SectionLabel(text)
            .foregroundStyle(Theme.Colour.text)
    }
}

/// A list section's footer in the caption size.
struct ListSectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Colour.text)
            .opacity(0.75)
    }
}

/// An empty screen: the symbol, a short Playfair heading and a line of Inter under it.
struct ThemedEmptyState: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
                    .font(Theme.Font.title)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            Text(description)
                .font(Theme.Font.body)
        }
        .foregroundStyle(Theme.Colour.text)
        .background(Theme.Colour.background.ignoresSafeArea())
    }
}

/// A check's result as a symbol with its word for VoiceOver, never colour alone (spec 15): a check mark when passed,
/// a cross in red when failed, and an ellipsis while it waits.
struct CheckMark: View {
    let passed: Bool?
    let passedText: String
    let failedText: String
    let waitingText: String

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.Font.bodyMedium)
            .foregroundStyle(passed == false ? Color.red : Theme.Colour.text)
            .opacity(passed == nil ? 0.6 : 1)
            .frame(width: 24)
            .accessibilityLabel(word)
    }

    private var symbol: String {
        switch passed {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.octagon.fill"
        case nil: "ellipsis.circle"
        }
    }

    private var word: String {
        switch passed {
        case true?: passedText
        case false?: failedText
        case nil: waitingText
        }
    }
}
