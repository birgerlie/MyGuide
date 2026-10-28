import Foundation

/// A fix that counts toward the walked path and distance (spec 4.4).
private func countingFix(_ kind: WalkLogEvent.Kind) -> WalkLogFix? {
    guard case .fix(let f) = kind, f.dropped == nil, !f.paused, f.accuracy <= 50 else { return nil }
    return f
}

/// Walked path as segments. A paused fix or a `paused` event ends a segment; other fixes that do not count are skipped.
private func segments(_ events: [WalkLogEvent]) -> [[Coordinate]] {
    var result: [[Coordinate]] = []
    var current: [Coordinate] = []
    func close() {
        if !current.isEmpty { result.append(current) }
        current = []
    }
    for event in events {
        switch event.kind {
        case .fix(let f) where f.paused: close()
        case .paused: close()
        default: if let f = countingFix(event.kind) { current.append(f.coordinate) }
        }
    }
    close()
    return result
}

public struct WalkLogSummary: Sendable, Equatable {
    public var start: Date?
    public var end: Date?
    public var duration: TimeInterval
    public var distance: Double
    public var fetches: Int
    public var fetchFailures: Int
    public var places: Int
    public var buzzes: Int
    public var notifications: Int
    public var failures: Int
    public var pauses: Int
    /// nil means "Ended without a stop".
    public var stopReason: WalkStopReason?
    public var unreadable: Int

    public init(events: [WalkLogEvent], unreadable: Int) {
        start = events.first?.at
        end = events.last?.at
        duration = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 0
        distance = segments(events).reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
        }
        var fetches = 0, fetchFailures = 0, buzzes = 0, notifications = 0, failures = 0, pauses = 0
        var placeIDs = Set<String>()
        var stop: WalkStopReason?
        for event in events {
            switch event.kind {
            case .fetched(_, _, _, _, let listed): fetches += 1; placeIDs.formUnion(listed.map(\.id))
            case .fetchFailed: fetchFailures += 1; failures += 1
            case .buzz: buzzes += 1
            case .notified: notifications += 1
            case .failure, .notifyFailed, .storyFailed: failures += 1
            case .paused: pauses += 1
            case .stopped(let reason): stop = reason
            default: break
            }
        }
        self.fetches = fetches
        self.fetchFailures = fetchFailures
        self.places = placeIDs.count
        self.buzzes = buzzes
        self.notifications = notifications
        self.failures = failures
        self.pauses = pauses
        self.stopReason = stop
        self.unreadable = unreadable
    }
}

public struct WalkLogMapData: Sendable, Equatable {
    public var path: [[Coordinate]]
    public var places: [WalkLogPlace]
    public var buzzedPlaceIDs: Set<String>
    public var stops: [Coordinate]
    public var pauses: [Coordinate]

    public init(events: [WalkLogEvent]) {
        path = segments(events)
        var order: [String] = []
        var byID: [String: WalkLogPlace] = [:]
        var buzzed = Set<String>()
        var stops: [Coordinate] = []
        var pauses: [Coordinate] = []
        var pendingStop: Coordinate?
        for event in events {
            switch event.kind {
            case .fetched(_, _, _, _, let listed):
                for place in listed {
                    if byID[place.id] == nil { order.append(place.id) }
                    byID[place.id] = place
                }
            case .buzz(let b): buzzed.insert(b.placeID)
            case .stopDetected(let c): pendingStop = c
            case .stopStory(let outcome, _, _):
                if outcome == .told, let c = pendingStop { stops.append(c) }
                pendingStop = nil
            case .paused(_, let at): if let at { pauses.append(at) }
            default: break
            }
        }
        places = order.compactMap { byID[$0] }
        buzzedPlaceIDs = buzzed
        self.stops = stops
        self.pauses = pauses
    }
}
