import MyGuideCore
import SwiftUI

/// The day's stored story: its summary, or a note that there is none yet. Read once when the screen opens.
struct DayStoryScreen: View {
    let dayKey: String
    let services: AppServices

    @State private var summary: String?
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        content
            .navigationTitle("Day story")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: dayKey) {
                do {
                    summary = try services.memory.dayStory(dayKey: dayKey)?.summary
                } catch {
                    AppServices.logMemoryFailure("day story load failed", error)
                    failed = true
                }
                loaded = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let summary {
            ScrollView {
                Text(summary)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if failed {
            ContentUnavailableView("This day story couldn't be opened.", systemImage: "exclamationmark.triangle")
        } else if loaded {
            ContentUnavailableView("No day story yet.", systemImage: "book.pages")
        } else {
            ProgressView()
        }
    }
}
