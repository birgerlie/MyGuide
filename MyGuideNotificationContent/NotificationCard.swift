import SwiftUI
import UIKit

/// The expanded walking notification in the design (spec 7.4, 12.9): the picture edge to edge on top when there is
/// one, then the label in spaced capitals, the name in Playfair, the distance and direction, the factual line and the
/// photo credit. Every part but the name is optional; what the payload leaves out is not drawn.
struct NotificationCard: View {
    let payload: NotificationPayload
    let picture: UIImage?

    /// Width over height of the picture's frame.
    static let pictureAspect: CGFloat = 16 / 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let picture { hero(picture) }
            VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
                if !payload.label.isEmpty { label(payload.label) }
                Text(payload.name)
                    .font(Theme.Font.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let line = payload.line, !line.isEmpty { direction(line) }
                if let fact = payload.fact, !fact.isEmpty {
                    Text(fact)
                        .font(Theme.Font.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if picture != nil, let credit = payload.credit, !credit.isEmpty {
                    Text(credit)
                        .font(Theme.Font.caption)
                        .opacity(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Spacing.unit)
                }
            }
            .padding(Theme.Spacing.wideMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.Colour.text)
        .background(Theme.Colour.background)
    }

    /// Edge to edge, cropped to 16:10 so a tall picture never pushes the text out of the card.
    private func hero(_ image: UIImage) -> some View {
        Color.clear
            .aspectRatio(Self.pictureAspect, contentMode: .fit)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .accessibilityHidden(true)
    }

    /// "STED I NÆRHETEN", "NESTE DEL", "HER DU STOPPET": small spaced capitals, as on the story screen.
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom(Theme.FontName.medium, size: 13, relativeTo: .caption))
            .tracking(1.6)
            .opacity(0.75)
            .accessibilityAddTraits(.isHeader)
    }

    /// "50 m foran deg" after a coral position symbol. The symbol is decoration: the words carry the direction.
    private func direction(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.unit) {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colour.coral)
                .accessibilityHidden(true)
            Text(line)
                .font(Theme.Font.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
