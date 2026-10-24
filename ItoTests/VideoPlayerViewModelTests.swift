import XCTest
import ito_runner
@testable import Ito

@MainActor
final class VideoPlayerViewModelTests: XCTestCase {
    func testInitialLoadRecordsHistoryBeforeExactRouteRequestAndPublishesDefaults() async {
        let anime = Anime(key: "exact-anime", title: "Anime")
        let episode = Anime.Episode(key: "exact-episode", title: nil, episode: 7)
        let hard = subtitle("hard", language: "JP", isHardsub: true)
        let soft = subtitle("soft", language: "EN")
        let audio = Anime.AudioTrack(url: "audio", language: "Japanese")
        let first = video(
            "first",
            audioTracks: [audio],
            subtitles: [hard, soft]
        )
        let second = video("second", quality: "720p")
        let subject = makeVideoPlayerSubject(anime: anime, episode: episode)
        subject.streamLoader.responses = [.success([first, second])]

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.events.events.prefix(2), ["history", "stream"])
        XCTAssertEqual(subject.history.requests.count, 1)
        XCTAssertEqual(subject.history.requests[0].anime.key, "exact-anime")
        XCTAssertEqual(subject.history.requests[0].episodeKey, "exact-episode")
        XCTAssertEqual(subject.history.requests[0].episodeTitle, "exact-episode")
        XCTAssertEqual(subject.history.requests[0].pluginID, "plugin.test")
        XCTAssertEqual(subject.streamLoader.requests[0].anime.key, "exact-anime")
        XCTAssertEqual(subject.streamLoader.requests[0].episode.key, "exact-episode")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.videos.map(\.url), ["first", "second"])
        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "first")
        XCTAssertEqual(subject.viewModel.selectedAudioTrack?.url, "audio")
        XCTAssertEqual(subject.viewModel.selectedSubtitle?.url, "soft")
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first"])
    }

    func testSavedTimeAsksBeforePlayingAndContinueStartsThere() async {
        let episode = Anime.Episode(key: "ep", title: nil, episode: 3)
        let subject = makeVideoPlayerSubject(episode: episode)
        subject.streamLoader.responses = [.success([video("first")])]
        subject.progress.savedTimes["ep"] = 754

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.resumeOffer, 754)
        XCTAssertTrue(subject.playback.activatedPreparationIDs.isEmpty)

        subject.viewModel.resolveResumeOffer(continueWatching: true)

        XCTAssertNil(subject.viewModel.resumeOffer)
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first"])
        XCTAssertEqual(subject.playback.activatedStartTimes, [754])
    }

    func testStartOverPlaysFromTheBeginning() async {
        let episode = Anime.Episode(key: "ep", title: nil, episode: 3)
        let subject = makeVideoPlayerSubject(episode: episode)
        subject.streamLoader.responses = [.success([video("first")])]
        subject.progress.savedTimes["ep"] = 754

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.resolveResumeOffer(continueWatching: false)

        XCTAssertEqual(subject.playback.activatedStartTimes, [nil])
    }

    func testShortSavedTimePlaysWithoutAsking() async {
        let episode = Anime.Episode(key: "ep", title: nil, episode: 3)
        let subject = makeVideoPlayerSubject(episode: episode)
        subject.streamLoader.responses = [.success([video("first")])]
        subject.progress.savedTimes["ep"] = 3

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertNil(subject.viewModel.resumeOffer)
        XCTAssertEqual(subject.playback.activatedStartTimes, [nil])
    }

    func testPlaybackTimeIsSavedPeriodicallyAndResetOnceWatched() async {
        let subject = makeVideoPlayerSubject()

        subject.viewModel.playbackTimeDidChange(currentTime: 2, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 6, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 8, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 12, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 85, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 95, duration: 100)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.progress.savedTimeWrites, [6, 12, 0])
    }

    func testLeavingSavesWhereWatchingStopped() async {
        let subject = makeVideoPlayerSubject()
        subject.viewModel.playbackTimeDidChange(currentTime: 6, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 9, duration: 100)

        subject.viewModel.disappear()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.progress.savedTimeWrites, [6, 9])
    }

    func testStartOverIsSavedRightAway() async {
        let episode = Anime.Episode(key: "ep", title: nil, episode: 3)
        let subject = makeVideoPlayerSubject(episode: episode)
        subject.streamLoader.responses = [.success([video("first")])]
        subject.progress.savedTimes["ep"] = 754
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.resolveResumeOffer(continueWatching: false)
        // Closing before any playback time arrives must not bring the prompt back.
        subject.viewModel.disappear()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.progress.savedTimes["ep"], 0)
    }

    func testChangingQualityCarriesOnFromTheCurrentTime() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("first"), video("second", quality: "720p")])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.playbackTimeDidChange(currentTime: 930, duration: 1400)

        subject.viewModel.selectVideo(subject.viewModel.videos[1])
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.playback.activatedStartTimes, [nil, 930])
    }

    func testInitialLoadFailureKeepsHistoryAndPublishesExistingErrorText() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.failure(VideoPlayerTestError.expected)]

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.history.requests.count, 1)
        XCTAssertEqual(
            subject.viewModel.loadPhase,
            .failure("expected video player failure")
        )
        XCTAssertTrue(subject.viewModel.videos.isEmpty)
        XCTAssertTrue(subject.playback.requests.isEmpty)
    }

    func testEmptySuccessfulStreamListIsContentWithoutPlayer() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([])]

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertNil(subject.viewModel.selectedVideo)
        XCTAssertNil(subject.viewModel.playbackSurface)
        XCTAssertTrue(subject.playback.requests.isEmpty)
    }

    func testDuplicateStartSuppressesOverlappingStreamLoads() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.suspended]

        subject.viewModel.start()
        subject.viewModel.start()
        await subject.streamLoader.waitForPendingCount(1)
        subject.viewModel.start()

        XCTAssertEqual(subject.streamLoader.requests.count, 1)
        XCTAssertEqual(subject.history.requests.count, 1)
        subject.streamLoader.resolveFirst(with: .success([]))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    func testDuplicateStartWhileInitialPreparationIsPendingDoesNotReloadStreams() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("stream")])]
        subject.playback.enqueue(.suspended, for: "stream")

        subject.viewModel.start()
        await subject.playback.waitForPendingCount(1)
        subject.viewModel.start()

        XCTAssertEqual(subject.streamLoader.requests.count, 1)
        XCTAssertEqual(subject.history.requests.count, 1)
        subject.playback.resolveFirst(for: "stream", preparationID: "stream")
        await subject.viewModel.waitForAllOperationsForTesting()
    }

    func testInitialSubtitleFallsBackToFirstWhenAllAreHardsub() async {
        let first = subtitle("first-hard", language: "One", isHardsub: true)
        let second = subtitle("second-hard", language: "Two", isHardsub: true)
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [
            .success([video("stream", subtitles: [first, second])])
        ]

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.selectedSubtitle?.url, "first-hard")
    }

    func testNonCooperativeLateStreamSuccessAfterDisappearCannotPublish() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.suspended]
        subject.viewModel.start()
        await subject.streamLoader.waitForPendingCount(1)

        subject.viewModel.disappear()
        subject.streamLoader.resolveFirst(with: .success([video("late")]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        XCTAssertTrue(subject.viewModel.videos.isEmpty)
        XCTAssertTrue(subject.playback.requests.isEmpty)
        XCTAssertEqual(subject.presence.clearCount, 1)
    }

    func testNonCooperativeLateStreamFailureCannotPublishErrorOrPresence() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.suspended]
        subject.viewModel.appear()
        subject.viewModel.start()
        await subject.streamLoader.waitForPendingCount(1)

        subject.viewModel.disappear()
        subject.streamLoader.resolveFirst(with: .failure(VideoPlayerTestError.expected))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        XCTAssertEqual(subject.presence.presented.count, 1)
        XCTAssertEqual(subject.presence.clearCount, 1)
        XCTAssertTrue(subject.playback.requests.isEmpty)
    }

    func testInvalidPreparationLeavesContentWithoutInventingFailure() async {
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("not a valid url")])]
        subject.playback.enqueue(.invalid, for: "not a valid url")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "not a valid url")
        XCTAssertNil(subject.viewModel.playbackSurface)
    }

    func testInvalidQualityPreparationKeepsExistingPlaybackCallbacksAuthoritative() async {
        let first = video("first")
        let invalid = video("invalid")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([first, invalid])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.playback.enqueue(.invalid, for: "invalid")

        subject.viewModel.selectVideo(invalid)
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.playback.emit(currentTime: 8, duration: 10)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "invalid")
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first"])
        XCTAssertEqual(subject.progress.requests.count, 1)
    }

    func testQualitySelectionPreservesCurrentAudioAndSubtitleAndReloadsSubtitle() async {
        let audioOne = Anime.AudioTrack(url: "audio-1", language: "One")
        let audioTwo = Anime.AudioTrack(url: "audio-2", language: "Two")
        let subOne = subtitle("sub-1", language: "One")
        let subTwo = subtitle("sub-2", language: "Two")
        let first = video(
            "first",
            audioTracks: [audioOne, audioTwo],
            subtitles: [subOne, subTwo]
        )
        let second = video("second", quality: "720p")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([first, second])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.selectAudioTrack(audioTwo)
        subject.viewModel.selectSubtitle(subTwo)
        await subject.viewModel.waitForAllOperationsForTesting()
        let loadsBeforeQuality = subject.subtitleLoader.requestedURLs.count

        subject.viewModel.selectVideo(second)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "second")
        XCTAssertEqual(subject.viewModel.selectedAudioTrack?.url, "audio-2")
        XCTAssertEqual(subject.viewModel.selectedSubtitle?.url, "sub-2")
        XCTAssertEqual(subject.subtitleLoader.requestedURLs.count, loadsBeforeQuality + 1)
        XCTAssertEqual(subject.subtitleLoader.requestedURLs.last, "sub-2")
        XCTAssertEqual(subject.playback.replacementCount, 1)
        XCTAssertEqual(subject.playback.observerInstallCount, 1)
        XCTAssertEqual(subject.playback.playCount, 2)
    }

    func testAudioSelectionOnlyChangesMetadata() async {
        let first = Anime.AudioTrack(url: "one", language: "One")
        let second = Anime.AudioTrack(url: "two", language: "Two")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [
            .success([video("stream", audioTracks: [first, second])])
        ]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        let preparationCount = subject.playback.requests.count

        subject.viewModel.selectAudioTrack(second)

        XCTAssertEqual(subject.viewModel.selectedAudioTrack?.url, "two")
        XCTAssertEqual(subject.playback.requests.count, preparationCount)
        XCTAssertEqual(subject.playback.replacementCount, 0)
    }

    func testRapidQualitySelectionRejectsLateOldPreparation() async {
        let first = video("first")
        let qualityA = video("quality-a", quality: "720p")
        let qualityB = video("quality-b", quality: "480p")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([first, qualityA, qualityB])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.playback.enqueue(.suspended, for: "quality-a")
        subject.playback.enqueue(.suspended, for: "quality-b")

        subject.viewModel.selectVideo(qualityA)
        await subject.playback.waitForPendingCount(1)
        subject.viewModel.selectVideo(qualityB)
        await subject.playback.waitForPendingCount(2)
        subject.playback.resolveFirst(for: "quality-b", preparationID: "prepared-b")
        await subject.viewModel.waitForCurrentPreparationForTesting()

        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "quality-b")
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first", "prepared-b"])
        subject.playback.resolveFirst(for: "quality-a", preparationID: "prepared-a")
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first", "prepared-b"])
        XCTAssertEqual(subject.viewModel.selectedVideo?.url, "quality-b")
    }

    func testSubtitleOffClearsSelectionCuesAndCurrentText() async {
        let selected = subtitle("sub", language: "English")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("stream", subtitles: [selected])])]
        subject.subtitleLoader.enqueue(
            .success("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello\n"),
            for: "sub"
        )
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.playbackTimeDidChange(currentTime: 2, duration: 10)
        XCTAssertEqual(subject.viewModel.currentSubtitleText, "Hello")

        subject.viewModel.selectSubtitle(nil)

        XCTAssertNil(subject.viewModel.selectedSubtitle)
        XCTAssertTrue(subject.viewModel.parsedSubtitles.isEmpty)
        XCTAssertNil(subject.viewModel.currentSubtitleText)
    }

    func testSubtitleSuccessfulVTTLoadUsesExactURLAndPR12Parser() async {
        let selected = subtitle("exact-subtitle-url", language: "English")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("stream")])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.subtitleLoader.enqueue(
            .success("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nFirst\nSecond\n"),
            for: "exact-subtitle-url"
        )

        subject.viewModel.selectSubtitle(selected)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.subtitleLoader.requestedURLs.last, "exact-subtitle-url")
        XCTAssertEqual(
            subject.viewModel.parsedSubtitles,
            [VTTCue(start: 1, end: 2, text: "First\nSecond")]
        )
    }

    func testSubtitleFetchAndDecodeFailuresRemainNonfatalAndPreserveCues() async {
        let original = subtitle("original", language: "English")
        let fetchFailure = subtitle("fetch-failure", language: "Spanish")
        let decodeFailure = subtitle("decode-failure", language: "French")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("stream")])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.subtitleLoader.enqueue(
            .success("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOriginal\n"),
            for: "original"
        )
        subject.viewModel.selectSubtitle(original)
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.subtitleLoader.enqueue(.failure(VideoPlayerTestError.expected), for: "fetch-failure")
        subject.viewModel.selectSubtitle(fetchFailure)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.parsedSubtitles.first?.text, "Original")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)

        subject.subtitleLoader.enqueue(
            .failure(VideoSubtitleLoaderError.nonUTF8Data),
            for: "decode-failure"
        )
        subject.viewModel.selectSubtitle(decodeFailure)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.parsedSubtitles.first?.text, "Original")
        XCTAssertEqual(subject.viewModel.selectedSubtitle?.url, "decode-failure")
    }

    func testIdenticalOverlappingSubtitleLoadIsSuppressed() async {
        let selected = subtitle("same", language: "English")
        let subject = makeVideoPlayerSubject()
        subject.subtitleLoader.enqueue(.suspended, for: "same")

        subject.viewModel.selectSubtitle(selected)
        await subject.subtitleLoader.waitForPendingCount(1, for: "same")
        subject.viewModel.selectSubtitle(selected)

        XCTAssertEqual(subject.subtitleLoader.requestedURLs, ["same"])
        subject.subtitleLoader.resolveFirst(for: "same", with: .success("WEBVTT\n"))
        await subject.viewModel.waitForAllOperationsForTesting()
    }

    func testRapidSubtitleSelectionRejectsLateOldResult() async {
        let subtitleA = subtitle("subtitle-a", language: "A")
        let subtitleB = subtitle("subtitle-b", language: "B")
        let subject = makeVideoPlayerSubject()
        subject.subtitleLoader.enqueue(.suspended, for: "subtitle-a")
        subject.subtitleLoader.enqueue(.suspended, for: "subtitle-b")

        subject.viewModel.selectSubtitle(subtitleA)
        await subject.subtitleLoader.waitForPendingCount(1, for: "subtitle-a")
        subject.viewModel.selectSubtitle(subtitleB)
        await subject.subtitleLoader.waitForPendingCount(1, for: "subtitle-b")
        subject.subtitleLoader.resolveFirst(
            for: "subtitle-b",
            with: .success("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nB cue\n")
        )
        await subject.viewModel.waitForCurrentSubtitleLoadForTesting()
        subject.subtitleLoader.resolveFirst(
            for: "subtitle-a",
            with: .success("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA cue\n")
        )
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.selectedSubtitle?.url, "subtitle-b")
        XCTAssertEqual(subject.viewModel.parsedSubtitles.first?.text, "B cue")
        subject.viewModel.playbackTimeDidChange(currentTime: 1.5, duration: 10)
        XCTAssertEqual(subject.viewModel.currentSubtitleText, "B cue")
    }

    func testLateSubtitleCompletionAfterDisappearCannotPublishCues() async {
        let selected = subtitle("late-subtitle", language: "English")
        let subject = makeVideoPlayerSubject()
        subject.subtitleLoader.enqueue(.suspended, for: "late-subtitle")
        subject.viewModel.selectSubtitle(selected)
        await subject.subtitleLoader.waitForPendingCount(1, for: "late-subtitle")

        subject.viewModel.disappear()
        subject.subtitleLoader.resolveFirst(
            for: "late-subtitle",
            with: .success("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nLate\n")
        )
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertTrue(subject.viewModel.parsedSubtitles.isEmpty)
        XCTAssertNil(subject.viewModel.currentSubtitleText)
    }

    func testActiveCueUsesInclusiveBoundariesFirstMatchAndClearsOutside() async {
        let selected = subtitle("sub", language: "English")
        let subject = makeVideoPlayerSubject()
        subject.subtitleLoader.enqueue(
            .success(
                "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nFirst\n\n"
                    + "00:00:02.000 --> 00:00:03.000\nSecond\n"
            ),
            for: "sub"
        )
        subject.viewModel.selectSubtitle(selected)
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.playbackTimeDidChange(currentTime: 1, duration: 10)
        XCTAssertEqual(subject.viewModel.currentSubtitleText, "First")
        subject.viewModel.playbackTimeDidChange(currentTime: 2, duration: 10)
        XCTAssertEqual(subject.viewModel.currentSubtitleText, "First")
        subject.viewModel.playbackTimeDidChange(currentTime: 2.5, duration: 10)
        XCTAssertEqual(subject.viewModel.currentSubtitleText, "Second")
        subject.viewModel.playbackTimeDidChange(currentTime: 3.1, duration: 10)
        XCTAssertNil(subject.viewModel.currentSubtitleText)
    }

    func testProgressThresholdRequiresFinitePositiveDurationAndStartsAtExactEightyPercent() async {
        let subject = makeVideoPlayerSubject()

        subject.viewModel.playbackTimeDidChange(currentTime: 79.9, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 80, duration: 0)
        subject.viewModel.playbackTimeDidChange(currentTime: 80, duration: .infinity)
        XCTAssertTrue(subject.progress.requests.isEmpty)
        XCTAssertFalse(subject.viewModel.hasTrackedProgress)

        subject.viewModel.playbackTimeDidChange(currentTime: 80, duration: 100)
        XCTAssertTrue(subject.viewModel.hasTrackedProgress)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertEqual(
            subject.progress.requests[0].context,
            PluginCompletionContext(
                media: MediaIdentity(pluginId: "plugin.test", itemId: "anime"),
                mediaKey: "anime",
                kind: .anime,
                originatingEpoch: "epoch"
            )
        )
        XCTAssertEqual(subject.tracker.requests.map(\.progress), [1])
    }

    func testProgressThresholdAboveEightyPercentIsOneShot() async {
        let subject = makeVideoPlayerSubject()

        subject.viewModel.playbackTimeDidChange(currentTime: 81, duration: 100)
        subject.viewModel.playbackTimeDidChange(currentTime: 95, duration: 100)
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.playbackTimeDidChange(currentTime: 100, duration: 100)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertEqual(subject.tracker.requests.count, 1)
    }

    func testLocalWatchedCompletesBeforeTrackerUpdate() async {
        let subject = makeVideoPlayerSubject()
        subject.progress.responses = [.suspended]

        subject.viewModel.playbackTimeDidChange(currentTime: 8, duration: 10)
        await subject.progress.waitUntilPending()
        XCTAssertEqual(subject.events.events, ["progress"])
        XCTAssertTrue(subject.tracker.requests.isEmpty)
        subject.progress.resolveFirst(with: .success(()))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.events.events, ["progress", "tracker"])
    }

    func testLocalWatchedFailureBlocksTrackerWithoutRetryingThreshold() async {
        let subject = makeVideoPlayerSubject()
        subject.progress.responses = [.failure(VideoPlayerTestError.expected)]

        subject.viewModel.playbackTimeDidChange(currentTime: 8, duration: 10)
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.playbackTimeDidChange(currentTime: 9, duration: 10)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertTrue(subject.viewModel.hasTrackedProgress)
        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertTrue(subject.tracker.requests.isEmpty)
    }

    func testTrackerProgressParsesEpisodeNumbersWithoutJoiningDecimalDigits() {
        XCTAssertEqual(
            VideoPlayerViewModel.trackerProgress(
                for: Anime.Episode(key: "key", title: "ignored", episode: 12.9)
            ),
            12
        )
        XCTAssertEqual(
            VideoPlayerViewModel.trackerProgress(
                for: Anime.Episode(key: "key", title: "Episode 12.5 Finale")
            ),
            12
        )
        XCTAssertEqual(
            VideoPlayerViewModel.trackerProgress(
                for: Anime.Episode(key: "episode-42", title: nil)
            ),
            42
        )
        XCTAssertNil(
            VideoPlayerViewModel.trackerProgress(
                for: Anime.Episode(key: "special", title: "No number")
            )
        )
    }

    func testDiscordAppearanceEpisodeTransitionAndClearPreservePayload() {
        let anime = Anime(
            key: "anime",
            title: "Exact Anime",
            cover: "cover"
        )
        let episode = Anime.Episode(
            key: "episode",
            title: nil,
            episode: 3,
            lang: "jp"
        )
        let subject = makeVideoPlayerSubject(anime: anime, episode: episode)
        subject.tracker.anilistID = "123"
        subject.metadata.displayName = "Exact Plugin"

        subject.viewModel.appear()
        subject.viewModel.episodeDidChange()
        subject.viewModel.disappear()

        XCTAssertEqual(subject.presence.presented.count, 2)
        XCTAssertEqual(subject.presence.presented[0].details, "Exact Anime")
        XCTAssertEqual(subject.presence.presented[0].state, "Watching Episode 3.0")
        XCTAssertEqual(subject.presence.presented[0].activityType, 3)
        XCTAssertEqual(
            subject.presence.presented[0].detailsURL,
            "https://anilist.co/anime/123"
        )
        XCTAssertEqual(
            subject.presence.presented[0].largeImageText,
            "Watching from JP at Exact Plugin"
        )
        XCTAssertEqual(subject.presence.presented[0].imageURL, "cover")
        XCTAssertTrue(subject.presence.presented[0].resetTimer)
        XCTAssertFalse(subject.presence.presented[1].resetTimer)
        XCTAssertEqual(subject.presence.clearCount, 1)
    }

    func testDiscordUsesOriginalAndUnknownPluginFallbacks() {
        let subject = makeVideoPlayerSubject(
            episode: Anime.Episode(key: "special", title: "Special")
        )

        subject.viewModel.appear()

        XCTAssertEqual(subject.presence.presented[0].state, "Watching Special")
        XCTAssertEqual(
            subject.presence.presented[0].largeImageText,
            "Watching from Original at Unknown Plugin"
        )
        XCTAssertNil(subject.presence.presented[0].detailsURL)
    }

    func testDisappearPausesShutsDownAndRejectsLatePlayerPreparation() async {
        let first = video("first")
        let second = video("second")
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([first, second])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.playback.enqueue(.suspended, for: "second")
        subject.viewModel.selectVideo(second)
        await subject.playback.waitForPendingCount(1)

        subject.viewModel.close()
        subject.viewModel.disappear()
        subject.playback.resolveFirst(for: "second", preparationID: "late")
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.playback.shutdownCount, 1)
        XCTAssertEqual(subject.playback.pauseCount, 2)
        XCTAssertEqual(subject.playback.observerRemovalCount, 1)
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first"])
    }

    func testDisappearCancelsPresentationChainButDoesNotUndoStartedLocalProgress() async {
        let subject = makeVideoPlayerSubject()
        subject.progress.responses = [.suspended]
        subject.viewModel.playbackTimeDidChange(currentTime: 8, duration: 10)
        await subject.progress.waitUntilPending()

        subject.viewModel.disappear()
        subject.progress.resolveFirst(with: .success(()))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertTrue(subject.viewModel.hasTrackedProgress)
        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertTrue(subject.tracker.requests.isEmpty)
    }

    func testTypedLoggingContainsOnlySafeFields() async {
        let secretURL = "https://secret.example/stream?token=stream-secret"
        let secretSubtitle = "https://secret.example/subtitle?token=subtitle-secret"
        let secretHeader = "Bearer header-secret"
        let secretTitle = "Private Anime Title"
        let anime = Anime(key: "private-anime-key", title: secretTitle)
        let episode = Anime.Episode(key: "private-episode-key", title: "Private Episode")
        let subject = makeVideoPlayerSubject(anime: anime, episode: episode)
        subject.streamLoader.responses = [
            .success([
                video(
                    secretURL,
                    headers: ["Authorization": secretHeader],
                    subtitles: [subtitle(secretSubtitle, language: "English")]
                )
            ])
        ]
        subject.subtitleLoader.enqueue(
            .failure(VideoPlayerTestError.secret("raw-error-secret")),
            for: secretSubtitle
        )

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertFalse(subject.logger.events.isEmpty)
        XCTAssertTrue(subject.logger.events.allSatisfy { $0.feature == .videoPlayer })
        let logs = subject.logger.formattedMessages.joined(separator: "\n")
        for secret in [
            secretURL,
            secretSubtitle,
            secretHeader,
            secretTitle,
            "private-anime-key",
            "private-episode-key",
            "raw-error-secret",
            "Authorization"
        ] {
            XCTAssertFalse(logs.contains(secret), "Typed logs contain \(secret)")
        }
    }
}
