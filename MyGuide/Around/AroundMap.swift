import MapKit
import MyGuideCore
import SwiftUI

/// The «Rundt deg» map (spec 5, 14, 16): MapKit muted and flat, without Apple's points of interest; the owner's dot
/// with a view cone while the heading is reliable, and an accuracy circle while the fix is too poor to select from;
/// the notify-worthy places as forest markers and the selected one as a coral pin. A tap on a marker chooses it.
/// On the first fix the map frames about `ownerSpan` metres around the owner, once, and follows them from there
/// until they pan or zoom by hand (spec 16.2); then it never re-centres by itself. The round locate button re-centres, follows the owner
/// again and resumes automatic selection (spec 16.1); MapKit's compass sits above it.
///
/// During a tour (tours spec 6) the map also shows its route as forest lines (straight stand-ins dashed) and its stops
/// as numbered pins, the next one coral, in place of their place markers (the selected place keeps its pin); a tap on
/// a stop in the nearby list chooses it as a marker tap does.
struct AroundMap: View {
    let model: AroundModel
    @Binding var position: MapCameraPosition
    let tour: ActiveTour?
    let language: StoryLanguage

    /// Metres across the narrow side of the map when it frames the owner.
    static let ownerSpan: CLLocationDistance = 600

    /// The map camera's heading, so the cone points the right way when the owner has rotated the map.
    @State private var cameraHeading: CLLocationDirection = 0
    /// Set once the first fix has been framed, so later fixes never move the map.
    @State private var framedOwner = false
    /// True from the first framing and after locate, until the owner pans or zooms by hand.
    @State private var following = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            Map(position: $position, scope: mapScope) {
                if model.positionIsPoor, let centre = model.position, let accuracy = model.positionAccuracy {
                    MapCircle(center: centre.clCoordinate, radius: accuracy)
                        .foregroundStyle(Theme.Colour.forest.opacity(0.12))
                        .stroke(Theme.Colour.forest.opacity(0.45), lineWidth: 1)
                }
                if let tour { tourContent(tour) }
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
        .onChange(of: model.position, initial: true) { _, position in follow(position) }
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

    /// Re-centres on the owner at the framing span and follows them again; automatic selection resumes.
    private func locate() {
        model.resumeAutomatic()
        following = true
        if let centre = model.position { frame(centre, animated: !reduceMotion) }
    }

    /// While following, each new position re-centres the map at the framing span. MapKit's own `.userLocation`
    /// following is not used: switching to it resets the zoom to MapKit's city-wide default (seen in the simulator).
    private func follow(_ position: Coordinate?) {
        guard let position else { return }
        if !framedOwner {
            framedOwner = true
            following = true
            frame(position, animated: false)
            return
        }
        // The owner panned or zoomed by hand: following ends until locate (spec 16.2).
        if self.position.positionedByUser { following = false }
        guard following else { return }
        frame(position, animated: !reduceMotion)
    }

    private func frame(_ centre: Coordinate, animated: Bool) {
        let framed = MapCameraPosition.region(Self.region(around: centre))
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { position = framed }
        } else {
            position = framed
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

    /// The places to mark: a tour's stops have their own pins, unless selected.
    private var orderedPlaces: [WalkingPlace] {
        let stopIDs = Set(tour?.stops.map(\.id) ?? [])
        let places = model.places.filter { !stopIDs.contains($0.candidate.id) || $0.candidate.id == selectedID }
        guard let selectedID else { return places }
        return places.filter { $0.candidate.id != selectedID } + places.filter { $0.candidate.id == selectedID }
    }

    // MARK: - Tour

    @MapContentBuilder
    private func tourContent(_ tour: ActiveTour) -> some MapContent {
        ForEach(Array(tour.routed.legs.enumerated()), id: \.offset) { _, leg in
            MapPolyline(coordinates: leg.path.map(\.clCoordinate))
                .stroke(Theme.Colour.forest,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round,
                                           dash: leg.approximate ? [6, 8] : []))
        }
        if tour.routed.plan.kind == .aToB {
            Annotation(ToursTexts.destinationPin(language), coordinate: tour.routed.plan.end.clCoordinate) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colour.forest)
                    .frame(width: 28, height: 28)
                    .background(Theme.Colour.ivory, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Colour.forest, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .accessibilityLabel(ToursTexts.destinationPin(language))
            }
            .annotationTitles(.hidden)
        }
        ForEach(Array(tour.stops.enumerated()), id: \.element.id) { index, stop in
            stopPin(stop, number: index + 1, state: Self.state(of: stop, in: tour))
        }
    }

    /// A stop in the nearby list is a button that chooses it, as its marker would; one outside the list cannot be
    /// chosen, so it is only a labelled pin.
    @MapContentBuilder
    private func stopPin(_ stop: TourStop, number: Int, state: ToursTexts.StopState) -> some MapContent {
        let label = ToursTexts.stopLabel(number, stop.name, state: state, language)
        let badge = StopNumberBadge(number: number, isNext: state == .next, visited: state == .visited,
                                    skipped: state == .skipped)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        if model.places.contains(where: { $0.candidate.id == stop.id }) {
            Annotation(coordinate: stop.coordinate.clCoordinate, anchor: .center) {
                Button {
                    model.choose(stop.id)
                } label: {
                    badge
                        .frame(width: Theme.minimumTouchHeight, height: Theme.minimumTouchHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            } label: {
                EmptyView()
            }
        } else {
            Annotation(coordinate: stop.coordinate.clCoordinate, anchor: .center) {
                badge
                    .accessibilityElement()
                    .accessibilityLabel(label)
            } label: {
                EmptyView()
            }
        }
    }

    private static func state(of stop: TourStop, in tour: ActiveTour) -> ToursTexts.StopState {
        if tour.visited.contains(stop.id) { return .visited }
        if tour.skipped.contains(stop.id) { return .skipped }
        return tour.next?.id == stop.id ? .next : .ahead
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
