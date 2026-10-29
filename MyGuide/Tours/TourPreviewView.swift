import MapKit
import MyGuideCore
import SwiftUI

/// The tour preview (tours spec 5, 6): a muted map with the route in forest and numbered stops (the next stop coral),
/// the totals, «Omtrentlig rute» when some leg is a straight stand-in, the stop list with «Fjern», the honest empty
/// and degenerate states, and «Start turen» in coral.
struct TourPreviewView: View {
    let model: TourBuilderModel
    let language: StoryLanguage
    /// Hands the shown tour over to whatever starts it (see `ToursTab.onStart`).
    let onStart: (RoutedTour) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let preview = model.preview {
                content(preview)
            } else {
                Theme.Colour.background
            }
        }
        .background(Theme.Colour.background)
        .navigationTitle(ToursTexts.previewTitle(language))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ preview: TourBuilderModel.Preview) -> some View {
        let routed = preview.routed
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.margin) {
                TourRouteMap(routed: routed, language: language)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
                VStack(alignment: .leading, spacing: Theme.Spacing.unit) {
                    Text(heading(preview.request))
                        .font(.custom(Theme.FontName.medium, size: 22, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Text(TourFormat.totals(seconds: routed.totalSeconds, metres: routed.totalMetres,
                                           stops: routed.plan.stops.count, language: language))
                        .font(Theme.Font.bodyMedium)
                }
                if routed.approximate {
                    note(symbol: "line.diagonal", title: ToursTexts.approximate(language),
                         detail: ToursTexts.approximateDetail(language))
                }
                if preview.partialSources {
                    note(symbol: "antenna.radiowaves.left.and.right.slash", title: nil,
                         detail: ToursTexts.partialSources(language))
                }
                if let empty = emptyText(preview) {
                    note(symbol: "mappin.slash", title: nil, detail: empty)
                } else {
                    stopList(preview)
                }
            }
            .foregroundStyle(Theme.Colour.text)
            .padding(.horizontal, Theme.Spacing.margin)
            .padding(.vertical, Theme.Spacing.unit)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions(preview) }
    }

    // MARK: - Texts

    private func heading(_ request: TourBuilderModel.Request) -> String {
        switch request {
        case .loop(let minutes): ToursTexts.loopHeading(minutes: minutes, language)
        case .destination(let destination): ToursTexts.destinationHeading(destination.name, language)
        }
    }

    /// The honest text when the tour has no stops (spec 5); nil when it has some.
    private func emptyText(_ preview: TourBuilderModel.Preview) -> String? {
        let plan = preview.routed.plan
        guard plan.stops.isEmpty else { return nil }
        if preview.removedByOwner > 0 { return ToursTexts.allRemoved(language) }
        switch preview.request {
        case .loop(let minutes):
            return ToursTexts.noStopsLoop(minutes: minutes, language)
        case .destination:
            let direct = GeoMath.distance(plan.start, plan.end)
            if direct < TourPlanner.minimumDirectMetres {
                return ToursTexts.destinationTooClose(TourFormat.distance(direct, language: language), language)
            }
            return ToursTexts.noStopsAToB(language)
        }
    }

    // MARK: - Pieces

    private func note(symbol: String, title: String?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(Theme.Font.bodyMedium) }
                Text(detail).font(Theme.Font.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Stone is the same in both appearances, so the text on it is always forest.
        .foregroundStyle(Theme.Colour.forest)
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.stone, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func stopList(_ preview: TourBuilderModel.Preview) -> some View {
        let routed = preview.routed
        let stops = routed.plan.stops
        return VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                TourStopRow(model: model, preview: preview, stop: stop, number: index + 1,
                            legSeconds: index < routed.legs.count ? routed.legs[index].seconds : 0,
                            language: language)
                Divider().overlay(Theme.Colour.stone)
            }
            finalLeg(routed)
        }
    }

    /// The walk from the last stop back to the start (loop) or on to the destination (A→B), so the rows add up.
    private func finalLeg(_ routed: RoutedTour) -> some View {
        HStack(spacing: 12) {
            Image(systemName: routed.plan.kind == .loop ? "arrow.uturn.backward" : "flag.checkered")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: StopNumberBadge.size, height: StopNumberBadge.size)
                .accessibilityHidden(true)
            Text(ToursTexts.finalLeg(isLoop: routed.plan.kind == .loop, language))
                .font(Theme.Font.bodyMedium)
            Spacer(minLength: Theme.Spacing.unit)
            Text(ToursTexts.walkTo(TourFormat.duration(routed.legs.last?.seconds ?? 0, language: language), language))
                .font(Theme.Font.caption)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ preview: TourBuilderModel.Preview) -> some View {
        VStack(spacing: Theme.Spacing.unit) {
            if model.refitting {
                HStack(spacing: 12) {
                    ProgressView().tint(Theme.Colour.text)
                    Text(ToursTexts.routing(language)).font(Theme.Font.body)
                    Spacer(minLength: Theme.Spacing.unit)
                    Button(ToursTexts.cancel(language)) { model.cancel() }
                        .font(Theme.Font.bodyMedium)
                        .frame(minHeight: Theme.minimumTouchHeight)
                }
                .foregroundStyle(Theme.Colour.text)
            }
            primaryAction(preview)
        }
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.top, Theme.Spacing.unit * 1.5)
        .padding(.bottom, Theme.Spacing.unit)
        .background(Theme.Colour.background)
        .overlay(alignment: .top) { Divider().overlay(Theme.Colour.stone) }
    }

    /// «Start turen» with stops; «Gå direkte» for an A→B without them; for a loop without them a longer duration, or
    /// only «Ny tur» after the longest.
    @ViewBuilder
    private func primaryAction(_ preview: TourBuilderModel.Preview) -> some View {
        let routed = preview.routed
        if !routed.plan.stops.isEmpty || routed.plan.kind == .aToB {
            Button(routed.plan.stops.isEmpty ? ToursTexts.walkDirect(language) : ToursTexts.start(language)) {
                onStart(routed)
                model.closePreview()
            }
            .buttonStyle(.themePrimary())
            .disabled(model.refitting)
        } else if preview.removedByOwner == 0, case .loop(let minutes) = preview.request,
                  let longer = TourBuilderModel.longerDuration(than: minutes) {
            Button(ToursTexts.tryLonger(minutes: longer, language)) { model.tryLonger() }
                .buttonStyle(.themePrimary())
        }
        if routed.plan.stops.isEmpty {
            Button(ToursTexts.newTour(language)) { dismiss() }
                .buttonStyle(.themeSecondary)
        }
    }
}

