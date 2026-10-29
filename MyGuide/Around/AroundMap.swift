import MapKit
import MyGuideCore
import SwiftUI

/// The «Rundt deg» map (spec 5, 14, 16): MapKit muted and flat, without Apple's points of interest; the owner's dot
/// with a view cone while the heading is reliable, and an accuracy circle while the fix is too poor to select from;
/// the notify-worthy places as forest markers and the selected one as a coral pin. A tap on a marker chooses it.
/// On the first fix the map frames about `ownerSpan` metres around the owner, once. After that it never re-centres
/// by itself: panning and zooming are the owner's (spec 16.2). The round locate button re-centres, follows the owner
/// again and resumes automatic selection (spec 16.1); MapKit's compass sits above it.
struct AroundMap: View {
    let model: AroundModel
    @Binding var position: MapCameraPosition
    let language: StoryLanguage

    /// Metres across the narrow side of the map when it frames the owner.
    static let ownerSpan: CLLocationDistance = 600

    /// The map camera's heading, so the cone points the right way when the owner has rotated the map.
    @State private var cameraHeading: CLLocationDirection = 0
    /// Set once the first fix has been framed, so later fixes never move the map.
    @State private var framedOwner = false
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            Map(position: $position, scope: mapScope) {
                if model.positionIsPoor, let centre = model.position, let accuracy = model.positionAccuracy {
                    MapCircle(center: centre.clCoordinate, radius: accuracy)
                        .foregroundStyle(Theme.Colour.forest.opacity(0.12))
                        .stroke(Theme.Colour.forest.opacity(0.45), lineWidth: 1)
                }
                UserAnnotation {
                    OwnerDot(coneRotation: model.heading.map { $0 - cameraHeading })
                }
                // The selected place last: MapKit tends to draw later annotations on top, so its pin and label stay
                // visible.
                ForEach(orderedPlaces, id: \.candidate.id) { place in
                    marker(place.candidate, isSelected: place.candidate.id == selectedID)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll,
                                showsTraffic: false))
            // Only our own controls (below); MapKit's would follow without telling the selection.
            .mapControls {}
            .onMapCameraChange(frequency: .continuous) { context in
                if cameraHeading != context.camera.heading { cameraHeading = context.camera.heading }
            }
            // The free part of the map, inside the safe area; transparent to touches, its buttons are not.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .topTrailing) { controls }
        }
        .mapScope(mapScope)
        .onChange(of: model.position, initial: true) { _, position in
            guard !framedOwner, let position else { return }
            framedOwner = true
            self.position = .region(Self.region(around: position))
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Spacing.unit) {
            MapCompass(scope: mapScope)
                .mapControlVisibility(.visible)
            Button(action: locate) {
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colour.forest)
                    .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                    .background(Theme.Colour.ivory, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AroundTexts.locate(language))
        }
        .padding(.trailing, Theme.Spacing.margin)
        .padding(.top, Theme.Spacing.unit)
    }

    /// Re-centres on the owner at the framing span, then follows them (MapKit keeps that zoom while following);
    /// automatic selection resumes. Following ends again when the owner pans.
    private func locate() {
        model.resumeAutomatic()
        guard let centre = model.position else {
            position = .userLocation(fallback: .automatic)
            return
        }
        let framed = Self.region(around: centre)
        withAnimation { position = .region(framed) }
        Task { @MainActor in
            // After the re-centring animation, unless the owner has taken the map meanwhile.
            try? await Task.sleep(for: .milliseconds(700))
            guard !position.positionedByUser else { return }
            position = .userLocation(followsHeading: false, fallback: .region(framed))
        }
    }

    static func region(around centre: Coordinate) -> MKCoordinateRegion {
        MKCoordinateRegion(center: centre.clCoordinate, latitudinalMeters: ownerSpan, longitudinalMeters: ownerSpan)
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
