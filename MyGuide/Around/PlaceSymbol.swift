import MyGuideCore
import SwiftUI

/// A place's marker on the «Rundt deg» map (spec 14): a small forest circle with the kind's symbol in ivory, or, for
/// the selected place, a larger coral pin with the symbol in forest and the name in a small ivory label under it.
/// The selected one differs by size, shape and label, not by colour alone (spec 16.9).
struct PlaceMarker: View {
    let name: String
    let symbol: String
    let isSelected: Bool

    static let size: CGFloat = 28
    static let selectedSize: CGFloat = 36
    /// The pin's point under the selected circle; the annotation is anchored at its tip.
    static let tailHeight: CGFloat = 8

    var body: some View {
        if isSelected { pin } else { dot }
    }

    private var dot: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Colour.ivory)
            .frame(width: Self.size, height: Self.size)
            .background(Theme.Colour.forest, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colour.ivory, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            // A 44 pt target around the 28 pt circle.
            .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
            .contentShape(Circle())
    }

    private var pin: some View {
        VStack(spacing: -1) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colour.forest)
                .frame(width: Self.selectedSize, height: Self.selectedSize)
                .background(Theme.Colour.coral, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Colour.ivory, lineWidth: 2))
            PinTail()
                .fill(Theme.Colour.coral)
                .frame(width: 12, height: Self.tailHeight)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .frame(minWidth: Theme.minimumTouchHeight, minHeight: Theme.minimumTouchHeight, alignment: .bottom)
        .contentShape(Rectangle())
        // Under the tip, outside the layout, so the anchor stays at the tip.
        .overlay(alignment: .bottom) {
            Text(name)
                .font(.custom(Theme.FontName.display, size: 15, relativeTo: .subheadline))
                .foregroundStyle(Theme.Colour.forest)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.unit)
                .padding(.vertical, 4)
                .background(Theme.Colour.ivory, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .fixedSize()
                .alignmentGuide(.bottom) { $0[.top] - 4 }
                .accessibilityHidden(true)
        }
    }
}

/// The downward point of the selected pin.
private struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The card's picture slot when the place has no picture: its kind's symbol on a stone square (spec 16.7).
struct PlaceSymbolTile: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .regular))
            .foregroundStyle(Theme.Colour.forest)
            .frame(width: size, height: size)
            .background(Theme.Colour.stone, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}
