import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingPlaybackTests {
    static let a = UUID(), b = UUID()
    @Test func tapAfterReadyPlays() {
        var p = WalkingPlayback()
        #expect(p.handle(.buzzSent(Self.a)).isEmpty && p.isBusy)
        #expect(p.handle(.storyReady(Self.a)).isEmpty && !p.isBusy)
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
        #expect(p.isBusy && p.playing?.id == Self.a)
    }
    @Test func tapWhilePreparingPlaysWhenReady() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.handle(.tellMe(Self.a)).isEmpty)
        #expect(p.handle(.storyReady(Self.a)) == [.play(Self.a, level: 1)])
    }
    @Test func failedStoryReportsOnTap() {
        // Review Focus 2
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.storyFailed(Self.a)) == [.reportFailure(Self.a)])
        #expect(p.handle(.tellMe(Self.a)) == [.reportFailure(Self.a)])
        #expect(!p.isBusy)
    }
    @Test func failureWithoutTapIsSilent() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.handle(.storyFailed(Self.a)).isEmpty && !p.isBusy)
    }
    @Test func oldNotificationInterruptsCurrentStory() {
        // Review Focus 4
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b))
        _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.tellMe(Self.a)) == [.stopAudio, .play(Self.a, level: 1)])
        #expect(p.playing?.id == Self.a)
    }
    @Test func tapOnPlayingStoryChangesNothing() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.tellMe(Self.a)).isEmpty && p.playing?.id == Self.a)
    }
    @Test func preparedTapInterruptsPlayingWhenReadyArrives() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.storyReady(Self.b)) == [.stopAudio, .play(Self.b, level: 1)])
    }
    @Test func unknownIDReportsFailure() {
        var p = WalkingPlayback()
        #expect(p.handle(.tellMe(Self.a)) == [.reportFailure(Self.a)])
    }
    @Test func moreLevels() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.finished(Self.a, level: 1)) == [.offerMore(Self.a)])
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)] && p.isBusy)
        #expect(p.handle(.moreReady(Self.a, level: 2)) == [.play(Self.a, level: 2)])
        #expect(p.handle(.finished(Self.a, level: 2)) == [.offerMore(Self.a)])
        _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 3))
        #expect(p.handle(.finished(Self.a, level: 3)).isEmpty)
        #expect(p.handle(.more(Self.a)).isEmpty)
    }
    @Test func moreFailureReportsAndFreesTheEngine() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        #expect(p.handle(.moreFailed(Self.a)) == [.reportFailure(Self.a)] && !p.isBusy)
        // The listener can ask again.
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)])
    }
    @Test func moreForUnknownStoryDoesNothing() {
        var p = WalkingPlayback()
        #expect(p.handle(.more(Self.a)).isEmpty && !p.isBusy)
    }
    @Test func skip() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.skip(Self.a)) == [.stopAudio, .retire(Self.a)])
        #expect(p.playing == nil && !p.isBusy)
        _ = p.handle(.buzzSent(Self.b))
        #expect(p.handle(.skip(Self.b)) == [.retire(Self.b)])
        #expect(p.handle(.storyReady(Self.b)).isEmpty)   // a skipped story never plays
    }
    @Test func skipClearsRememberedTap() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.skip(Self.a))
        #expect(p.handle(.storyReady(Self.a)).isEmpty && p.playing == nil)
    }
    @Test func skippingAnotherStoryKeepsAudioPlaying() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.buzzSent(Self.b))
        #expect(p.handle(.skip(Self.b)) == [.retire(Self.b)] && p.playing?.id == Self.a)
    }
    @Test func lateMoreResultOfSkippedStoryIsIgnored() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        _ = p.handle(.skip(Self.a))
        #expect(p.handle(.moreReady(Self.a, level: 2)).isEmpty && p.playing == nil && !p.isBusy)
    }
    @Test func externalStopFreesTheEngine() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.stoppedExternally).isEmpty && !p.isBusy)
    }
    @Test func staleFinishIsIgnored() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b)); _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.finished(Self.a, level: 1)).isEmpty && p.playing?.id == Self.b)
    }
    @Test func replayAfterAllLevelsDoesNotOfferOrFetchMore() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 2))
        _ = p.handle(.finished(Self.a, level: 2)); _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 3))
        _ = p.handle(.finished(Self.a, level: 3))
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
        #expect(p.handle(.finished(Self.a, level: 1)).isEmpty)
        #expect(p.handle(.more(Self.a)).isEmpty)
    }
    @Test func replayOfLevelOneStillOffersMoreWhenLevelsRemain() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1))
        _ = p.handle(.tellMe(Self.a))
        #expect(p.handle(.finished(Self.a, level: 1)) == [.offerMore(Self.a)])
    }
    @Test func tapWhileFetchingReplaysAndTheFetchStillPlays() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
        #expect(p.handle(.tellMe(Self.a)).isEmpty)   // already playing it
        #expect(p.handle(.moreReady(Self.a, level: 2)) == [.play(Self.a, level: 2)])
    }
    @Test func tapWhileFetchingInterruptsAnotherStory() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b)); _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.tellMe(Self.a)) == [.stopAudio, .play(Self.a, level: 1)])
    }
    @Test func lateFinishOfEarlierLevelKeepsEngineBusy() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 2))
        #expect(p.handle(.finished(Self.a, level: 1)).isEmpty)
        #expect(p.isBusy && p.playing?.level == 2)
    }
    @Test func memoryIsBoundedButActiveStoriesSurvive() {
        var p = WalkingPlayback()
        // a is skipped while preparing, then 25 newer buzzes arrive: its late result must still not play.
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.skip(Self.a))
        for _ in 0..<25 { let id = UUID(); _ = p.handle(.buzzSent(id)); _ = p.handle(.storyReady(id)) }
        #expect(p.handle(.storyReady(Self.a)).isEmpty && p.playing == nil)
        // b is still preparing (tapped) through 25 newer stories and then plays.
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.tellMe(Self.b))
        for _ in 0..<25 { let id = UUID(); _ = p.handle(.buzzSent(id)); _ = p.handle(.storyReady(id)) }
        #expect(p.handle(.storyReady(Self.b)) == [.play(Self.b, level: 1)])
        // The oldest idle ready story has been forgotten: a tap on it is a failure (re-prepare from memory).
        var q = WalkingPlayback()
        _ = q.handle(.buzzSent(Self.a)); _ = q.handle(.storyReady(Self.a))
        for _ in 0..<WalkingPlayback.memoryLimit { let id = UUID(); _ = q.handle(.buzzSent(id)); _ = q.handle(.storyReady(id)) }
        #expect(q.handle(.tellMe(Self.a)) == [.reportFailure(Self.a)])
    }

    // MARK: - Queries and in-app listening (Task 11)

    @Test func hasStoryOnlyWhileTheStoryCanBeTold() {
        var p = WalkingPlayback()
        #expect(!p.hasStory(Self.a))
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.hasStory(Self.a))                       // preparing
        _ = p.handle(.storyReady(Self.a))
        #expect(p.hasStory(Self.a))                       // ready
        _ = p.handle(.tellMe(Self.a)); _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        #expect(p.hasStory(Self.a))                       // fetching
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyFailed(Self.b))
        #expect(!p.hasStory(Self.b))                      // failed: the app may rebuild it from memory
        _ = p.handle(.skip(Self.a))
        #expect(!p.hasStory(Self.a))                      // skipped: forgotten
    }
    @Test func deepestLevelFollowsWhatWasPlayed() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a))
        #expect(p.deepestLevel(Self.a) == nil)            // ready, never played
        _ = p.handle(.tellMe(Self.a))
        #expect(p.deepestLevel(Self.a) == 1)
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 2))
        #expect(p.deepestLevel(Self.a) == 2)
        _ = p.handle(.tellMe(Self.b))
        #expect(p.deepestLevel(Self.b) == nil)            // unknown
    }
    @Test func moreOnAReadyStoryThatWasNeverPlayed() {
        // The story screen's "Tell me more" works before anything was heard: the story has level 1, so level 2 is next.
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a))
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)] && p.isBusy)
        // Nothing heard counts as level 1 heard: 1 + 1 = 2.
        #expect(p.fetchingLevel(Self.a) == 2)
        #expect(p.handle(.moreReady(Self.a, level: 2)) == [.play(Self.a, level: 2)])
        #expect(p.deepestLevel(Self.a) == 2 && p.fetchingLevel(Self.a) == nil)
    }
    @Test func moreIsRefusedWhilePreparingOrFetching() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.handle(.more(Self.a)).isEmpty)
        _ = p.handle(.storyReady(Self.a)); _ = p.handle(.more(Self.a))
        #expect(p.handle(.more(Self.a)).isEmpty)          // already fetching
    }
    @Test func listenPlaysAnyLevelAndReplacesTheCurrentAudio() {
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 3, deepestHeard: 0))
        #expect(p.handle(.listen(Self.a, level: 2)) == [.play(Self.a, level: 2)])
        #expect(p.playing?.level == 2 && p.isBusy && p.deepestLevel(Self.a) == 2)
        // Same story, other level: the app replaces the audio itself, so no stopAudio.
        #expect(p.handle(.listen(Self.a, level: 1)) == [.play(Self.a, level: 1)])
        #expect(p.playing?.level == 1 && p.deepestLevel(Self.a) == 2)
        // The level already playing: nothing to do.
        #expect(p.handle(.listen(Self.a, level: 1)).isEmpty)
        // Another story stops this one first.
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b))
        #expect(p.handle(.listen(Self.b, level: 1)) == [.stopAudio, .play(Self.b, level: 1)])
        // b has only level 1's text.
        #expect(p.handle(.listen(Self.b, level: 2)).isEmpty && p.playing?.level == 1)
    }
    @Test func listenFinishOffersMoreOnlyWhileLevelsRemain() {
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 3, deepestHeard: 0))
        _ = p.handle(.listen(Self.a, level: 2))
        #expect(p.handle(.finished(Self.a, level: 2)) == [.offerMore(Self.a)])
        _ = p.handle(.listen(Self.a, level: 3))
        #expect(p.handle(.finished(Self.a, level: 3)).isEmpty && !p.isBusy)
    }
    @Test func listenBoundariesAndStates() {
        var p = WalkingPlayback()
        // Unknown or failed: a failure, as for "tell me".
        #expect(p.handle(.listen(Self.a, level: 1)) == [.reportFailure(Self.a)])
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyFailed(Self.b))
        #expect(p.handle(.listen(Self.b, level: 1)) == [.reportFailure(Self.b)])
        // Preparing: there is no text yet, so nothing plays.
        _ = p.handle(.buzzSent(Self.a))
        #expect(p.handle(.listen(Self.a, level: 1)).isEmpty && p.playing == nil)
        _ = p.handle(.storyReady(Self.a))
        // Levels without text (here 2 of 1 stored) and outside 1...3 are ignored.
        #expect(p.handle(.listen(Self.a, level: 0)).isEmpty)
        #expect(p.handle(.listen(Self.a, level: 2)).isEmpty)
        #expect(p.handle(.listen(Self.a, level: 4)).isEmpty)
        #expect(p.playing == nil && p.deepestLevel(Self.a) == nil)
    }
    @Test func listenWhileFetchingKeepsTheFetch() {
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a))
        #expect(p.handle(.listen(Self.a, level: 1)) == [.play(Self.a, level: 1)])
        #expect(p.handle(.moreReady(Self.a, level: 2)) == [.play(Self.a, level: 2)])
    }

    // MARK: - Restored from memory (Ruling 17)

    @Test func restoredWithEveryStoredLevelHeardFetchesTheNext() {
        // storedLevels 2, deepestHeard 2: next = 2 + 1 = 3 > 2 stored, so it is fetched.
        var p = WalkingPlayback()
        #expect(p.handle(.restored(Self.a, storedLevels: 2, deepestHeard: 2)).isEmpty)
        #expect(p.hasStory(Self.a) && !p.isBusy && p.deepestLevel(Self.a) == 2)
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)])
        #expect(p.fetchingLevel(Self.a) == 3 && p.isBusy)
    }
    @Test func restoredWithAStoredLevelNotHeardPlaysItFromStorage() {
        // storedLevels 3, deepestHeard 2: next = 2 + 1 = 3 ≤ 3 stored, so it plays without a fetch.
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 3, deepestHeard: 2))
        #expect(p.handle(.more(Self.a)) == [.play(Self.a, level: 3)])
        #expect(p.fetchingLevel(Self.a) == nil && p.playing?.level == 3 && p.deepestLevel(Self.a) == 3)
        #expect(p.handle(.finished(Self.a, level: 3)).isEmpty)
    }
    @Test func restoredWithEverythingHeardHasNoMore() {
        // storedLevels 3, deepestHeard 3: next = 4 > 3 levels.
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 3, deepestHeard: 3))
        #expect(p.handle(.more(Self.a)).isEmpty && !p.isBusy)
        // A replay still works.
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
    }
    @Test func restoredNothingHeard() {
        // storedLevels 1, deepestHeard 0: nothing heard counts as level 1, next = 2 > 1 stored → fetch level 2.
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 1, deepestHeard: 0))
        #expect(p.deepestLevel(Self.a) == nil)
        #expect(p.handle(.tellMe(Self.a)) == [.play(Self.a, level: 1)])
        _ = p.handle(.finished(Self.a, level: 1))
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)] && p.fetchingLevel(Self.a) == 2)
    }
    @Test func restoredClampsAndRejectsBadCounts() {
        var p = WalkingPlayback()
        // 0 stored levels: no story.
        #expect(p.handle(.restored(Self.a, storedLevels: 0, deepestHeard: 0)).isEmpty && !p.hasStory(Self.a))
        // 5 stored → cap min(5, 3) = 3; deepest heard 4 → min(4, 3) = 3.
        _ = p.handle(.restored(Self.b, storedLevels: 5, deepestHeard: 4))
        #expect(p.deepestLevel(Self.b) == 3)
        #expect(p.handle(.listen(Self.b, level: 3)) == [.play(Self.b, level: 3)])
        #expect(p.handle(.listen(Self.b, level: 4)).isEmpty)
    }
    @Test func moreFromStorageInterruptsAnotherStory() {
        var p = WalkingPlayback()
        _ = p.handle(.restored(Self.a, storedLevels: 2, deepestHeard: 1))
        _ = p.handle(.buzzSent(Self.b)); _ = p.handle(.storyReady(Self.b)); _ = p.handle(.tellMe(Self.b))
        #expect(p.handle(.more(Self.a)) == [.stopAudio, .play(Self.a, level: 2)])
    }
    @Test func fetchedLevelsCountAsStored() {
        // After more fetched level 2, a replay of level 1 then "more" plays level 2 again from storage? No: the
        // deepest heard is 2, so next = 3, which is fetched.
        var p = WalkingPlayback()
        _ = p.handle(.buzzSent(Self.a)); _ = p.handle(.storyReady(Self.a)); _ = p.handle(.tellMe(Self.a))
        _ = p.handle(.finished(Self.a, level: 1)); _ = p.handle(.more(Self.a)); _ = p.handle(.moreReady(Self.a, level: 2))
        #expect(p.handle(.listen(Self.a, level: 2)).isEmpty)   // already playing level 2
        #expect(p.handle(.listen(Self.a, level: 1)) == [.play(Self.a, level: 1)])
        _ = p.handle(.finished(Self.a, level: 1))
        #expect(p.handle(.more(Self.a)) == [.fetchMore(Self.a)] && p.fetchingLevel(Self.a) == 3)
    }
}
