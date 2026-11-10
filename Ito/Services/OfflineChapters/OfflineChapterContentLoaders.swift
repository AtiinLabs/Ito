import Foundation
import ito_runner

/// Where one opening of the reader reads its chapter from. Nothing here is stored: it applies to this
/// reader only, so the next opening starts local-first again.
nonisolated enum ReaderContentPreference: Equatable, Sendable {
    /// A verified copy first, then the installed source.
    case localFirst
    /// The installed source reads this chapter even if a copy exists. Its neighbors stay local-first.
    case remoteThisTime(chapterKey: String)

    var initialRemoteKeys: Set<String> {
        switch self {
        case .localFirst: []
        case .remoteThisTime(let chapterKey): [chapterKey]
        }
    }
}

/// A loader that can drop a "read online this time" choice, so the chapter reads from its downloaded copy.
@MainActor
protocol DownloadedCopyReopening: AnyObject {
    /// Whether the chapter is held on the installed source for this reading only.
    func isReadingRemoteThisTime(chapterKey: String) -> Bool
    /// Whether the chapter is read from the installed source rather than a stored copy.
    func readsFromSource(chapterKey: String) -> Bool
    /// Reads the chapter local-first from now on, as a reader opened without the choice would.
    func readDownloadedCopy(chapterKey: String)
}

/// Chooses where one chapter is read from. The choice is pinned on first use, so an open chapter keeps
/// its source when a download finishes, a copy is deleted, or the network changes. Pins last as long
/// as the loader that owns this resolver.
@MainActor
final class OfflineChapterSourceResolver {
    enum Source {
        case local(OfflineChapterLease)
        case remote
    }

    private let pluginID: String
    private let local: any OfflineChapterReading
    private let hasRemote: Bool
    /// Chapters that read from the source whatever is stored, until the user asks for the copy.
    private var remoteKeys: Set<String>
    private var pins: [String: Source] = [:]

    init(
        pluginID: String,
        local: any OfflineChapterReading,
        hasRemote: Bool,
        initialRemoteKeys: Set<String> = []
    ) {
        self.pluginID = pluginID
        self.local = local
        self.hasRemote = hasRemote
        remoteKeys = initialRemoteKeys
    }

    /// A verified copy with the exact chapter key wins and involves no plugin or network call, unless the
    /// chapter was chosen to read online this time. Otherwise the installed source reads the chapter. With
    /// neither, the chapter is not downloaded.
    func source(for entry: MediaEntry, chapter: Chapter) async throws -> Source {
        if let pinned = pins[chapter.key] {
            return pinned
        }
        if hasRemote, remoteKeys.contains(chapter.key) {
            return pin(.remote, for: chapter.key)
        }
        let edition = OfflineChapterEdition(
            pluginId: pluginID,
            mediaKind: entry.kind,
            canonicalMediaId: entry.key,
            chapterKey: chapter.key
        )
        if await local.verifiedEdition(edition) {
            do {
                let lease = try await local.openLease(edition)
                return pin(.local(lease), for: chapter.key)
            } catch OfflineStoreError.protectedDataUnavailable {
                throw OfflineReadError.protectedDataUnavailable
            } catch {
                // Removed, damaged, or changed since the check: this copy is not readable now, so the
                // installed source (if any) reads the chapter instead.
            }
        }
        guard hasRemote else { throw OfflineReadError.notDownloaded }
        return pin(.remote, for: chapter.key)
    }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        hasRemote && remoteKeys.contains(chapterKey)
    }

    /// Whether the chapter is read from the installed source: chosen so for this reading, or pinned there
    /// because it had no readable copy when it was loaded.
    func readsFromSource(chapterKey: String) -> Bool {
        if case .remote? = pins[chapterKey] { return true }
        return isReadingRemoteThisTime(chapterKey: chapterKey)
    }

    /// Ends a "read online this time" choice. The chapter's source is decided again, local-first, on its
    /// next load. A copy the reader already holds open is never dropped.
    func readLocalFirst(chapterKey: String) {
        guard remoteKeys.remove(chapterKey) != nil else { return }
        if case .remote? = pins[chapterKey] { pins[chapterKey] = nil }
    }

    /// Reads the pages of a leased copy. Text is read and verified off the main actor; images stay on
    /// disk and are fetched through their locator by the offline image pipeline. A copy that turns out
    /// damaged or missing on disk is unpinned when a source can read the chapter instead, and the
    /// result is nil so the caller reads from the source.
    func localPages(_ lease: OfflineChapterLease, chapter: Chapter) async throws -> [Page]? {
        let reader = local
        do {
            return try await Task.detached(priority: .utility) {
                try OfflineChapterPages.make(from: lease, reader: reader)
            }.value
        } catch let error as OfflineStoreError where hasRemote && error.isUnreadableCopy {
            pins[chapter.key] = .remote
            return nil
        }
    }

    private func pin(_ source: Source, for chapterKey: String) -> Source {
        // A concurrent load may have pinned first; its choice wins and this one is dropped.
        if let existing = pins[chapterKey] {
            return existing
        }
        pins[chapterKey] = source
        return source
    }
}

