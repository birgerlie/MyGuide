import MyGuideCore
import SwiftUI

/// Story prose as separate paragraphs with 24 pt between them (three steps of the 8 pt rhythm), instead of the one
/// blank line a single `Text` gives.
struct StoryText: View {
    static let paragraphSpacing: CGFloat = Theme.Spacing.unit * 3

    let text: String
    var font: Font = Theme.Font.body
    var selectable = false

    var body: some View {
        VStack(alignment: .leading, spacing: Self.paragraphSpacing) {
            ForEach(Array(StoryParagraphs.split(text).enumerated()), id: \.offset) { _, paragraph in
                if selectable {
                    Text(paragraph).font(font).textSelection(.enabled)
                } else {
                    Text(paragraph).font(font)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver reads the story as one passage, not one element per paragraph.
        .accessibilityElement(children: .combine)
    }
}
