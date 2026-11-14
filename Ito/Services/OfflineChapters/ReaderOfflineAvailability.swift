import Combine
import Foundation
import ito_runner

/// What a reader knows about stored copies and the network, to say where reading stops instead of
/// starting a load that must fail. Bound to one series.
@MainActor
protocol ReaderOfflineAvailability: AnyObject {
    /// Whether offline chapters exist on this build. When false, stored copies and the network change
    /// nothing a reader shows or does, with one exception: a source lock (`locked`) is still reported
    /// as a boundary instead of ending the reader.
    var isAvailable: Bool { get }
    /// Whether the system reports no network.
    var isOffline: Bool { get }
    /// Whether the chapter has a verified copy, by exact chapter key.
    func isVerified(chapterKey: String) -> Bool
    /// Fires after a change that can alter either answer.
    var changes: AnyPublisher<Void, Never> { get }
}

/// What one reader session knows about stored copies and its route, in one place for both readers: where
/// reading stops instead of opening a neighbor, and the downloaded copy offered when an online opening fails.
@MainActor
final class ReaderOfflineContext {
    private let availability: any ReaderOfflineAvailability
    /// The route has no installed source, so only stored chapters can be opened.
    private let isSavedOnly: Bool
    private let downloadedCopy: (any DownloadedCopyReopening)?
    private var subscription: AnyCancellable?

    init(
        availability: any ReaderOfflineAvailability = UnavailableReaderOfflineAvailability(),
        isSavedOnly: Bool = false,
        downloadedCopy: (any DownloadedCopyReopening)? = nil
    ) {
        self.availability = availability
        self.isSavedOnly = isSavedOnly
        self.downloadedCopy = downloadedCopy
    }

    /// Adds what only a reader knows to the ordering's answer. A chapter of the other format opens
    /// elsewhere, and one with neither a copy nor a way to fetch it is not available. Without offline
    /// support, other-reader boundaries retain the earlier end behavior; source locks always remain
    /// explicit boundaries.
    func resolving(
        _ boundary: ReaderChapterBoundary<Chapter>,
        opensHere: (Chapter) -> Bool
    ) -> ReaderChapterBoundary<Chapter> {
        // Source access is a boundary even when this runtime has no offline inventory service.
        // Absence of download support must not disguise a locked neighbor as the end.
        if case .locked = boundary { return boundary }
        guard availability.isAvailable else {
            guard case .chapter(let chapter) = boundary, opensHere(chapter) else { return .end }
            return boundary
        }
        guard case .chapter(let chapter) = boundary else { return boundary }
        guard opensHere(chapter) else { return .otherReader(chapter) }
        // A chapter that reads from the source (chosen so, or loaded there before its copy finished) is
        // not read from its copy, whatever is stored.
        let readsStoredCopy = availability.isVerified(chapterKey: chapter.key)
            && downloadedCopy?.readsFromSource(chapterKey: chapter.key) != true
        if !readsStoredCopy, isSavedOnly || availability.isOffline {
            return .notAvailableOffline(chapter)
        }
        return boundary
    }

    /// Calls `onChange` after a download finishes or the network flips, since either moves a boundary.
    func observe(_ onChange: @escaping @MainActor () -> Void) {
        subscription = availability.changes.sink { onChange() }
    }

    /// Whether the chapter was opened to read online this time and has a verified copy to read instead.
    func canReadDownloadedCopy(chapterKey: String) -> Bool {
        availability.isAvailable
            && availability.isVerified(chapterKey: chapterKey)
            && downloadedCopy?.isReadingRemoteThisTime(chapterKey: chapterKey) == true
    }

    func readDownloadedCopy(chapterKey: String) {
        downloadedCopy?.readDownloadedCopy(chapterKey: chapterKey)
    }
}

/// No offline store: nothing is verified and the device is never offline, so stored copies and the
/// network change nothing. A reader keeps its earlier behavior at a neighbor of the other format
/// (it ends there), but a source lock is still reported as a lock rather than as the end.
@MainActor
final class UnavailableReaderOfflineAvailability: ReaderOfflineAvailability {
    let isAvailable = false
    let isOffline = false

    func isVerified(chapterKey: String) -> Bool { false }

    var changes: AnyPublisher<Void, Never> {
        Empty(completeImmediately: false).eraseToAnyPublisher()
    }
}

/// Reads the download center's observed state for one series and the shared connectivity seam. It
/// reports a change only when a chapter gains or loses its verified copy or the network flips, not on
/// download progress.
@MainActor
final class ObservedReaderOfflineAvailability: ReaderOfflineAvailability {
    private var verifiedKeys: Set<String> = []
    private var offline: Bool
    private let changeSubject = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []

    init(
        media: MediaIdentity,
        downloads: any MediaDetailDownloadServing,
        connectivity: any ConnectivityServing
    ) {
        offline = connectivity.isOffline
        // The center replays its current state, so the first value is in place before this returns.
        downloads.chapterStates(for: media)
            .sink { [weak self] states in
                let verified = Set(states.filter { $0.value == .downloaded }.keys)
                guard let self, verified != self.verifiedKeys else { return }
                self.verifiedKeys = verified
                self.changeSubject.send()
            }
            .store(in: &cancellables)
        connectivity.isOfflinePublisher
            .sink { [weak self] isOffline in
                guard let self, isOffline != self.offline else { return }
                self.offline = isOffline
                self.changeSubject.send()
            }
            .store(in: &cancellables)
    }

    let isAvailable = true

    var isOffline: Bool { offline }

    func isVerified(chapterKey: String) -> Bool {
        verifiedKeys.contains(chapterKey)
    }

    var changes: AnyPublisher<Void, Never> {
        changeSubject.eraseToAnyPublisher()
    }
}
