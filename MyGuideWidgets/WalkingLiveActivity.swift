import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen and Dynamic Island presentation of walking mode, in the design (spec 7.5). The app computes every
/// text; this only lays it out.
struct WalkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkingActivityAttributes.self) { context in
            WalkingLockScreen(content: Content(context))
        } dynamicIsland: { context in
            let content = Content(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WalkingMark(size: 22)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // The island is always black: ivory text, whatever the appearance.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.title)
                            .font(.custom(content.titleIsHeading ? Theme.FontName.display : Theme.FontName.medium,
                                          size: 17, relativeTo: .headline))
                            .lineLimit(1)
                        if let line = content.line {
                            Text(line)
                                .font(.custom(Theme.FontName.regular, size: 14, relativeTo: .subheadline))
                                .lineLimit(2)
                                .opacity(0.85)
                        }
                    }
                    .foregroundStyle(Theme.Colour.ivory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                WalkingMark(size: 15)
            } compactTrailing: {
                if let name = content.shortPlaceName {
                    Text(name)
                        .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
                        .foregroundStyle(Theme.Colour.ivory)
                        .lineLimit(1)
                }
            } minimal: {
                WalkingMark(size: 15)
            }
            .widgetURL(content.storyURL)
            .keylineTint(Theme.Colour.coral)
        }
    }
}

/// What the activity shows, in display order, after the stale rule: a stale activity is one the app stopped
/// updating, so it must not claim walking mode is running and shows only the paused texts.
private struct Content {
    /// The walking status above a place, or nil when the title already is the status (or a stop story's title).
    let status: String?
    /// The place name or stop story title (Playfair), or the status itself before the first place and when stale.
    let title: String
    /// True when `title` is a place name or story title, set in Playfair; false when it is the status (Inter).
    let titleIsHeading: Bool
    /// The factual line, the stop story's text, the waiting text or «Åpne MyGuide».
    let line: String?
    let placeName: String?
    let storyURL: URL?

    /// The compact island has room for about 12 characters: a longer name is cut to 11 and "…".
    static let compactNameLength = 12

    init(_ context: ActivityViewContext<WalkingActivityAttributes>) {
        let state = context.state
        if context.isStale {
            let norwegian = context.attributes.isNorwegian
            status = nil
            title = WalkingActivityAttributes.pausedHeadline(norwegian: norwegian)
            titleIsHeading = false
            line = WalkingActivityAttributes.pausedBody(norwegian: norwegian)
            placeName = nil
            storyURL = nil
        } else if let storyID = state.storyID {
            status = nil
            title = state.headline
            titleIsHeading = true
            line = state.body.isEmpty ? nil : state.body
            placeName = nil
            storyURL = WalkingActivityAttributes.storyURL(storyID)
        } else if let name = state.placeName {
            status = state.headline
            title = name
            titleIsHeading = true
            line = state.placeFact
            placeName = name
            storyURL = nil
        } else {
            status = nil
            title = state.headline
            titleIsHeading = false
            line = state.body.isEmpty ? nil : state.body
            placeName = nil
            storyURL = nil
        }
    }

    /// The place name for the compact island, at most `compactNameLength` characters; nil when there is no place.
    var shortPlaceName: String? {
        guard let placeName else { return nil }
        guard placeName.count > Self.compactNameLength else { return placeName }
        return placeName.prefix(Self.compactNameLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The walking mark in coral: the same in the island and on the lock screen.
private struct WalkingMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "figure.walk")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.Colour.coral)
    }
}

/// The lock screen and banner: ivory (forest in dark mode) with forest (ivory) text. A stop story is about 50 words:
/// 8 lines fit it; a tap opens it in full.
private struct WalkingLockScreen: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.unit * 1.5) {
            WalkingMark(size: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if let status = content.status {
                    Text(status)
                        .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
                        .lineLimit(1)
                        .opacity(0.75)
                }
                Text(content.title)
                    .font(content.titleIsHeading
                          ? .custom(Theme.FontName.display, size: 20, relativeTo: .title3)
                          : .custom(Theme.FontName.medium, size: 17, relativeTo: .headline))
                    .lineLimit(content.titleIsHeading ? 2 : 1)
                if let line = content.line {
                    Text(line)
                        .font(.custom(Theme.FontName.regular, size: 15, relativeTo: .subheadline))
                        .lineLimit(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(text)
        .padding(Theme.Spacing.margin)
        // The colours are handed to the system, so they are resolved here for the appearance rather than left dynamic
        // (`Theme.Colour.background` and `.text`, resolved).
        .activityBackgroundTint(dark ? Theme.Colour.forest : Theme.Colour.ivory)
        .activitySystemActionForegroundColor(text)
        // A tap opens the stop story on show; nothing to open while the activity only reports walking or is stale.
        .widgetURL(content.storyURL)
    }

    private var dark: Bool { colorScheme == .dark }
    private var text: Color { dark ? Theme.Colour.ivory : Theme.Colour.forest }
}
