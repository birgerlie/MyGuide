import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PlaceFeedTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let castle = WalkingPlace(candidate: Candidate(id: "c", name: "C", coordinate: .at(), kind: "x"), tier: .top)

    @Test func firstFetchThenDistance() {
        var f = PlaceFeed()
        #expect(f.shouldFetch(at: .at(), now: Self.t0))
        f.fetchStarted(now: Self.t0)
        #expect(f.isFetching)
        #expect(!f.shouldFetch(at: .at(north: 900), now: Self.t0 + 1))        // in flight
        f.fetchSucceeded([], at: .at(), now: Self.t0 + 2)
        #expect(!f.isFetching)
        // 249 m from the centre is below the 250 m threshold (no fetch); 250 m reaches it (fetch).
        #expect(!f.shouldFetch(at: .at(north: 249), now: Self.t0 + 3))
        #expect(f.shouldFetch(at: .at(north: 250), now: Self.t0 + 3))
    }

    @Test func distanceIsMeasuredInAnyDirection() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([], at: .at(north: 100, east: 100), now: Self.t0)
        // From (100, 100): (100, -140) is 240 m west, (100, -160) is 260 m west.
        #expect(!f.shouldFetch(at: .at(north: 100, east: -140), now: Self.t0 + 1))
        #expect(f.shouldFetch(at: .at(north: 100, east: -160), now: Self.t0 + 1))
    }

    @Test func successStoresPlacesAndMovesCentre() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0)
        #expect(f.places == [Self.castle])
        f.fetchStarted(now: Self.t0 + 10); f.fetchSucceeded([], at: .at(north: 400), now: Self.t0 + 10)
        #expect(f.places.isEmpty)
        // The centre moved to 400 m north: 0 m is 400 m away (fetch), 300 m is 100 m away (no fetch).
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 11))
        #expect(!f.shouldFetch(at: .at(north: 300), now: Self.t0 + 11))
    }

    @Test func failureKeepsPlacesAndBacksOff() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0)
        f.fetchStarted(now: Self.t0 + 100); f.fetchFailed(now: Self.t0 + 100)
        #expect(!f.isFetching)
        #expect(f.places == [Self.castle])
        // Failure at t0+100: blocked until t0+160 (100 + 60).
        #expect(!f.shouldFetch(at: .at(north: 400), now: Self.t0 + 159))
        #expect(f.shouldFetch(at: .at(north: 400), now: Self.t0 + 160))
    }

    @Test func failureBeforeAnySuccessRetriesAfterSixtySeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
    }

    @Test func successClearsTheBackoff() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        f.fetchStarted(now: Self.t0 + 60); f.fetchSucceeded([], at: .at(), now: Self.t0 + 61)
        // Moved 300 m, only 2 s after the success: the old failure no longer blocks.
        #expect(f.shouldFetch(at: .at(north: 300), now: Self.t0 + 63))
    }

    @Test func withinRangeNeverRefetchesEvenAfterBackoff() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([], at: .at(), now: Self.t0)
        f.fetchStarted(now: Self.t0 + 5); f.fetchFailed(now: Self.t0 + 5)
        // Still 100 m from the centre: nothing to refetch even after the backoff.
        #expect(!f.shouldFetch(at: .at(north: 100), now: Self.t0 + 500))
    }

    @Test func cancelledFetchCanRestartAtOnce() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchCancelled()
        #expect(!f.isFetching)
        #expect(f.shouldFetch(at: .at(), now: Self.t0))
    }

    @Test func cancelledFetchAfterFailureStillHonoursTheBackoff() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        f.fetchStarted(now: Self.t0 + 60); f.fetchCancelled()
        // Cancelling does not touch the earlier failure time (t0 + 60 > failure + 60 is already true).
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 30))
    }
}
