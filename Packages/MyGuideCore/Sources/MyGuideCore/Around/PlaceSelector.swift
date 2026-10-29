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
    public var clusterSpacing = 15.0       // two nearest within this of each other …
    public var clusterReach = 40.0         // … and both within this of the owner → suggest a photo
    public init() {}

    /// Spec 6.4: a heading is reliable when it is finite, its accuracy is known, at most `maxHeadingAccuracy`, and the
    /// position's accuracy is known and at most `maxPositionAccuracy`.
    public func headingIsReliable(heading: Double?, headingAccuracy: Double?, positionAccuracy: Double?) -> Bool {
        guard let heading, heading.isFinite,
              let headingAccuracy, headingAccuracy >= 0, headingAccuracy <= maxHeadingAccuracy,
              let positionAccuracy, positionAccuracy >= 0, positionAccuracy <= maxPositionAccuracy else { return false }
        return true
    }
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
    /// The challenger that has been beating the current place, and the instant it first did so (qualifying time).
    private var pending: (id: String, since: Date)?
    /// The place the owner tapped, held against automatic changes until `resumeAutomatic()` (spec 16.1).
    private var heldID: String?

    public init(config: PlaceSelectionConfig = .init()) {
        self.config = config
    }

    /// True while a tapped place is held.
    public var isHolding: Bool { heldID != nil }

    /// The owner tapped locate (spec 16.1): automatic selection resumes. The held place stays selected until a
    /// challenger has won for a full dwell (or a playing place freezes in).
    /// Without a hold nothing changes: a challenger already mid-dwell keeps its time.
    public mutating func resumeAutomatic() {
        guard heldID != nil else { return }
        heldID = nil
        pending = nil
    }

    /// Offset of `bearing` from `heading`, wrapped into (−180, 180]: `GeoMath.signedOffset`.
    public static func offset(heading: Double, bearing: Double) -> Double {
        GeoMath.signedOffset(from: heading, to: bearing)
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

        let chosen: PlaceVector
        if let held = heldVector(input) {
            pending = nil                 // the dwell starts afresh when the hold ends
            chosen = held
        } else if let id = input.playingPlaceID, let playing = input.vectors.first(where: { $0.place.candidate.id == id }) {
            pending = nil
            chosen = playing
        } else if let cur = currentID.flatMap({ id in input.vectors.first { $0.place.candidate.id == id } }) {
            chosen = automatic(current: cur, winner: winner, input: input, reliable: reliable)
        } else {
            pending = nil
            chosen = winner               // first selection, or the current place vanished
        }
        return finish(chosen, input: input, reliable: reliable)
    }

    /// Selects `placeID` at once. `hold` (a tap) holds it against automatic changes, also against a playing place,
    /// until `resumeAutomatic()` or until it leaves the list (spec 16.1). Without `hold` (a buzz in the foreground,
    /// spec 12.2) it is only the current place: the normal rules and dwell apply from the next update, and any
    /// earlier hold ends. With a poor fix, no places or a place not in the list the call is an ordinary `update`, and
    /// an earlier hold stays.
    @discardableResult
    public mutating func choose(placeID: String, hold: Bool = true, _ input: SelectionInput) -> SelectionState {
        guard input.positionAccuracy <= config.maxPositionAccuracy, !input.vectors.isEmpty,
              let vector = input.vectors.first(where: { $0.place.candidate.id == placeID }) else {
            return update(input)
        }
        let reliable = Self.reliableHeading(input, config)
        pending = nil
        heldID = hold ? placeID : nil
        return finish(vector, input: input, reliable: reliable)
    }

    // MARK: - Rules

    /// Whether `winner` may replace `cur`, and if so whether it has done so for a full dwell. The dwell counts
    /// continuous qualifying time: `pending` is cleared whenever the winner does not beat the current place.
    private mutating func automatic(current cur: PlaceVector, winner: PlaceVector,
                                    input: SelectionInput, reliable: Bool) -> PlaceVector {
        let winID = winner.place.candidate.id
        let curIn = isIn(cur, half: config.keepHalfAngle, input, reliable)
        let winIn = isIn(winner, half: config.selectHalfAngle, input, reliable)
        let nearer = winner.distance < cur.distance - max(config.equalRatio * cur.distance, config.equalMetres)
        let beats: Bool
        if winID == cur.place.candidate.id {
            beats = false
        } else if winIn && !curIn {
            beats = true                  // the claim is lost: the distance rule is bypassed
        } else if winIn == curIn {
            beats = nearer                // both in the angle, or both fallback (spec 12.3)
        } else {
            beats = false                 // the current place is in the angle, the winner is only a fallback
        }
        guard beats else {
            pending = nil
            return cur
        }
        if pending?.id != winID { pending = (winID, input.now) }
        guard let since = pending?.since, input.now.timeIntervalSince(since) >= config.dwell else { return cur }
        return winner
    }

    /// The held place's vector; a list without it ends the hold.
    private mutating func heldVector(_ input: SelectionInput) -> PlaceVector? {
        guard let id = heldID else { return nil }
        guard let v = input.vectors.first(where: { $0.place.candidate.id == id }) else {
            heldID = nil
            return nil
        }
        return v
    }

    private mutating func finish(_ chosen: PlaceVector, input: SelectionInput, reliable: Bool) -> SelectionState {
        let id = chosen.place.candidate.id
        currentID = id
        if heldID != id { heldID = nil }
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

    /// A poor fix or an empty list: no current place. A hold survives it (spec 16.1: only locate ends it).
    private mutating func reset() {
        currentID = nil
        pending = nil
    }

    // MARK: - Helpers

    /// `update` and `choose` call this only after the position accuracy passed, so this is the heading part of 6.4.
    private static func reliableHeading(_ input: SelectionInput, _ c: PlaceSelectionConfig) -> Bool {
        c.headingIsReliable(heading: input.heading, headingAccuracy: input.headingAccuracy,
                            positionAccuracy: input.positionAccuracy)
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
        let sorted = vectors.sorted {
            $0.distance != $1.distance ? $0.distance < $1.distance : $0.place.candidate.id < $1.place.candidate.id
        }
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