/// One stop: its number, its picture when cached (else its kind's symbol on stone), its name, its kind symbol with
/// the walk to it, and «Fjern».
private struct TourStopRow: View {
    let model: TourBuilderModel
    let preview: TourBuilderModel.Preview
    let stop: TourStop
    let number: Int
    let legSeconds: Double
    let language: StoryLanguage

    @State private var picture: UIImage?
    @Environment(\.displayScale) private var displayScale

    private static let pictureSize: CGFloat = 56

    private var symbol: String {
        preview.places[stop.id].map(PlaceSymbol.systemName(for:)) ?? "mappin"
    }

    /// «Stopp 1, første stopp, Pantheon, 12 min å gå».
    private var accessibilityText: String {
        let walk = ToursTexts.walkTo(TourFormat.duration(legSeconds, language: language), language)
        let next = number == 1 ? ", \(ToursTexts.nextStop(language))" : ""
        return "\(ToursTexts.stopNumber(number, language))\(next), \(stop.name), \(walk)"
    }

    var body: some View {
        HStack(spacing: 12) {
            StopNumberBadge(number: number, isNext: number == 1)
            Group {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.pictureSize, height: Self.pictureSize)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    PlaceSymbolTile(symbol: symbol, size: Self.pictureSize)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.name)
                    .font(.custom(Theme.FontName.display, size: 17, relativeTo: .body))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                    Text(ToursTexts.walkTo(TourFormat.duration(legSeconds, language: language), language))
                }
                .font(Theme.Font.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Button(ToursTexts.remove(language)) { model.remove(stop.id) }
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Colour.forest)
                .padding(.horizontal, 12)
                .frame(minHeight: Theme.minimumTouchHeight)
                .background(Theme.Colour.stone, in: Capsule())
                .buttonStyle(.plain)
                .disabled(model.refitting)
                .opacity(model.refitting ? 0.5 : 1)
                .accessibilityLabel(ToursTexts.removeLabel(stop.name, language))
        }
        .padding(.vertical, 12)
        .task(id: "\(stop.id)#\(model.picturesVersion)") {
            let loaded = await model.cachedPicture(for: stop, in: preview,
                                                   maxPixels: Int((Self.pictureSize * displayScale).rounded(.up)))
            guard !Task.isCancelled else { return }
            if let loaded { picture = loaded }
        }
    }
}

