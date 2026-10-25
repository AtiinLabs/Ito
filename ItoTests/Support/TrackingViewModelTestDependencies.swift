import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class TrackingCallJournal {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

enum TrackingTestError: Error {
    case failure
    case secret(String)
}

@MainActor
final class TrackingMessageCaptureSpy: TrackingMessagePresenting {
    private(set) var messages: [TrackingMessage] = []

    func present(_ message: TrackingMessage) {
        messages.append(message)
    }
}

@MainActor
final class TrackerOAuthAuthenticatorFake: TrackerOAuthAuthenticating {
    var error: (any Error)?
    private(set) var providerIDs: [String] = []

    func authenticate(provider: any TrackerProvider) async throws {
        providerIDs.append(provider.identifier)
        if let error { throw error }
    }
}

@MainActor
final class TrackerSheetServiceFake: TrackerSheetServicing {
    private let sheetStateSubject = PassthroughSubject<Void, Never>()
    var providers: [TrackerProviderPresentation]
    var remoteIDs: [MediaIdentity: [String: String]]
    var locallyLinkedMedia: Set<MediaIdentity>
    var refreshError: (any Error)?
    private(set) var lookupRequests: [(media: MediaIdentity, providerID: String)] = []
    private(set) var refreshCount = 0

    var sheetStatePublisher: AnyPublisher<Void, Never> {
        sheetStateSubject.eraseToAnyPublisher()
    }

    init(
        providers: [TrackerProviderPresentation] = [],
        remoteIDs: [MediaIdentity: [String: String]] = [:],
        locallyLinkedMedia: Set<MediaIdentity> = []
    ) {
        self.providers = providers
        self.remoteIDs = remoteIDs
        self.locallyLinkedMedia = locallyLinkedMedia
    }

    func authenticatedProviders() -> [TrackerProviderPresentation] {
        providers
    }

    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String? {
        lookupRequests.append((media, providerID))
        return remoteIDs[media]?[providerID]
    }

    func hasAuthenticatedLink(for media: MediaIdentity) -> Bool {
        locallyLinkedMedia.contains(media)
    }

    func refreshState() async throws {
        refreshCount += 1
        if let refreshError { throw refreshError }
    }

    func sendStateChange() {
        sheetStateSubject.send()
    }
}

@MainActor
final class TrackerSettingsServiceFake: TrackerSettingsServicing {
    private struct PendingOperation {
        let providerID: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let subject: CurrentValueSubject<TrackerSettingsAuthoritativeState, Never>
    private var pendingAuthentication: [PendingOperation] = []
    private var pendingLogout: [PendingOperation] = []

    var suspendsAuthentication = false
    var suspendsLogout = false
    var authenticationError: (any Error)?
    var logoutError: (any Error)?
    private(set) var authenticationInvocations: [String] = []
    private(set) var logoutInvocations: [String] = []
    private(set) var tokenAuthenticationInvocations: [(providerID: String, token: String)] = []
    private(set) var refreshCount = 0

    init(state: TrackerSettingsAuthoritativeState) {
        subject = CurrentValueSubject(state)
    }

    var settingsState: TrackerSettingsAuthoritativeState { subject.value }

    var settingsStatePublisher: AnyPublisher<TrackerSettingsAuthoritativeState, Never> {
        subject.eraseToAnyPublisher()
    }

    var pendingAuthenticationCount: Int { pendingAuthentication.count }
    var pendingLogoutCount: Int { pendingLogout.count }

    func authenticate(providerID: String) async throws {
        authenticationInvocations.append(providerID)
        if suspendsAuthentication {
            try await withCheckedThrowingContinuation { continuation in
                pendingAuthentication.append(
                    PendingOperation(providerID: providerID, continuation: continuation)
                )
            }
            return
        }
        if let authenticationError { throw authenticationError }
    }

    func authenticate(providerID: String, token: String) async throws {
        tokenAuthenticationInvocations.append((providerID, token))
        if let authenticationError { throw authenticationError }
    }

    func logout(providerID: String) async throws {
        logoutInvocations.append(providerID)
        if suspendsLogout {
            try await withCheckedThrowingContinuation { continuation in
                pendingLogout.append(
                    PendingOperation(providerID: providerID, continuation: continuation)
                )
            }
            return
        }
        if let logoutError { throw logoutError }
    }

    func refreshSettingsState() {
        refreshCount += 1
    }

    func send(_ state: TrackerSettingsAuthoritativeState) {
        subject.send(state)
    }

    func completeAuthentication(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingAuthentication.remove(at: index)
        pending.continuation.resume(with: result)
    }

    func completeLogout(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingLogout.remove(at: index)
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class TrackingPreferenceStoreFake: TrackerSettingsPreferenceStoring {
    private struct PendingWrite {
        let value: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    var autoSyncTrackersToLocal: Bool
    var suspendsWrites = false
    var nextError: (any Error)?
    private(set) var invocations: [Bool] = []
    private var pendingWrites: [PendingWrite] = []

    init(initialValue: Bool) {
        autoSyncTrackersToLocal = initialValue
    }

    var pendingWriteCount: Int { pendingWrites.count }

    func setAutoSyncTrackersToLocal(_ value: Bool) async throws {
        invocations.append(value)
        if suspendsWrites {
            try await withCheckedThrowingContinuation { continuation in
                pendingWrites.append(PendingWrite(value: value, continuation: continuation))
            }
            return
        }
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        autoSyncTrackersToLocal = value
    }

    func completeWrite(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingWrites.remove(at: index)
        if case .success = result {
            autoSyncTrackersToLocal = pending.value
        }
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class TrackerSearchServiceFake: TrackerSearchServicing {
    struct Invocation: Equatable {
        let providerID: String
        let title: String
        let isAnime: Bool
    }

    private struct PendingSearch {
        let invocation: Invocation
        let continuation: CheckedContinuation<[TrackerMedia], any Error>
    }

    var suspendsSearches = false
    var queuedResults: [Result<[TrackerMedia], any Error>] = []
    private(set) var invocations: [Invocation] = []
    private var pendingSearches: [PendingSearch] = []

    var pendingCount: Int { pendingSearches.count }
    var pendingTitles: [String] { pendingSearches.map(\.invocation.title) }

    func searchMedia(
        providerID: String,
        title: String,
        isAnime: Bool
    ) async throws -> [TrackerMedia] {
        let invocation = Invocation(providerID: providerID, title: title, isAnime: isAnime)
        invocations.append(invocation)
        if suspendsSearches {
            return try await withCheckedThrowingContinuation { continuation in
                pendingSearches.append(
                    PendingSearch(invocation: invocation, continuation: continuation)
                )
            }
        }
        guard !queuedResults.isEmpty else { return [] }
        return try queuedResults.removeFirst().get()
    }

    func complete(
        at index: Int = 0,
        with result: Result<[TrackerMedia], any Error>
    ) {
        let pending = pendingSearches.remove(at: index)
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class TrackerDetailsServiceFake: TrackerDetailsServicing {
    struct UpdateInvocation: Equatable {
        let providerID: String
        let mediaID: String
        let progress: Int?
        let status: String?
    }

    private struct PendingLoad {
        let continuation: CheckedContinuation<TrackerMediaEntry?, any Error>
    }

    private struct PendingUpdate {
        let continuation: CheckedContinuation<Void, any Error>
    }

    var suspendsLoads = false
    var suspendsUpdates = false
    var queuedLoadResults: [Result<TrackerMediaEntry?, any Error>] = []
    var queuedUpdateResults: [Result<Void, any Error>] = []
    private(set) var loadInvocations: [(providerID: String, mediaID: String)] = []
    private(set) var updateInvocations: [UpdateInvocation] = []
    private var pendingLoads: [PendingLoad] = []
    private var pendingUpdates: [PendingUpdate] = []
    let journal: TrackingCallJournal?

    init(journal: TrackingCallJournal? = nil) {
        self.journal = journal
    }

    var pendingLoadCount: Int { pendingLoads.count }
    var pendingUpdateCount: Int { pendingUpdates.count }

    func getMediaListEntry(
        providerID: String,
        mediaID: String
    ) async throws -> TrackerMediaEntry? {
        loadInvocations.append((providerID, mediaID))
        journal?.record("load")
        if suspendsLoads {
            return try await withCheckedThrowingContinuation { continuation in
                pendingLoads.append(PendingLoad(continuation: continuation))
            }
        }
        guard !queuedLoadResults.isEmpty else { return nil }
        return try queuedLoadResults.removeFirst().get()
    }

    func updateProgress(
        providerID: String,
        mediaID: String,
        progress: Int?,
        status: String?
    ) async throws {
        updateInvocations.append(
            UpdateInvocation(
                providerID: providerID,
                mediaID: mediaID,
                progress: progress,
                status: status
            )
        )
        journal?.record("update")
        if suspendsUpdates {
            try await withCheckedThrowingContinuation { continuation in
                pendingUpdates.append(PendingUpdate(continuation: continuation))
            }
            return
        }
        guard !queuedUpdateResults.isEmpty else { return }
        try queuedUpdateResults.removeFirst().get()
    }

    func completeLoad(
        at index: Int = 0,
        with result: Result<TrackerMediaEntry?, any Error>
    ) {
        let pending = pendingLoads.remove(at: index)
        pending.continuation.resume(with: result)
    }

    func completeUpdate(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingUpdates.remove(at: index)
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class TrackerLinkStoreFake: TrackerLinkPersisting {
    struct LinkInvocation {
        let media: MediaIdentity
        let providerID: String
        let remoteMediaID: String
    }

    struct UnlinkInvocation {
        let media: MediaIdentity
        let providerID: String
    }

    private struct PendingLink {
        let invocation: LinkInvocation
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingUnlink {
        let invocation: UnlinkInvocation
        let continuation: CheckedContinuation<Void, any Error>
    }

    var remoteIDs: [MediaIdentity: [String: String]] = [:]
    var suspendsLinks = false
    var suspendsUnlinks = false
    var linkError: (any Error)?
    var unlinkError: (any Error)?
    private(set) var linkInvocations: [LinkInvocation] = []
    private(set) var unlinkInvocations: [UnlinkInvocation] = []
    private var pendingLinks: [PendingLink] = []
    private var pendingUnlinks: [PendingUnlink] = []
    let journal: TrackingCallJournal?

    init(journal: TrackingCallJournal? = nil) {
        self.journal = journal
    }

    var pendingLinkCount: Int { pendingLinks.count }
    var pendingUnlinkCount: Int { pendingUnlinks.count }

    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String? {
        remoteIDs[media]?[providerID]
    }

    func link(
        media: MediaIdentity,
        providerID: String,
        remoteMediaID: String
    ) async throws {
        let invocation = LinkInvocation(
            media: media,
            providerID: providerID,
            remoteMediaID: remoteMediaID
        )
        linkInvocations.append(invocation)
        journal?.record("link")
        if suspendsLinks {
            try await withCheckedThrowingContinuation { continuation in
                pendingLinks.append(PendingLink(invocation: invocation, continuation: continuation))
            }
            return
        }
        if let linkError { throw linkError }
        remoteIDs[media, default: [:]][providerID] = remoteMediaID
    }

    func unlink(media: MediaIdentity, providerID: String) async throws {
        let invocation = UnlinkInvocation(media: media, providerID: providerID)
        unlinkInvocations.append(invocation)
        journal?.record("unlink")
        if suspendsUnlinks {
            try await withCheckedThrowingContinuation { continuation in
                pendingUnlinks.append(
                    PendingUnlink(invocation: invocation, continuation: continuation)
                )
            }
            return
        }
        if let unlinkError { throw unlinkError }
        remoteIDs[media]?.removeValue(forKey: providerID)
    }

    func completeLink(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingLinks.remove(at: index)
        if case .success = result {
            remoteIDs[pending.invocation.media, default: [:]][pending.invocation.providerID] =
                pending.invocation.remoteMediaID
        }
        pending.continuation.resume(with: result)
    }

    func completeUnlink(
        at index: Int = 0,
        with result: Result<Void, any Error>
    ) {
        let pending = pendingUnlinks.remove(at: index)
        if case .success = result {
            remoteIDs[pending.invocation.media]?.removeValue(
                forKey: pending.invocation.providerID
            )
        }
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class TrackerLocalProgressReaderFake: TrackerLocalProgressReading {
    var progress: Set<Float>
    private(set) var mediaRequests: [MediaIdentity] = []

    init(progress: Set<Float> = []) {
        self.progress = progress
    }

    func readProgress(for media: MediaIdentity) -> Set<Float> {
        mediaRequests.append(media)
        return progress
    }
}

@MainActor
final class TrackerExternalURLOpenerFake: TrackerExternalURLOpening {
    struct Invocation {
        let providerID: String
        let media: TrackerMedia
    }

    var error: (any Error)?
    private(set) var invocations: [Invocation] = []

    func open(providerID: String, media: TrackerMedia) async throws {
        invocations.append(Invocation(providerID: providerID, media: media))
        if let error { throw error }
    }
}

@MainActor
final class TrackerApplicationURLOpenerFake: TrackerApplicationURLOpening {
    var error: (any Error)?
    private(set) var urls: [URL] = []

    func open(_ url: URL) async throws {
        urls.append(url)
        if let error { throw error }
    }
}

@MainActor
func trackerTestMedia(
    id: String = "remote-1",
    title: String = "Exact Title",
    format: String? = "MANGA",
    episodes: Int? = nil,
    chapters: Int? = 12
) -> TrackerMedia {
    TrackerMedia(
        id: id,
        title: title,
        titleRomaji: nil,
        coverImage: nil,
        format: format,
        episodes: episodes,
        chapters: chapters
    )
}

@MainActor
func trackerTestDestination(
    media: TrackerMedia? = nil,
    isLocallyLinked: Bool = false,
    showCancelButton: Bool = false,
    providerID: String = "anilist",
    providerName: String = "AniList",
    mediaIdentity: MediaIdentity? = nil
) -> TrackerDetailsDestination {
    TrackerDetailsDestination(
        providerID: providerID,
        providerName: providerName,
        mediaIdentity: mediaIdentity ?? MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "media.test", mediaKind: .manga),
        media: media ?? trackerTestMedia(),
        showCancelButton: showCancelButton,
        isLocallyLinked: isLocallyLinked
    )
}

@MainActor
func trackingWaitUntil(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition was not met before timeout", file: file, line: line)
}
