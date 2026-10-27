import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen and Dynamic Island presentation of walking mode.
struct WalkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkingActivityAttributes.self) { context in
            // Lock screen and banner.
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.headline)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.body)
                    .font(.subheadline)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            // A tap opens the stop story on show; nothing to open while the activity only says "Walking".
            .widgetURL(context.state.storyID.map(WalkingActivityAttributes.storyURL))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.headline)
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
            .widgetURL(context.state.storyID.map(WalkingActivityAttributes.storyURL))
        }
    }
}
