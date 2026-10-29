import Foundation
import Testing
@testable import MyGuideCore

/// Direction-based place selection (spec 6.2–6.4, 12.3).
@Suite struct PlaceSelectorTests {
    static func v(_ id: String, d: Double, b: Double) -> PlaceVector {
        let c = Candidate(id: id, name: id, coordinate: Coordinate(latitude: 59.9, longitude: 10.7), kind: "x")
        return PlaceVector(place: WalkingPlace(candidate: c, tier: .top), distance: d, bearing: b)
    }

    static func input(_ vectors: [PlaceVector], heading: Double?, hAcc: Double? = 10, pAcc: Double = 10,
                      playing: String? = nil, t: Double) -> SelectionInput {
        SelectionInput(vectors: vectors, positionAccuracy: pAcc, heading: heading, headingAccuracy: hAcc,
                       playingPlaceID: playing, now: Date(timeIntervalSince1970: t))
    }

    static func selected(_ s: SelectionState) -> SelectedPlace? {
        if case .selected(let p) = s { return p }
        return nil
    }

    // offset(heading:bearing:) = bearing − heading wrapped into (−180, 180].
    // 359 → 1: 1 − 359 = −358 → +360 = 2.   10 → 350: 350 − 10 = 340 → −360 = −20.   0 → 180: 180 (not −180).
    @Test func offsetWrapsAroundNorth() {
        #expect(PlaceSelector.offset(heading: 359, bearing: 1) == 2)
        #expect(PlaceSelector.offset(heading: 10, bearing: 350) == -20)
        #expect(PlaceSelector.offset(heading: 0, bearing: 180) == 180)
        #expect(PlaceSelector.offset(heading: 180, bearing: 0) == 180)       // −180 → +180
    }

