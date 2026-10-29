import MapKit
import MyGuideCore
import SwiftUI

/// The «Rundt deg» map (spec 5, 14): MapKit muted and flat, without Apple's points of interest; the owner's dot with
/// a view cone while the heading is reliable; the notify-worthy places as forest markers and the selected one as a
/// coral pin. A tap on a marker chooses it. Compass and locate are MapKit's own controls; the camera follows the
/// owner (without heading) until they pan, and the locate control follows again (spec 16.2).
struct AroundMap: View {
    let model: AroundModel
    @Binding var position: MapCameraPosition
    let language: StoryLanguage

    /// The map camera's heading, so the cone points the right way when the owner has rotated the map.
    @State private var cameraHeading: CLLocationDirection = 0

    var body: some View {
        Map(position: $position) {
            UserAnnotation {
                OwnerDot(coneRotation: model.heading.map { $0 - cameraHeading })
            }
            // The selected place last: MapKit tends to draw later annotations on top, so its pin and label stay visible.
            ForEach(orderedPlaces, id: \.candidate.id) { place in
                marker(place.candidate, isSelected: place.candidate.id == selectedID)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
                .mapControlVisibility(.visible)
            MapUserLocationButton()
        }
        .mapControlVisibility(.visible)
        .onMapCameraChange(frequency: .continuous) { context in
            if cameraHeading != context.camera.heading { cameraHeading = context.camera.heading }
        }
    }

    private func marker(_ candidate: Candidate, isSelected: Bool) -> some MapContent {
        Annotation(coordinate: candidate.coordinate.clCoordinate, anchor: isSelected ? .bottom : .center) {
            Button {
                model.choose(candidate.id)
            } label: {
                PlaceMarker(name: candidate.name, symbol: PlaceSymbol.systemName(for: candidate), isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AroundTexts.markerLabel(candidate.name, isSelected: isSelected, language))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } label: {
            EmptyView()
        }
    }

    private var orderedPlaces: [WalkingPlace] {
        guard let selectedID else { return model.places }
        return model.places.filter { $0.candidate.id != selectedID } + model.places.filter { $0.candidate.id == selectedID }
    }

    private var selectedID: String? {
        if case .selected(let selected) = model.selection { return selected.vector.place.candidate.id }
        return nil
    }
}

/// The owner's position: a forest dot with an ivory ring and, while the heading is reliable, a translucent forest
/// wedge of ±30° (the selection angle of spec 6.2) in the phone's direction.
private struct OwnerDot: View {
    /// Degrees clockwise from the top of the screen; nil draws no cone.
    let coneRotation: Double?

    private static let coneLength: CGFloat = 64
    private static let dotSize: CGFloat = 18

    var body: some View {
        ZStack {
            if let coneRotation {
                ViewCone(halfAngle: .degrees(30))
                    .fill(RadialGradient(colors: [Theme.Colour.forest.opacity(0.45), Theme.Colour.forest.opacity(0)],
                                         center: .center, startRadius: Self.dotSize / 2, endRadius: Self.coneLength))
                    .rotationEffect(.degrees(coneRotation))
            }
            Circle()
                .fill(Theme.Colour.forest)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .overlay(Circle().strokeBorder(Theme.Colour.ivory, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: Self.coneLength * 2, height: Self.coneLength * 2)
        // The cone is decoration: taps go through to the markers under it.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A circular sector from the centre of its rect, pointing up, `halfAngle` to each side.
private struct ViewCone: Shape {
    let halfAngle: Angle

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // SwiftUI angles run clockwise from the +x axis; straight up is −90°.
        let up = Angle.degrees(-90)
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: radius, startAngle: up - halfAngle, endAngle: up + halfAngle,
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
