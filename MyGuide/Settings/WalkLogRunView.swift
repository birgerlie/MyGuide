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

    var body: some View {
        List {
            if let loaded {
                Section {
                    mapView(loaded.map)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                }
                if let errorText = loaded.errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
                if let summary = loaded.summary {
                    summarySection(summary)
                }
                Section {
                    Toggle("Hide fixes", isOn: $hideFixes)
                    ForEach(timeline(loaded.events)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(WalkLogFormat.time(item.event.at, seconds: true))
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            Text(WalkLogText.line(item.event.kind))
                                .font(.footnote)
                                .foregroundStyle(isFailure(item.event.kind) ? Color.red : Color.primary)
                        }
                    }
                } header: {
                    Text("Timeline")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Walk")
        .navigationBarTitleDisplayMode(.inline)
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
                        .stroke(.blue, lineWidth: 4)
                }
            }
            ForEach(data.places, id: \.id) { place in
                if data.buzzedPlaceIDs.contains(place.id) {
                    Marker(place.name, coordinate: coordinate(place.coordinate)).tint(.orange)
                } else {
                    Annotation(place.name, coordinate: coordinate(place.coordinate), anchor: .center) {
                        Circle().fill(.gray).frame(width: 8, height: 8)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(Array(data.stops.enumerated()), id: \.offset) { _, stop in
                Marker("Stop", coordinate: coordinate(stop)).tint(.blue)
            }
            ForEach(Array(data.pauses.enumerated()), id: \.offset) { _, pause in
                Annotation("Paused", coordinate: coordinate(pause)) {
                    Image(systemName: "pause.circle").font(.title2).foregroundStyle(.indigo)
                }
            }
        }
    }

    private func summarySection(_ s: WalkLogSummary) -> some View {
        Section("Summary") {
            LabeledContent("Distance", value: WalkLogFormat.distance(s.distance))
            LabeledContent("Duration", value: WalkLogFormat.duration(s.duration))
            LabeledContent("Fetches", value: "\(s.fetches) (\(s.fetchFailures) failed)")
            LabeledContent("Places", value: "\(s.places)")
            LabeledContent("Buzzes", value: "\(s.buzzes)")
            LabeledContent("Notifications", value: "\(s.notifications)")
            LabeledContent("Failures", value: "\(s.failures)")
            LabeledContent("Pauses", value: "\(s.pauses)")
            if let reason = s.stopReason {
                LabeledContent("Stopped", value: reason.rawValue)
            } else if isCurrent {
                LabeledContent("Status", value: "In progress")
            } else {
                Text("Ended without a stop").foregroundStyle(.red)
            }
            if s.unreadable > 0 {
                Text("\(s.unreadable) unreadable lines").foregroundStyle(.red)
            }
        }
    }

    private func load() async {
        let url = url
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            do {
                let read = WalkLogReader.read(try Data(contentsOf: url))
                return Loaded(events: read.events,
                              summary: WalkLogSummary(events: read.events, unreadable: read.unreadable),
                              map: WalkLogMapData(events: read.events))
            } catch {
                return Loaded(errorText: "Unreadable: \(error)")
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
