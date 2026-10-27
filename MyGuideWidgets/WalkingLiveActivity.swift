import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen and Dynamic Island presentation of walking mode.
struct WalkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkingActivityAttributes.self) { context in
            // Lock screen and banner. A stop story is about 50 words: 8 lines fit it; a tap opens it in full.
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.headline(context))
                    .font(.headline)
                    .lineLimit(1)
                Text(context.isStale ? WalkingActivityAttributes.pausedBody : context.state.body)
                    .font(.subheadline)
                    .lineLimit(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            // A tap opens the stop story on show; nothing to open while the activity only says "Walking" or is stale.
            .widgetURL(Self.storyURL(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(Self.headline(context))
                        .font(.headline)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "figure.walk")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "figure.walk")
            }
            .widgetURL(Self.storyURL(context))
        }
    }

    /// A stale activity is one the app stopped updating: it must not claim walking mode is running.
    private static func headline(_ context: ActivityViewContext<WalkingActivityAttributes>) -> String {
        context.isStale ? WalkingActivityAttributes.pausedHeadline : context.state.headline
    }

    private static func storyURL(_ context: ActivityViewContext<WalkingActivityAttributes>) -> URL? {
        context.isStale ? nil : context.state.storyID.map(WalkingActivityAttributes.storyURL)
    }
}
