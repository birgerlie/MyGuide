import Foundation

/// Tuning of the direction-based place selection (spec 6.2–6.4, 12.3).
public struct PlaceSelectionConfig: Sendable, Equatable {
    public var selectHalfAngle = 30.0      // degrees
    public var keepHalfAngle = 40.0
    public var dwell: TimeInterval = 1.5
    public var equalRatio = 0.15           // challenger must be nearer by > max(ratio·d, metres)
    public var equalMetres = 10.0
    public var maxHeadingAccuracy = 25.0
    public var maxPositionAccuracy = 50.0
    public var directionDistanceFactor = 2.0   // direction stated only when distance > factor·accuracy
    public var explicitHold: TimeInterval = 20
    public var explicitTurn = 60.0
    public var clusterSpacing = 15.0       // two nearest within this of each other …
    public var clusterReach = 40.0         // … and both within this of the owner → suggest a photo
    public init() {}
}

/// A place seen from the owner's position.
public struct PlaceVector: Sendable, Equatable {
    public var place: WalkingPlace
    public var distance: Double
    public var bearing: Double

    public init(place: WalkingPlace, distance: Double, bearing: Double) {
        self.place = place
        self.distance = distance
        self.bearing = bearing
    }

    /// Distance and bearing of every place from `position`, in the order given.
    public static func from(position: Coordinate, places: [WalkingPlace]) -> [PlaceVector] {
        places.map {
            PlaceVector(place: $0,
                        distance: GeoMath.distance(position, $0.candidate.coordinate),
                        bearing: GeoMath.bearing(from: position, to: $0.candidate.coordinate))
        }
    }
}

public struct SelectionInput: Sendable, Equatable {
    public var vectors: [PlaceVector]
    public var positionAccuracy: Double
    public var heading: Double?            // smoothed, degrees; nil = none
    public var headingAccuracy: Double?
    public var playingPlaceID: String?
    public var now: Date

    public init(vectors: [PlaceVector], positionAccuracy: Double, heading: Double?, headingAccuracy: Double?,
                playingPlaceID: String?, now: Date) {
        self.vectors = vectors
        self.positionAccuracy = positionAccuracy
        self.heading = heading
        self.headingAccuracy = headingAccuracy
        self.playingPlaceID = playingPlaceID
        self.now = now
    }
}

public struct SelectedPlace: Sendable, Equatable {
    public var vector: PlaceVector
    /// Offset bearing − heading in (−180, 180], only when a direction may be stated (reliable heading and
    /// distance > factor · position accuracy); nil otherwise.
    public var relative: Double?
    public var suggestPhoto: Bool

    public init(vector: PlaceVector, relative: Double?, suggestPhoto: Bool) {
        self.vector = vector
        self.relative = relative
        self.suggestPhoto = suggestPhoto
    }
}

public enum SelectionState: Sendable, Equatable {
    case noPlaces
    case uncertainPosition
    case selected(SelectedPlace)
}

/// Picks the place the owner is looking at. Pure state machine: the caller feeds it positions and headings.
public struct PlaceSelector: Sendable {
    private let config: PlaceSelectionConfig
    public private(set) var state: SelectionState = .noPlaces

    private var currentID: String?
    /// The latest automatic winner and the instant it first became the winner (reset when the winner changes).
    private var pending: (id: String, since: Date)?
    private var hold: (id: String, since: Date, heading: Double?)?

    public init(config: PlaceSelectionConfig = .init()) {
        self.config = config
    }