/// A stop's number in a circle: forest with ivory digits, or, for the next stop, a larger coral circle with forest
/// digits and an ivory ring (size and ring, not colour alone). During a tour a visited stop shows a check mark instead
/// of its number and a skipped one is faded, both smaller than the next.
struct StopNumberBadge: View {
    let number: Int
    let isNext: Bool
    var visited = false
    var skipped = false

    static let size: CGFloat = 28
    static let nextSize: CGFloat = 34

    var body: some View {
        Group {
            if visited {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
            } else {
                Text("\(number)")
                    .font(.custom(Theme.FontName.medium, size: isNext ? 16 : 14, relativeTo: .caption))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isNext ? Theme.Colour.forest : Theme.Colour.ivory)
        .frame(width: isNext ? Self.nextSize : Self.size, height: isNext ? Self.nextSize : Self.size)
        .background(isNext ? Theme.Colour.coral : Theme.Colour.forest, in: Circle())
        .overlay(Circle().strokeBorder(Theme.Colour.ivory, lineWidth: isNext ? 2 : 1.5))
        .opacity(skipped ? 0.45 : 1)
        .frame(width: Self.nextSize, height: Self.nextSize)
        .accessibilityHidden(true)
    }
}

/// The preview's map: MapKit muted and flat without Apple's points of interest (as `AroundMap`), the walked legs as
/// forest lines (straight stand-ins dashed), numbered stop pins, and the start (and an A→B's destination). It frames
/// the whole tour, again after each change.
private struct TourRouteMap: View {
    let routed: RoutedTour
    let language: StoryLanguage

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(Array(routed.legs.enumerated()), id: \.offset) { _, leg in
                MapPolyline(coordinates: leg.path.map(\.clCoordinate))
                    .stroke(Theme.Colour.forest,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round,
                                               dash: leg.approximate ? [6, 8] : []))
            }
            Annotation(ToursTexts.startPin(language), coordinate: routed.plan.start.clCoordinate) {
                endPin(symbol: "figure.walk")
            }
            .annotationTitles(.hidden)
            if routed.plan.kind == .aToB {
                Annotation(ToursTexts.destinationPin(language), coordinate: routed.plan.end.clCoordinate) {
                    endPin(symbol: "flag.checkered")
                }
                .annotationTitles(.hidden)
            }
            ForEach(Array(routed.plan.stops.enumerated()), id: \.element.id) { index, stop in
                Annotation(stop.name, coordinate: stop.coordinate.clCoordinate) {
                    StopNumberBadge(number: index + 1, isNext: index == 0)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .onChange(of: routed) { position = .automatic }
        .accessibilityLabel(ToursTexts.mapLabel(language))
    }

    private func endPin(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Colour.forest)
            .frame(width: 28, height: 28)
            .background(Theme.Colour.ivory, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colour.forest, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
