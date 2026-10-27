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
}