nonisolated enum OfflineChapterPages {
    static func make(from lease: OfflineChapterLease, reader: any OfflineChapterReading) throws -> [Page] {
        try lease.manifest.pages.map { manifestPage throws -> Page in
            let description = manifestPage.description
            switch manifestPage.kind {
            case .image:
                return Page(
                    index: Int32(manifestPage.index),
                    content: .url(OfflineAssetLocator.makeURLString(token: lease.token, fileName: manifestPage.file)),
                    hasDescription: description != nil,
                    description: description
                )
            case .text:
                guard let leased = lease.page(fileName: manifestPage.file) else {
                    throw OfflineAssetError.leaseReleased
                }
                let data = try reader.readVerifiedPage(leased)
                // The bytes match the manifest digest, so non-UTF-8 text means the copy itself is damaged.
                guard let text = String(bytes: data, encoding: .utf8) else {
                    throw OfflineStoreError.damaged(.pageMismatch)
                }
                return Page(
                    index: Int32(manifestPage.index),
                    content: .text(text),
                    hasDescription: description != nil,
                    description: description
                )
            }
        }
    }
}

/// Manga pages: the verified local copy first, then the installed source.
@MainActor
final class ResolvingMangaPageLoader: MangaPageLoading, DownloadedCopyReopening {
    /// The installed source's loader, or nil on saved-only routes.
    let remote: (any MangaPageLoading)?
    private let resolver: OfflineChapterSourceResolver

    init(
        pluginID: String,
        local: any OfflineChapterReading,
        remote: (any MangaPageLoading)?,
        preference: ReaderContentPreference = .localFirst
    ) {
        self.remote = remote
        resolver = OfflineChapterSourceResolver(
            pluginID: pluginID,
            local: local,
            hasRemote: remote != nil,
            initialRemoteKeys: preference.initialRemoteKeys
        )
    }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        resolver.isReadingRemoteThisTime(chapterKey: chapterKey)
    }

    func readsFromSource(chapterKey: String) -> Bool {
        resolver.readsFromSource(chapterKey: chapterKey)
    }

    func readDownloadedCopy(chapterKey: String) {
        resolver.readLocalFirst(chapterKey: chapterKey)
    }

    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        if case .local(let lease) = try await resolver.source(for: entry, chapter: chapter),
           let pages = try await resolver.localPages(lease, chapter: chapter) {
            return pages
        }
        guard let remote else { throw OfflineReadError.notDownloaded }
        return try await remote.pages(for: entry, chapter: chapter)
    }
}

/// Novel and text-chapter pages: the verified local copy first, then the installed source.
@MainActor
final class ResolvingNovelChapterLoader: NovelChapterLoading, DownloadedCopyReopening {
    /// The installed source's loader, or nil on saved-only routes.
    let remote: (any NovelChapterLoading)?
    private let resolver: OfflineChapterSourceResolver

    init(
        pluginID: String,
        local: any OfflineChapterReading,
        remote: (any NovelChapterLoading)?,
        preference: ReaderContentPreference = .localFirst
    ) {
        self.remote = remote
        resolver = OfflineChapterSourceResolver(
            pluginID: pluginID,
            local: local,
            hasRemote: remote != nil,
            initialRemoteKeys: preference.initialRemoteKeys
        )
    }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        resolver.isReadingRemoteThisTime(chapterKey: chapterKey)
    }

    func readsFromSource(chapterKey: String) -> Bool {
        resolver.readsFromSource(chapterKey: chapterKey)
    }

    func readDownloadedCopy(chapterKey: String) {
        resolver.readLocalFirst(chapterKey: chapterKey)
    }

    func content(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        if case .local(let lease) = try await resolver.source(for: entry, chapter: chapter),
           let pages = try await resolver.localPages(lease, chapter: chapter) {
            return pages
        }
        guard let remote else { throw OfflineReadError.notDownloaded }
        return try await remote.content(for: entry, chapter: chapter)
    }
}

private extension OfflineStoreError {
    /// The copy is in the inventory but its bytes cannot be read or verified.
    nonisolated var isUnreadableCopy: Bool {
        switch self {
        case .damaged, .versionUnavailable:
            true
        case .reconciliationPending, .blocked, .jobUnavailable, .notVerified, .protectedDataUnavailable:
            false
        }
    }
}
