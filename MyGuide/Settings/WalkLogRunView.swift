import MapKit
import MyGuideCore
import SwiftUI

/// One run of the walk log: the map, the summary and the timeline (spec 4.5).
struct WalkLogRunView: View {
    private struct Loaded: Sendable {
        var events: [WalkLogEvent] = []
        var summary: WalkLogSummary?
        var map = WalkLogMapData(events: [])
        var errorText: String?
    }

    let url: URL
    let isCurrent: Bool

    @State private var loaded: Loaded?
    @State private var position: MapCameraPosition = .automatic
    @State private var hideFixes = true
    /// The screen texts follow the iPhone's language (spec 17).
    private var screenLanguage: StoryLanguage { UILanguage.current }

    var body: some View {
        List {
            if let loaded {
                Section {
                    mapView(loaded.map)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                }
                .themedRows()
                if let errorText = loaded.errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(Theme.Font.caption).foregroundStyle(.red)
                    }
                    .themedRows()
                }
                if let summary = loaded.summary {
                    summarySection(summary)
                }
                Section {
                    Toggle(SettingsTexts.hideFixes(screenLanguage), isOn: $hideFixes)
                        .tint(ScreenChrome.toggleTint)
                    // The event lines are the log's own data; a failure gets a warning symbol as well as red.
                    ForEach(timeline(loaded.events)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.unit) {
                            Text(WalkLogFormat.time(item.event.at, seconds: true))
                                .font(Theme.Font.caption.monospacedDigit()).opacity(0.75)
                            if isFailure(item.event.kind) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.red)
                            }
                            Text(WalkLogFormat.timelineText(item.event.kind, screenLanguage))
                                .font(Theme.Font.caption)
                                .foregroundStyle(isFailure(item.event.kind) ? Color.red : Theme.Colour.text)
                        }
                    }
                } header: {
                    ListSectionHeader(SettingsTexts.timeline(screenLanguage))
                }
                .themedRows()
            } else {
                ProgressView()
                    .themedRows()
            }
        }
        .themedList()
        .themedTitle(SettingsTexts.walk(screenLanguage))
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
        }
        .task { await load() }
    }

    private struct TimelineItem: Identifiable {
        let id: Int
        let event: WalkLogEvent
    }

    private func timeline(_ events: [WalkLogEvent]) -> [TimelineItem] {
        events.enumerated().compactMap { index, event in
            if hideFixes, case .fix = event.kind { return nil }
            return TimelineItem(id: index, event: event)
        }
    }

    private func isFailure(_ kind: WalkLogEvent.Kind) -> Bool {
        switch kind {
        case .fetchFailed, .notifyFailed, .storyFailed, .failure: true
        case .stopStory(let outcome, _, _): outcome == .failed
        default: false
        }
    }

    private func coordinate(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    private func mapView(_ data: WalkLogMapData) -> some View {
        Map(position: $position) {
            ForEach(Array(data.path.enumerated()), id: \.offset) { _, segment in
                if segment.count >= 2 {
                    MapPolyline(coordinates: segment.map(coordinate))
                        // Adaptive: forest on the light map, ivory on the dark one.
                        .stroke(Theme.Colour.text, lineWidth: 4)
                }
            }
            ForEach(data.places, id: \.id) { place in
                if data.buzzedPlaceIDs.contains(place.id) {
                    Marker(place.name, coordinate: coordinate(place.coordinate)).tint(Theme.Colour.coral)
                } else {
                    Annotation(place.name, coordinate: coordinate(place.coordinate), anchor: .center) {
                        Circle().fill(Theme.Colour.text.opacity(0.6)).frame(width: 8, height: 8)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(Array(data.stops.enumerated()), id: \.offset) { _, stop in
                Marker(SettingsTexts.stopMarker(screenLanguage), systemImage: "mappin.and.ellipse",
                       coordinate: coordinate(stop))
                    .tint(Theme.Colour.text)
            }
            ForEach(Array(data.pauses.enumerated()), id: \.offset) { _, pause in
                Annotation(SettingsTexts.pausedMarker(screenLanguage), coordinate: coordinate(pause)) {
                    Image(systemName: "pause.circle.fill").font(.title2)
                        .foregroundStyle(Theme.Colour.text, Theme.Colour.background)
                }
            }
        }
    }

    private func summarySection(_ s: WalkLogSummary) -> some View {
        let language = screenLanguage
        return Section {
            LabeledContent(SettingsTexts.distance(language), value: WalkLogFormat.distance(s.distance))
            LabeledContent(SettingsTexts.duration(language), value: WalkLogFormat.duration(s.duration))
            LabeledContent(SettingsTexts.fetches(language),
                           value: SettingsTexts.fetchCount(s.fetches, failed: s.fetchFailures, language))
            LabeledContent(SettingsTexts.places(language), value: "\(s.places)")
            LabeledContent(SettingsTexts.buzzes(language), value: "\(s.buzzes)")
            LabeledContent(SettingsTexts.notifications(language), value: "\(s.notifications)")
            LabeledContent(SettingsTexts.failuresLabel(language), value: "\(s.failures)")
            LabeledContent(SettingsTexts.pauses(language), value: "\(s.pauses)")
            if let reason = s.stopReason {
                Text(WalkLogFormat.stopReason(reason, language))
            } else if isCurrent {
                LabeledContent(SettingsTexts.status(language), value: SettingsTexts.inProgress(language))
            } else {
                Label(SettingsTexts.endedWithoutStop(language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if s.unreadable > 0 {
                Label(SettingsTexts.unreadableLines(s.unreadable, language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } header: {
            ListSectionHeader(SettingsTexts.summary(language))
        }
        .themedRows()
    }

    private func load() async {
        let url = url
        let language = screenLanguage
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            do {
                let read = WalkLogReader.read(try Data(contentsOf: url))
                return Loaded(events: read.events,
                              summary: WalkLogSummary(events: read.events, unreadable: read.unreadable),
                              map: WalkLogMapData(events: read.events))
            } catch {
                return Loaded(errorText: SettingsTexts.unreadableError(error, language))
            }
        }.value
        loaded = result
        if let region = Self.region(fitting: result.map) { position = .region(region) }
    }

    /// A region holding every point on the map, with a margin; nil when there are none.
    private static func region(fitting map: WalkLogMapData) -> MKCoordinateRegion? {
        let points = map.path.flatMap { $0 } + map.places.map(\.coordinate) + map.stops + map.pauses
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.003),
                                    longitudeDelta: max((maxLon - minLon) * 1.3, 0.003))
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: span)
    }
}
