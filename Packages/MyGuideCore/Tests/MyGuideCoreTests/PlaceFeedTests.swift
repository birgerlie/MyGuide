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

    @Test func failureWithNoPlacesRetriesAfterFifteenSeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        // No places (spec 19.6): failure at t0 blocks until t0 + 15; 14.9 < 15 blocked, 15 ≥ 15 allowed.
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 14.9))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 15))
    }

    @Test func emptyFeedBacksOffFifteenThirtySixty() {
        var f = PlaceFeed()
        // 1st failure at t0: 15 · 2⁰ = 15 s → blocked at t0 + 14.9, allowed at t0 + 15.
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 14.9))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 15))
        // 2nd at t0 + 15: 15 · 2¹ = 30 s → blocked at t0 + 44.9 (15 + 29.9), allowed at t0 + 45 (15 + 30).
        f.fetchStarted(now: Self.t0 + 15); f.fetchFailed(now: Self.t0 + 15)
        #expect(f.failureRetryInterval == 30)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 44.9))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 45))
        // 3rd at t0 + 45: 15 · 2² = 60 s → blocked at t0 + 104.9 (45 + 59.9), allowed at t0 + 105 (45 + 60).
        f.fetchStarted(now: Self.t0 + 45); f.fetchFailed(now: Self.t0 + 45)
        #expect(f.failureRetryInterval == 60)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 104.9))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 105))
        // 4th and later: capped at 60 (15 · 2³ = 120 > 60).
        f.fetchStarted(now: Self.t0 + 105); f.fetchFailed(now: Self.t0 + 105)
        #expect(f.failureRetryInterval == 60)
        f.fetchStarted(now: Self.t0 + 165); f.fetchFailed(now: Self.t0 + 165)
        #expect(f.failureRetryInterval == 60)
    }

    @Test func successResetsTheEmptyFeedBackoff() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        f.fetchStarted(now: Self.t0 + 15); f.fetchFailed(now: Self.t0 + 15)
        #expect(f.failureRetryInterval == 30)
        // An empty list comes back: the count resets, and the next failure waits 15 s again.
        f.fetchStarted(now: Self.t0 + 45); f.fetchSucceeded([], at: .at(), now: Self.t0 + 45)
        #expect(f.failureRetryInterval == 15)
        f.fetchStarted(now: Self.t0 + 50); f.fetchFailed(now: Self.t0 + 50)
        // 400 m away, failure at t0 + 50: blocked at t0 + 64.9, allowed at t0 + 65 (50 + 15).
        #expect(!f.shouldFetch(at: .at(north: 400), now: Self.t0 + 64.9))
        #expect(f.shouldFetch(at: .at(north: 400), now: Self.t0 + 65))
    }

    @Test func cancelledFetchesDoNotCountAsFailures() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        f.fetchStarted(now: Self.t0 + 15); f.fetchCancelled()
        // Still the first failure: 15 s.
        #expect(f.failureRetryInterval == 15)
    }

    @Test func failureAfterAnEmptyListRetriesAfterFifteenSeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([], at: .at(), now: Self.t0)
        // An empty list is no places too: failure at t0 + 100, 400 m away, blocked until t0 + 115 (100 + 15).
        f.fetchStarted(now: Self.t0 + 100); f.fetchFailed(now: Self.t0 + 100)
        #expect(!f.shouldFetch(at: .at(north: 400), now: Self.t0 + 114.9))
        #expect(f.shouldFetch(at: .at(north: 400), now: Self.t0 + 115))
    }

    @Test func failureWithPlacesRetriesAfterSixtySeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0)
        // Places kept: failure at t0, 400 m away; 59.9 < 60 blocked, 60 ≥ 60 allowed (not the 15 s of an empty feed).
        f.fetchStarted(now: Self.t0); f.fetchFailed(now: Self.t0)
        #expect(!f.shouldFetch(at: .at(north: 400), now: Self.t0 + 59.9))
        #expect(f.shouldFetch(at: .at(north: 400), now: Self.t0 + 60))
    }

    @Test func retryIntervals() {
        #expect(PlaceFeed.retryInterval == 60)
        #expect(PlaceFeed.emptyRetryInterval == 15)
        // As things stand: no places 15, stale places 15, fetched places 60, an empty fetched list 15.
        var f = PlaceFeed()
        #expect(f.failureRetryInterval == 15)
        f.fetchStarted(now: Self.t0)
        f.offerStaleList([Self.castle])
        #expect(f.failureRetryInterval == 15)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0)
        #expect(f.failureRetryInterval == 60)
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([], at: .at(), now: Self.t0)
        #expect(f.failureRetryInterval == 15)
    }

    // MARK: - Stale list at start (spec 19.6)

    @Test func staleListFillsAnEmptyFeedWithoutCountingAsFetched() {
        var f = PlaceFeed()
        #expect(f.wantsStaleList)
        f.fetchStarted(now: Self.t0)
        let taken1 = f.offerStaleList([Self.castle])
        #expect(taken1)
        #expect(f.places == [Self.castle])
        #expect(f.placesAreStale)
        // The fetch it was taken during still runs; the offer is used up.
        #expect(f.isFetching)
        #expect(!f.wantsStaleList)
        // Cancelled: no centre was set by the stale list, so the next fix fetches at once, even at the same spot.
        f.fetchCancelled()
        #expect(f.places == [Self.castle])
        #expect(f.shouldFetch(at: .at(), now: Self.t0))
    }

    @Test func staleListIsReplacedByTheFetch() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.offerStaleList([Self.castle])
        let fresh = WalkingPlace(candidate: Candidate(id: "p", name: "P", coordinate: .at(north: 40), kind: "x"), tier: .good)
        f.fetchSucceeded([fresh], at: .at(), now: Self.t0 + 3)
        #expect(f.places == [fresh])
        #expect(!f.placesAreStale)
        // Now a real centre: 249 m away no fetch, 250 m a fetch.
        #expect(!f.shouldFetch(at: .at(north: 249), now: Self.t0 + 4))
        #expect(f.shouldFetch(at: .at(north: 250), now: Self.t0 + 4))
    }

    @Test func staleListIsReplacedEvenByAnEmptyFetch() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.offerStaleList([Self.castle])
        f.fetchSucceeded([], at: .at(), now: Self.t0 + 3)
        #expect(f.places.isEmpty)
        #expect(!f.placesAreStale)
        #expect(!f.wantsStaleList)
    }

    @Test func failureWithOnlyStalePlacesRetriesAfterFifteenSeconds() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.offerStaleList([Self.castle])
        f.fetchFailed(now: Self.t0 + 8)
        // Stale places are kept but are not the walk's places yet: failure at t0 + 8 blocks until t0 + 23 (8 + 15).
        #expect(f.places == [Self.castle])
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 22.9))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 23))
    }

    @Test func emptyStaleListIsNotTakenButUsesUpTheOffer() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        let taken2 = f.offerStaleList([])
        #expect(!taken2)
        #expect(f.places.isEmpty)
        #expect(!f.placesAreStale)
        #expect(!f.wantsStaleList)
    }

    @Test func staleListIsOfferedOnlyOnce() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        let taken3 = f.offerStaleList([Self.castle])
        #expect(taken3)
        let other = WalkingPlace(candidate: Candidate(id: "o", name: "O", coordinate: .at(), kind: "x"), tier: .good)
        let taken4 = f.offerStaleList([other])
        #expect(!taken4)
        #expect(f.places == [Self.castle])
    }

    @Test func claimedStaleListIsTakenLater() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        let claimed = f.claimStaleList()
        #expect(claimed)
        // Claimed: no second claim while its facts are looked up.
        #expect(!f.wantsStaleList)
        let again = f.claimStaleList()
        #expect(!again)
        let taken = f.takeStaleList([Self.castle])
        #expect(taken)
        #expect(f.places == [Self.castle] && f.placesAreStale)
    }

    @Test func claimedStaleListIsNotTakenOnceTheFetchCameBack() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        _ = f.claimStaleList()
        let fresh = WalkingPlace(candidate: Candidate(id: "p", name: "P", coordinate: .at(north: 40), kind: "x"), tier: .good)
        f.fetchSucceeded([fresh], at: .at(), now: Self.t0 + 1)
        let taken = f.takeStaleList([Self.castle])
        #expect(!taken)
        #expect(f.places == [fresh] && !f.placesAreStale)
        // An empty fresh list also wins: it set a centre.
        var g = PlaceFeed()
        g.fetchStarted(now: Self.t0)
        _ = g.claimStaleList()
        g.fetchSucceeded([], at: .at(), now: Self.t0 + 1)
        let takenEmpty = g.takeStaleList([Self.castle])
        #expect(!takenEmpty)
        #expect(g.places.isEmpty)
    }

    @Test func claimedStaleListIsStillTakenAfterAFailedFetch() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        _ = f.claimStaleList()
        f.fetchFailed(now: Self.t0 + 1)
        let taken = f.takeStaleList([Self.castle])
        #expect(taken)
        #expect(f.places == [Self.castle])
    }

    @Test func staleListIsNotTakenWithoutAClaim() {
        var f = PlaceFeed()
        let taken = f.takeStaleList([Self.castle])
        #expect(!taken)
        #expect(f.places.isEmpty)
    }

    @Test func staleListIsNotWantedOnceAFetchHasSucceeded() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0); f.fetchSucceeded([], at: .at(), now: Self.t0)
        // A fetch came back (empty): its result stands, a stored list must not replace it.
        #expect(!f.wantsStaleList)
        let taken5 = f.offerStaleList([Self.castle])
        #expect(!taken5)
        #expect(f.places.isEmpty)
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

    @Test func osmFailedListIsRetriedAfterSixtySecondsWithoutMoving() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0, osmFailed: true, fetchedAt: Self.t0)
        // Fetched at t0 with OSM failed: still at the centre, blocked at t0 + 59, allowed at t0 + 60 (60 ≥ 60).
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
        // A complete list from the retry ends it: 100 m away and long after, no fetch (100 < 250).
        f.fetchStarted(now: Self.t0 + 60)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0 + 61, osmFailed: false, fetchedAt: Self.t0 + 61)
        #expect(!f.shouldFetch(at: .at(north: 100), now: Self.t0 + 500))
    }

    @Test func osmFailedRetryCountsFromTheListsFetchTime() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0 + 30)
        // A list the camera fetched at t0, taken by the feed at t0 + 30: the retry is due at t0 + 60, not t0 + 90.
        f.fetchSucceeded([], at: .at(), now: Self.t0 + 30, osmFailed: true, fetchedAt: Self.t0)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
    }

    @Test func osmFailedListDatedInTheFutureCountsFromNow() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        // fetchedAt t0 + 1000 (clock set back) → counted from t0: blocked at t0 + 59, due at t0 + 60.
        f.fetchSucceeded([], at: .at(), now: Self.t0, osmFailed: true, fetchedAt: Self.t0 + 1000)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
    }

    @Test func osmFailedRetryWaitsForTheFailureBackoffAndAnInFlightFetch() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0, osmFailed: true, fetchedAt: Self.t0)
        // The retry at t0 + 60 starts and is in flight: no second fetch.
        f.fetchStarted(now: Self.t0 + 60)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 61))
        // It fails at t0 + 70 with places kept: the 60 s failure backoff holds until t0 + 130 (70 + 60), the OSM rule
        // cannot skip it.
        f.fetchFailed(now: Self.t0 + 70)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 129))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 130))
    }

    @Test func osmFailedDefaultsToFetchedNow() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        // No fetchedAt: counted from now = t0 → due at t0 + 60.
        f.fetchSucceeded([], at: .at(), now: Self.t0, osmFailed: true)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 59))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 60))
    }

    @Test func osmFailedRetryUsesTheListsBackedOffAge() {
        // Spec 20.8: a list whose OSM part failed for the second time in a row asks for its retry after 120 s.
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0, osmFailed: true, fetchedAt: Self.t0, osmRetryAge: 120)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 119))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 120))
        // The third: 300 s.
        f.fetchStarted(now: Self.t0 + 120)
        f.fetchSucceeded([Self.castle], at: .at(), now: Self.t0 + 121, osmFailed: true, fetchedAt: Self.t0 + 121,
                         osmRetryAge: 300)
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 420))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 421))
        // Moving 250 m still refetches at once, whatever the age.
        #expect(f.shouldFetch(at: .at(north: 250), now: Self.t0 + 122))
    }

    @Test func completeListKeepsTheDistanceRule() {
        var f = PlaceFeed()
        f.fetchStarted(now: Self.t0)
        f.fetchSucceeded([], at: .at(), now: Self.t0, osmFailed: false, fetchedAt: Self.t0)
        // OSM fine: an hour later at 249 m no fetch, at 250 m a fetch.
        #expect(!f.shouldFetch(at: .at(north: 249), now: Self.t0 + 3600))
        #expect(f.shouldFetch(at: .at(north: 250), now: Self.t0 + 3600))
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
        f.fetchStarted(now: Self.t0 + 5); f.fetchCancelled()
        // Cancelling does not touch the earlier failure time: with no places the failure at t0 blocks until t0 + 15,
        // so t0 + 10 is still blocked and t0 + 15 is allowed.
        #expect(!f.shouldFetch(at: .at(), now: Self.t0 + 10))
        #expect(f.shouldFetch(at: .at(), now: Self.t0 + 15))
    }
}