    @Test func nearestInsideTheAngleWins() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 80, b: 10), Self.v("right", d: 30, b: 90), Self.v("back", d: 20, b: 180),
                  Self.v("left", d: 40, b: 270)]
        #expect(s.update(Self.input(vs, heading: 0, t: 0)).placeID == "front")   // only "front" is within ±30°
    }

    @Test func nearerPlaceBehindDoesNotWin() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 80, b: 0), Self.v("back", d: 20, b: 180)]
        for i in 0...10 {
            #expect(s.update(Self.input(vs, heading: 0, t: Double(i))).placeID == "front")
        }
    }

    @Test func turnSwitchesAfterDwellOnly() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 50, b: 0), Self.v("right", d: 50, b: 90)]
        #expect(s.update(Self.input(vs, heading: 0, t: 0)).placeID == "front")
        // Turn to 90 at t = 10: "right" becomes the winner at 10; 11.4 − 10 = 1.4 < 1.5, 11.5 − 10 = 1.5 ≥ 1.5.
        #expect(s.update(Self.input(vs, heading: 90, t: 10)).placeID == "front")
        #expect(s.update(Self.input(vs, heading: 90, t: 11.4)).placeID == "front")
        #expect(s.update(Self.input(vs, heading: 90, t: 11.5)).placeID == "right")
    }

    @Test func noFlickerUnderNoiseAroundNorth() {
        var s = PlaceSelector()
        let vs = [Self.v("a", d: 60, b: 2), Self.v("b", d: 62, b: 358)]
        let headings = [355.0, 5, 357, 3]
        var seen = Set<String>()
        for i in 0..<50 {                   // 0.2 s steps over 10 s
            let id = s.update(Self.input(vs, heading: headings[i % 4], t: Double(i) * 0.2)).placeID
            seen.insert(id ?? "none")
        }
        #expect(seen == ["a"])
    }

    @Test func northIsContinuous() {
        var s = PlaceSelector()
        let vs = [Self.v("n", d: 50, b: 1)]
        let p = Self.selected(s.update(Self.input(vs, heading: 359, t: 0)))
        #expect(p?.vector.place.candidate.id == "n")
        #expect(p?.relative == 2)           // 1 − 359 = −358 → +360 = 2
    }

    @Test func playingPlaceIsFrozen() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 50, b: 0), Self.v("right", d: 50, b: 90)]
        #expect(s.update(Self.input(vs, heading: 0, playing: "front", t: 0)).placeID == "front")
        var last: SelectedPlace?
        for i in 1...5 {
            last = Self.selected(s.update(Self.input(vs, heading: 90, playing: "front", t: Double(i))))
            #expect(last?.vector.place.candidate.id == "front")
        }
        // front at bearing 0, heading 90: 0 − 90 = −90.
        #expect(last?.relative == -90)
    }

    @Test func noDirectionWithoutReliableHeading() {
        var s = PlaceSelector()
        let vs = [Self.v("far", d: 80, b: 0), Self.v("near", d: 30, b: 120)]
        // Heading accuracy 30 > 25 → unreliable: nearest overall, no direction.
        let p = Self.selected(s.update(Self.input(vs, heading: 0, hAcc: 30, t: 0)))
        #expect(p?.vector.place.candidate.id == "near")
        #expect(p?.relative == nil)
        var s2 = PlaceSelector()
        let q = Self.selected(s2.update(Self.input(vs, heading: nil, hAcc: nil, t: 0)))
        #expect(q?.vector.place.candidate.id == "near")
        #expect(q?.relative == nil)
        var s3 = PlaceSelector()
        #expect(Self.selected(s3.update(Self.input(vs, heading: .nan, hAcc: 5, t: 0)))?.relative == nil)
        // Accuracy exactly 25 is still reliable (≤): "far" at bearing 0 is in angle, so it wins over "near".
        var s4 = PlaceSelector()
        #expect(s4.update(Self.input(vs, heading: 0, hAcc: 25, t: 0)).placeID == "far")
    }

    @Test func positionAccuracyGate() {
        var s = PlaceSelector()
        let a = [Self.v("a", d: 50, b: 0)]
        #expect(s.update(Self.input(a, heading: 0, t: 0)).placeID == "a")
        #expect(s.update(Self.input(a, heading: 0, pAcc: 80, t: 1)) == .uncertainPosition)
        #expect(s.update(Self.input(a, heading: 0, pAcc: 50, t: 2)).placeID == "a")     // 50 is not > 50
        #expect(s.update(Self.input(a, heading: 0, pAcc: 50.1, t: 3)) == .uncertainPosition)
        // Back to a good fix: a different winner is taken at once, no dwell.
        let b = [Self.v("b", d: 50, b: 0)]
        #expect(s.update(Self.input(b, heading: 0, pAcc: 10, t: 4)).placeID == "b")
    }

    @Test func directionNeedsDistanceAboveTwiceAccuracy() {
        var s = PlaceSelector()
        // pAcc 20: 40 > 2·20 = 40 is false → nil; 41 > 40 → set (bearing 10, heading 0: 10).
        #expect(Self.selected(s.update(Self.input([Self.v("p", d: 40, b: 10)], heading: 0, pAcc: 20, t: 0)))?.relative == nil)
        #expect(Self.selected(s.update(Self.input([Self.v("p", d: 41, b: 10)], heading: 0, pAcc: 20, t: 1)))?.relative == 10)
    }

    @Test func equalDistanceKeepsCurrent() {
        // current 100 m in angle; threshold max(0.15·100 = 15, 10) = 15 → challenger needs < 85.
        var s = PlaceSelector()
        let cur = Self.v("cur", d: 100, b: 0)
        #expect(s.update(Self.input([cur], heading: 0, t: 0)).placeID == "cur")
        let at86 = [cur, Self.v("ch", d: 86, b: 10)]
        for i in 1...10 { #expect(s.update(Self.input(at86, heading: 0, t: Double(i))).placeID == "cur") }
        // Fresh scene: challenger first seen at 84 m (< 85) at t = 20 → switches at 21.5, not at 21.4.
        var s2 = PlaceSelector()
        #expect(s2.update(Self.input([cur], heading: 0, t: 0)).placeID == "cur")
        let at84 = [cur, Self.v("ch", d: 84, b: 10)]
        #expect(s2.update(Self.input(at84, heading: 0, t: 20)).placeID == "cur")
        #expect(s2.update(Self.input(at84, heading: 0, t: 21.4)).placeID == "cur")
        #expect(s2.update(Self.input(at84, heading: 0, t: 21.5)).placeID == "ch")
        // current 40 m: threshold max(0.15·40 = 6, 10) = 10 → needs < 30: 31 kept, 29 switches.
        let near = Self.v("cur", d: 40, b: 0)
        var s3 = PlaceSelector()
        #expect(s3.update(Self.input([near], heading: 0, t: 0)).placeID == "cur")
        for i in 1...5 {
            #expect(s3.update(Self.input([near, Self.v("ch", d: 31, b: 10)], heading: 0, t: Double(i))).placeID == "cur")
        }
        var s4 = PlaceSelector()
        #expect(s4.update(Self.input([near], heading: 0, t: 0)).placeID == "cur")
        let at29 = [near, Self.v("ch", d: 29, b: 10)]
        #expect(s4.update(Self.input(at29, heading: 0, t: 1)).placeID == "cur")
        #expect(s4.update(Self.input(at29, heading: 0, t: 2.5)).placeID == "ch")
    }

    @Test func fallbackWhenNothingInAngle() {
        var s = PlaceSelector()
        let vs = [Self.v("a", d: 50, b: 120), Self.v("b", d: 30, b: 200)]
        let p = Self.selected(s.update(Self.input(vs, heading: 0, t: 0)))
        #expect(p?.vector.place.candidate.id == "b")
        #expect(p?.relative == -160)        // 200 − 0 = 200 → −360 = −160
    }

    @Test func inAngleBeatsFallbackAfterDwell() {
        var s = PlaceSelector()
        let side = Self.v("side", d: 50, b: 120)
        #expect(s.update(Self.input([side], heading: 0, t: 0)).placeID == "side")
        let both = [side, Self.v("ahead", d: 80, b: 10)]
        #expect(s.update(Self.input(both, heading: 0, t: 5)).placeID == "side")
        #expect(s.update(Self.input(both, heading: 0, t: 6.4)).placeID == "side")
        #expect(s.update(Self.input(both, heading: 0, t: 6.5)).placeID == "ahead")
    }

    @Test func leavingKeepAngleKeepsCardUntilChallengerDwells() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 50, b: 0), Self.v("right", d: 70, b: 60)]
        #expect(s.update(Self.input(vs, heading: 0, t: 0)).placeID == "front")
        // Heading 45: front offset −45 (outside 40), right offset 15 (inside 30) → right wins from t = 10.
        let p = Self.selected(s.update(Self.input(vs, heading: 45, t: 10)))
        #expect(p?.vector.place.candidate.id == "front")
        #expect(p?.relative == -45)         // 0 − 45
        #expect(s.update(Self.input(vs, heading: 45, t: 11.4)).placeID == "front")
        #expect(s.update(Self.input(vs, heading: 45, t: 11.5)).placeID == "right")
    }

    @Test func keepAngleIsWiderThanSelectAngle() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 50, b: 0), Self.v("other", d: 70, b: 80)]
        #expect(s.update(Self.input(vs, heading: 0, t: 0)).placeID == "front")
        // Heading 35 (front offset −35): outside select 30 but inside keep 40 → kept; "other" offset 45 is not in angle.
        for i in 1...10 { #expect(s.update(Self.input(vs, heading: 35, t: Double(i))).placeID == "front") }
    }

    @Test func explicitChoiceHoldsTwentySecondsOrSixtyDegrees() {
        let vs = [Self.v("front", d: 30, b: 0), Self.v("back", d: 60, b: 180)]
        var s = PlaceSelector()
        #expect(s.update(Self.input(vs, heading: 0, t: 0)).placeID == "front")
        #expect(s.choose(placeID: "back", Self.input(vs, heading: 0, t: 0)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 0, t: 19)).placeID == "back")
        // The hold ends at 20 − 0 = 20 (not < 20); the dwell then starts afresh: 21.4 − 20 < 1.5 ≤ 21.5 − 20.
        #expect(s.update(Self.input(vs, heading: 0, t: 20)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 0, t: 21.4)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 0, t: 21.5)).placeID == "front")

        // Turning exactly 60° keeps the hold; 61° ends it.
        var s2 = PlaceSelector()
        _ = s2.update(Self.input(vs, heading: 0, t: 0))
        _ = s2.choose(placeID: "back", Self.input(vs, heading: 0, t: 0))
        #expect(s2.update(Self.input(vs, heading: 60, t: 4)).placeID == "back")
        // Hold ends at 61°; back is outside the keep angle and front (30 m) beats 60 − max(9, 10) = 50: dwell from t = 5.
        #expect(s2.update(Self.input(vs, heading: 61, t: 5)).placeID == "back")
        #expect(s2.update(Self.input(vs, heading: 61, t: 6.4)).placeID == "back")
        #expect(s2.update(Self.input(vs, heading: 61, t: 6.5)).placeID == "front")
        // Turning the other way: offset(0, 300) = −60 keeps, 299 → −61 ends.
        var s3 = PlaceSelector()
        _ = s3.update(Self.input(vs, heading: 0, t: 0))
        _ = s3.choose(placeID: "back", Self.input(vs, heading: 0, t: 0))
        #expect(s3.update(Self.input(vs, heading: 300, t: 4)).placeID == "back")
        #expect(s3.update(Self.input(vs, heading: 299, t: 5)).placeID == "back")
        #expect(s3.update(Self.input(vs, heading: 299, t: 6.5)).placeID == "front")
    }

    @Test func explicitChoiceOfUnknownPlaceFallsBackToAutomatic() {
        var s = PlaceSelector()
        let vs = [Self.v("front", d: 30, b: 0)]
        #expect(s.choose(placeID: "ghost", Self.input(vs, heading: 0, t: 0)).placeID == "front")
    }

    @Test func selectedPlaceVanishesFromList() {
        var s = PlaceSelector()
        let a = Self.v("a", d: 100, b: 0)
        let b = Self.v("b", d: 60, b: 10)
        // First: only a in the list.
        #expect(s.update(Self.input([a], heading: 0, t: 0)).placeID == "a")
        // a disappears: b wins at once.
        #expect(s.update(Self.input([b], heading: 0, t: 0.1)).placeID == "b")
        // Same id with a new distance: kept, vector updated. Current 55 → threshold max(8.25, 10) = 10 → a rival
        // must be < 45; c at 50 never qualifies, however long it stays.
        let moved = Self.v("b", d: 55, b: 10)
        let withC = [moved, Self.v("c", d: 50, b: 5)]
        for t in [0.2, 1.0, 1.7, 3.0] {
            let p = Self.selected(s.update(Self.input(withC, heading: 0, t: t)))
            #expect(p?.vector.place.candidate.id == "b")
            #expect(p?.vector.distance == 55)
        }
        // c at 44 < 45 qualifies from t = 4: still b at 5.4, c at 5.5.
        let closer = [moved, Self.v("c", d: 44, b: 5)]
        #expect(s.update(Self.input(closer, heading: 0, t: 4)).placeID == "b")
        #expect(s.update(Self.input(closer, heading: 0, t: 5.4)).placeID == "b")
        #expect(s.update(Self.input(closer, heading: 0, t: 5.5)).placeID == "c")
    }

    @Test func emptyListIsNoPlacesAndRecovers() {
        var s = PlaceSelector()
        #expect(s.update(Self.input([Self.v("a", d: 50, b: 0)], heading: 0, t: 0)).placeID == "a")
        #expect(s.update(Self.input([], heading: 0, t: 1)) == .noPlaces)
        #expect(s.state == .noPlaces)
        #expect(s.update(Self.input([Self.v("z", d: 50, b: 0)], heading: 0, t: 2)).placeID == "z")
    }

    @Test func photoSuggestedForTightCluster() {
        var s = PlaceSelector()
        // d 30 and 38, bearings 10 and 15 (5° ≤ 20° → spacing |30 − 38| = 8 ≤ 15), both ≤ 40 → true.
        let tight = [Self.v("a", d: 30, b: 10), Self.v("b", d: 38, b: 15)]
        #expect(Self.selected(s.update(Self.input(tight, heading: 0, t: 0)))?.suggestPhoto == true)
        // Bearings 0 and 90: √(30² + 38² − 2·30·38·cos 90°) = √(900 + 1444) = 48.4 > 15 → false.
        let wide = [Self.v("a", d: 30, b: 0), Self.v("b", d: 38, b: 90)]
        var s2 = PlaceSelector()
        #expect(Self.selected(s2.update(Self.input(wide, heading: 0, t: 0)))?.suggestPhoto == false)
        // Close to each other but too far from the owner: 50 and 55, 5° apart → spacing 5, but 55 > 40 → false.
        let far = [Self.v("a", d: 50, b: 0), Self.v("b", d: 55, b: 5)]
        var s3 = PlaceSelector()
        #expect(Self.selected(s3.update(Self.input(far, heading: 0, t: 0)))?.suggestPhoto == false)
        // 40 m both (boundary) at 0° and 30° apart: √(1600 + 1600 − 3200·cos 30°) = √(3200 − 2771.3) = 20.7 > 15 → false;
        // at 20° apart (≤ 20 → |40 − 40| = 0) → true.
        var s4 = PlaceSelector()
        let apart30 = [Self.v("a", d: 40, b: 0), Self.v("b", d: 40, b: 30)]
        #expect(Self.selected(s4.update(Self.input(apart30, heading: 0, t: 0)))?.suggestPhoto == false)
        var s5 = PlaceSelector()
        let apart20 = [Self.v("a", d: 40, b: 0), Self.v("b", d: 40, b: 20)]
        #expect(Self.selected(s5.update(Self.input(apart20, heading: 0, t: 0)))?.suggestPhoto == true)
        // A single place never suggests a photo.
        var s6 = PlaceSelector()
        #expect(Self.selected(s6.update(Self.input([Self.v("a", d: 10, b: 0)], heading: 0, t: 0)))?.suggestPhoto == false)
    }

    @Test func vectorsFromPositionUseGeoMath() {
        let here = Coordinate(latitude: 59.9, longitude: 10.7)
        let north = Coordinate(latitude: 59.91, longitude: 10.7)
        let c = Candidate(id: "n", name: "n", coordinate: north, kind: "x")
        let vs = PlaceVector.from(position: here, places: [WalkingPlace(candidate: c, tier: .good)])
        #expect(vs.count == 1)
        // 0.01° of latitude = 0.01 · π/180 · 6 371 000 ≈ 1111.95 m, due north.
        #expect(abs(vs[0].distance - 1111.95) < 0.5)
        #expect(abs(vs[0].bearing) < 0.001)
    }

    @Test func fallbackModeAppliesTheDistanceRule() {
        // Unreliable heading → both fallback. Current 50 m: threshold max(7.5, 10) = 10 → rival must be < 40.
        let cur = Self.v("cur", d: 50, b: 0)
        var s = PlaceSelector()
        #expect(s.update(Self.input([cur], heading: 0, hAcc: 30, t: 0)).placeID == "cur")
        for i in 1...10 {
            let vs = [cur, Self.v("rival", d: i == 10 ? 40 : 49, b: 90)]       // 40 is not < 40
            #expect(s.update(Self.input(vs, heading: 0, hAcc: 30, t: Double(i))).placeID == "cur")
        }
        let at39 = [cur, Self.v("rival", d: 39, b: 90)]
        #expect(s.update(Self.input(at39, heading: 0, hAcc: 30, t: 20)).placeID == "cur")
        #expect(s.update(Self.input(at39, heading: 0, hAcc: 30, t: 21.4)).placeID == "cur")
        #expect(s.update(Self.input(at39, heading: 0, hAcc: 30, t: 21.5)).placeID == "rival")
    }

    @Test func dwellCountsOnlyQualifyingTimeLeavingKeepAngle() {
        // Current at bearing 38 (heading 0: inside keep 40, outside select 30); rival at 0, 95 m vs 100 m:
        // 95 < 100 − 15 = 85 is false → no qualification for 10 s.
        var s = PlaceSelector()
        let vs = [Self.v("cur", d: 100, b: 38), Self.v("rival", d: 95, b: 0)]
        #expect(s.update(Self.input([vs[0]], heading: 0, t: 0)).placeID == "cur")
        for i in 1...10 { #expect(s.update(Self.input(vs, heading: 0, t: Double(i))).placeID == "cur") }
        // Heading 357: current offset 38 − 357 = −319 → 41 (outside keep), rival offset 3: rule 7 from t = 11.
        #expect(s.update(Self.input(vs, heading: 357, t: 11)).placeID == "cur")
        #expect(s.update(Self.input(vs, heading: 357, t: 12.4)).placeID == "cur")
        #expect(s.update(Self.input(vs, heading: 357, t: 12.5)).placeID == "rival")
    }

    @Test func dwellCountsOnlyQualifyingTimeDistance() {
        var s = PlaceSelector()
        let cur = Self.v("cur", d: 100, b: 0)
        #expect(s.update(Self.input([cur], heading: 0, t: 0)).placeID == "cur")
        for i in 1...10 {
            #expect(s.update(Self.input([cur, Self.v("ch", d: 86, b: 10)], heading: 0, t: Double(i))).placeID == "cur")
        }
        let at84 = [cur, Self.v("ch", d: 84, b: 10)]                      // 84 < 85 qualifies from t = 11
        #expect(s.update(Self.input(at84, heading: 0, t: 11)).placeID == "cur")
        #expect(s.update(Self.input(at84, heading: 0, t: 12.4)).placeID == "cur")
        #expect(s.update(Self.input(at84, heading: 0, t: 12.5)).placeID == "ch")
    }

    @Test func tapDuringPlaybackOverridesFreezeThenFreezeReturns() {
        let vs = [Self.v("front", d: 30, b: 0), Self.v("back", d: 60, b: 180)]
        var s = PlaceSelector()
        #expect(s.update(Self.input(vs, heading: 0, playing: "front", t: 0)).placeID == "front")
        #expect(s.choose(placeID: "back", Self.input(vs, heading: 0, playing: "front", t: 1)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 0, playing: "front", t: 20.9)).placeID == "back")   // 19.9 < 20
        #expect(s.update(Self.input(vs, heading: 0, playing: "front", t: 21)).placeID == "front")    // hold over
    }

    @Test func firstReliableHeadingDuringHoldIsTheTurnReference() {
        let vs = [Self.v("front", d: 30, b: 0), Self.v("back", d: 60, b: 180)]
        var s = PlaceSelector()
        _ = s.update(Self.input(vs, heading: 0, t: 0))
        // Unreliable at the tap (hAcc 40 > 25).
        #expect(s.choose(placeID: "back", Self.input(vs, heading: 0, hAcc: 40, t: 0)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 0, t: 1)).placeID == "back")      // reference = 0
        #expect(s.update(Self.input(vs, heading: 60, t: 2)).placeID == "back")     // 60 is not > 60
        #expect(s.update(Self.input(vs, heading: 61, t: 3)).placeID == "back")     // hold over, dwell starts
        #expect(s.update(Self.input(vs, heading: 61, t: 4.4)).placeID == "back")
        #expect(s.update(Self.input(vs, heading: 61, t: 4.5)).placeID == "front")
    }

    @Test func noPlacesState() { #expect(PlaceSelector().state == .noPlaces) }
}

extension SelectionState {
    var placeID: String? {
        if case .selected(let p) = self { return p.vector.place.candidate.id }
        return nil
    }
}