    /// Offset of `bearing` from `heading`, wrapped into (−180, 180].
    public static func offset(heading: Double, bearing: Double) -> Double {
        var r = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }            // 0 ..< 360
        if r > 180 { r -= 360 }
        return r
    }

    @discardableResult
    public mutating func update(_ input: SelectionInput) -> SelectionState {
        guard input.positionAccuracy <= config.maxPositionAccuracy else {
            reset()
            state = .uncertainPosition
            return state
        }
        guard !input.vectors.isEmpty else {
            reset()
            state = .noPlaces
            return state
        }
        let reliable = Self.reliableHeading(input, config)
        let winner = Self.winner(input, reliable: reliable, config)
        trackWinner(winner.place.candidate.id, now: input.now, current: currentID)

        let chosen: PlaceVector
        if let id = input.playingPlaceID, let playing = input.vectors.first(where: { $0.place.candidate.id == id }) {
            chosen = playing
        } else if let held = heldVector(input, reliable: reliable) {
            chosen = held
        } else if let cur = currentID.flatMap({ id in input.vectors.first { $0.place.candidate.id == id } }) {
            chosen = automatic(current: cur, winner: winner, input: input, reliable: reliable)
        } else {
            chosen = winner       // first selection, or the current place vanished
        }
        return finish(chosen, input: input, reliable: reliable)
    }

    /// The owner tapped a place: select it at once and hold it against automatic changes for `explicitHold`
    /// seconds, or until the owner has turned more than `explicitTurn` degrees.
    @discardableResult
    public mutating func choose(placeID: String, _ input: SelectionInput) -> SelectionState {
        guard input.positionAccuracy <= config.maxPositionAccuracy, !input.vectors.isEmpty,
              let vector = input.vectors.first(where: { $0.place.candidate.id == placeID }) else {
            return update(input)
        }
        let reliable = Self.reliableHeading(input, config)
        let winner = Self.winner(input, reliable: reliable, config)
        trackWinner(winner.place.candidate.id, now: input.now, current: placeID)
        hold = (placeID, input.now, reliable ? input.heading : nil)
        return finish(vector, input: input, reliable: reliable)
    }

    // MARK: - Rules

    private func automatic(current cur: PlaceVector, winner: PlaceVector,
                           input: SelectionInput, reliable: Bool) -> PlaceVector {
        if winner.place.candidate.id == cur.place.candidate.id { return cur }
        let curIn = isIn(cur, half: config.keepHalfAngle, input, reliable)
        let winIn = isIn(winner, half: config.selectHalfAngle, input, reliable)
        // The current place keeps its claim while inside the keep angle, or while it is itself the fallback winner
        // (handled above: the winner differs here, so in fallback mode the claim is gone).
        let claim = curIn
        let beats: Bool
        if !claim {
            beats = true
        } else if winIn && !curIn {
            beats = true
        } else if winIn == curIn {
            beats = winner.distance < cur.distance - max(config.equalRatio * cur.distance, config.equalMetres)
        } else {
            beats = false
        }
        guard beats, let p = pending, p.id == winner.place.candidate.id,
              input.now.timeIntervalSince(p.since) >= config.dwell else { return cur }
        return winner
    }

    /// The held vector while the hold is valid; clears the hold when it is over.
    private mutating func heldVector(_ input: SelectionInput, reliable: Bool) -> PlaceVector? {
        guard let h = hold else { return nil }
        var valid = input.now.timeIntervalSince(h.since) < config.explicitHold
        if valid, reliable, let now = input.heading, let tap = h.heading,
           abs(Self.offset(heading: tap, bearing: now)) > config.explicitTurn {
            valid = false
        }
        guard valid, let v = input.vectors.first(where: { $0.place.candidate.id == h.id }) else {
            hold = nil
            return nil
        }
        return v
    }

    private mutating func trackWinner(_ id: String, now: Date, current: String?) {
        if id == current {
            pending = nil
        } else if pending?.id != id {
            pending = (id, now)
        }
    }

    private mutating func finish(_ chosen: PlaceVector, input: SelectionInput, reliable: Bool) -> SelectionState {
        let id = chosen.place.candidate.id
        currentID = id
        if hold?.id != id { hold = nil }
        if pending?.id == id { pending = nil }
        var relative: Double?
        if reliable, let heading = input.heading,
           chosen.distance > config.directionDistanceFactor * input.positionAccuracy {
            relative = Self.offset(heading: heading, bearing: chosen.bearing)
        }
        state = .selected(SelectedPlace(vector: chosen, relative: relative,
                                        suggestPhoto: Self.cluster(input.vectors, config)))
        return state
    }

    private mutating func reset() {
        currentID = nil
        pending = nil
        hold = nil
    }

    // MARK: - Helpers

    private static func reliableHeading(_ input: SelectionInput, _ c: PlaceSelectionConfig) -> Bool {
        guard let h = input.heading, h.isFinite, let a = input.headingAccuracy, a >= 0, a <= c.maxHeadingAccuracy else {
            return false
        }
        return true
    }

    private func isIn(_ v: PlaceVector, half: Double, _ input: SelectionInput, _ reliable: Bool) -> Bool {
        guard reliable, let h = input.heading else { return false }
        return abs(Self.offset(heading: h, bearing: v.bearing)) <= half
    }

    private static func nearest(_ vs: [PlaceVector]) -> PlaceVector? {
        vs.min { a, b in
            a.distance != b.distance ? a.distance < b.distance : a.place.candidate.id < b.place.candidate.id
        }
    }

    /// The nearest place inside the select angle, else the nearest overall (the fallback). `vectors` is non-empty.
    private static func winner(_ input: SelectionInput, reliable: Bool, _ c: PlaceSelectionConfig) -> PlaceVector {
        if reliable, let h = input.heading {
            let inAngle = input.vectors.filter { abs(offset(heading: h, bearing: $0.bearing)) <= c.selectHalfAngle }
            if let best = nearest(inAngle) { return best }
        }
        return nearest(input.vectors)!
    }

    /// True when the two nearest places are close to each other and both close to the owner.
    private static func cluster(_ vectors: [PlaceVector], _ c: PlaceSelectionConfig) -> Bool {
        let sorted = vectors.sorted { $0.distance < $1.distance }
        guard sorted.count >= 2 else { return false }
        let a = sorted[0], b = sorted[1]
        guard b.distance <= c.clusterReach else { return false }
        let delta = GeoMath.angularDifference(a.bearing, b.bearing)
        let spacing: Double
        if delta <= 20 {
            spacing = abs(a.distance - b.distance)
        } else {
            let r = delta * .pi / 180
            spacing = (a.distance * a.distance + b.distance * b.distance - 2 * a.distance * b.distance * cos(r))
                .squareRoot()
        }
        return spacing <= c.clusterSpacing
    }
}
