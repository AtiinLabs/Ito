import Combine
import Foundation
import GRDB
import UIKit

/// A cover small enough to keep, already encoded.
nonisolated struct EncodedCoverThumbnail: Equatable, Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int

    /// Whether the table would accept it.
    var isStorable: Bool {
        (1...LibraryCoverThumbnailRecord.maximumByteCount).contains(data.count)
            && (1...LibraryCoverThumbnailRecord.maximumPixelWidth).contains(pixelWidth)
            && (1...LibraryCoverThumbnailRecord.maximumPixelHeight).contains(pixelHeight)
    }
}

/// Shrinks a displayed cover to what a Library card needs and encodes it as JPEG.
nonisolated enum LibraryCoverThumbnailEncoder {
    /// The largest thumbnail, in pixels. A card is at most 140 pt wide.
    static let maximumPixelSize = CGSize(width: 300, height: 450)
    /// Tried in order until the result fits the table's size limit.
    static let compressionQualities: [CGFloat] = [0.75, 0.55, 0.35]

    static func encode(_ image: UIImage) -> EncodedCoverThumbnail? {
        let sourceWidth = image.size.width * image.scale
        let sourceHeight = image.size.height * image.scale
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth >= 1, sourceHeight >= 1 else { return nil }

        // Never enlarge.
        let factor = min(1, maximumPixelSize.width / sourceWidth, maximumPixelSize.height / sourceHeight)
        let target = CGSize(
            width: max(1, (sourceWidth * factor).rounded()),
            height: max(1, (sourceHeight * factor).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in compressionQualities {
            guard let data = rendered.jpegData(compressionQuality: quality) else { return nil }
            let encoded = EncodedCoverThumbnail(
                data: data,
                pixelWidth: Int(target.width),
                pixelHeight: Int(target.height)
            )
            if encoded.isStorable { return encoded }
        }
        return nil
    }
}

/// What storing a thumbnail did.
nonisolated enum LibraryCoverThumbnailStoreOutcome: Equatable, Sendable {
    case stored
    /// The item already has a thumbnail captured for this cover address.
    case alreadyCurrent
    /// The item is gone, or its cover address is no longer the one the image was displayed for.
    case itemChanged
    /// The thumbnail is outside what the table keeps.
    case rejected
}

/// The durable covers of Library items. A thumbnail belongs to its item and is removed with it.
actor LibraryCoverThumbnailStore {
    private let database: DatabasePool
    private let now: @Sendable () -> Date

    init(database: DatabasePool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    /// Keeps `thumbnail` for the item, in one transaction that also requires the item's cover address to
    /// still be `coverUrl`, so an image displayed for an old address is never kept for a new one.
    func store(
        _ thumbnail: EncodedCoverThumbnail,
        itemID: String,
        coverUrl: String
    ) async throws -> LibraryCoverThumbnailStoreOutcome {
        guard thumbnail.isStorable else { return .rejected }
        let coverHash = Self.coverHash(coverUrl)
        let storedAt = now()
        return try await database.write { db in
            guard let item = try LibraryItem.fetchOne(db, key: itemID),
                  let currentCover = item.coverUrl,
                  Self.coverHash(currentCover) == coverHash else {
                return .itemChanged
            }
            if let existing = try LibraryCoverThumbnailRecord.fetchOne(db, key: itemID),
               existing.coverURLSHA256 == coverHash {
                return .alreadyCurrent
            }
            try LibraryCoverThumbnailRecord(
                libraryItemId: itemID,
                coverURLSHA256: coverHash,
                imageData: thumbnail.data,
                pixelWidth: thumbnail.pixelWidth,
                pixelHeight: thumbnail.pixelHeight,
                storedAt: storedAt
            ).save(db)
            return .stored
        }
    }

    /// The encoded thumbnail of this item with the cover address it was captured for, if it has one.
    func storedThumbnail(for itemID: String) async throws -> StoredCoverThumbnail? {
        try await database.read { db in
            try LibraryCoverThumbnailRecord.fetchOne(db, key: itemID).map {
                StoredCoverThumbnail(data: $0.imageData, coverURLSHA256: $0.coverURLSHA256)
            }
        }
    }

    /// Which cover address the item's thumbnail was captured for. A cheap read: it never loads the image.
    func storedCoverHash(for itemID: String) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT coverURLSHA256 FROM libraryCoverThumbnail WHERE libraryItemId = ?",
                arguments: [itemID]
            )
        }
    }

    nonisolated static func coverHash(_ coverUrl: String) -> String {
        OfflineDigest.sha256Hex(Data(coverUrl.utf8))
    }
}

/// A stored thumbnail as it is read back.
nonisolated struct StoredCoverThumbnail: Equatable, Sendable {
    let data: Data
    let coverURLSHA256: String
}

/// A durable cover ready to display, with the cover address it was captured for. A card uses it only while
/// that is still its own cover address.
nonisolated struct LibraryDurableCover: Sendable {
    let image: UIImage
    let coverURLSHA256: String

    /// Approximate decoded size in bytes, for the cache's cost limit.
    var cost: Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}

/// Durable Library covers for the cards. `capture` keeps what a card displayed; `thumbnail` answers when
/// the network cache cannot, such as offline or after the cache was cleared; `forget` drops what is held in
/// memory for items that left the Library.
@MainActor
protocol LibraryCoverThumbnailServing: AnyObject {
    func thumbnail(for itemID: String) async -> LibraryDurableCover?
    func capture(itemID: String, coverUrl: String, image: UIImage)
    func forget(itemIDs: Set<String>)
    var thumbnailChanges: AnyPublisher<String, Never> { get }
}

extension LibraryCoverThumbnailServing {
    var thumbnailChanges: AnyPublisher<String, Never> { Empty().eraseToAnyPublisher() }

    /// The durable cover of an item, only while it was captured for the item's current cover address.
    func thumbnail(itemID: String, coverUrl: String) async -> LibraryDurableCover? {
        guard let cover = await thumbnail(for: itemID),
              cover.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(coverUrl) else { return nil }
        return cover
    }
}

@MainActor
final class LibraryCoverThumbnails: LibraryCoverThumbnailServing {
    private final class CachedCover {
        let cover: LibraryDurableCover
        init(_ cover: LibraryDurableCover) { self.cover = cover }
    }

    private let store: LibraryCoverThumbnailStore
    private let encode: @Sendable (UIImage) -> EncodedCoverThumbnail?
    private let decode: @Sendable (StoredCoverThumbnail) async -> LibraryDurableCover?
    private let cache = NSCache<NSString, CachedCover>()
    /// The cover address each item's thumbnail is known to hold, so a card that appears again does not
    /// touch the database.
    private var recordedHashes: [String: String] = [:]
    private var capturesInFlight: [String: String] = [:]
    /// Bumped whenever an item's stored thumbnail is replaced or the item is forgotten. A read that began
    /// before that is older than the store and must not repopulate the cache.
    private var epochs: [String: UInt64] = [:]
    private var epochClock: UInt64 = 0
    /// Bumped when every stored thumbnail may have changed at once, so no read that began before it can
    /// repopulate the cache either.
    private var storeGeneration: UInt64 = 0
    private let changes = PassthroughSubject<String, Never>()
    var thumbnailChanges: AnyPublisher<String, Never> { changes.eraseToAnyPublisher() }

    init(
        store: LibraryCoverThumbnailStore,
        cacheCostLimit: Int = 16 * 1024 * 1024,
        encode: @escaping @Sendable (UIImage) -> EncodedCoverThumbnail? = { LibraryCoverThumbnailEncoder.encode($0) },
        decode: @escaping @Sendable (StoredCoverThumbnail) async -> LibraryDurableCover? = { LibraryCoverThumbnails.decode($0) }
    ) {
        self.store = store
        self.encode = encode
        self.decode = decode
        cache.totalCostLimit = cacheCostLimit
    }

    convenience init(database: DatabasePool) {
        self.init(store: LibraryCoverThumbnailStore(database: database))
    }

    func thumbnail(for itemID: String) async -> LibraryDurableCover? {
        let key = itemID as NSString
        if let cached = cache.object(forKey: key) { return cached.cover }
        let epoch = epochs[itemID]
        let generation = storeGeneration
        guard let stored = try? await store.storedThumbnail(for: itemID) else { return nil }
        // Decoding is explicitly off the main actor, whatever the module's isolation defaults are.
        let decode = decode
        let decoded = await Task.detached(priority: .userInitiated) { await decode(stored) }.value
        guard let decoded else { return nil }
        // A capture or forget that finished while this read was suspended makes it stale: the caller still
        // checks the cover address, but the cache must not take it back after the eviction.
        if epochs[itemID] == epoch, storeGeneration == generation {
            cache.setObject(CachedCover(decoded), forKey: key, cost: decoded.cost)
        }
        return decoded
    }

    func capture(itemID: String, coverUrl: String, image: UIImage) {
        Task { await record(itemID: itemID, coverUrl: coverUrl, image: image) }
    }

    func forget(itemIDs: Set<String>) {
        for itemID in itemIDs {
            evict(itemID)
            recordedHashes[itemID] = nil
            capturesInFlight[itemID] = nil
        }
    }

    /// Drops everything held in memory, so the next read comes from the store. A restore replaces stored
    /// thumbnails behind this service's back; whatever it held, or was still reading, may be older than that.
    func invalidateAll() {
        cache.removeAllObjects()
        recordedHashes.removeAll()
        capturesInFlight.removeAll()
        storeGeneration &+= 1
    }

    private func evict(_ itemID: String) {
        cache.removeObject(forKey: itemID as NSString)
        epochClock &+= 1
        epochs[itemID] = epochClock
    }

    /// `capture`, awaitable. Skips an image whose cover address is already stored or being stored, before
    /// anything is rendered or encoded.
    func record(itemID: String, coverUrl: String, image: UIImage) async {
        let coverHash = LibraryCoverThumbnailStore.coverHash(coverUrl)
        guard recordedHashes[itemID] != coverHash, capturesInFlight[itemID] != coverHash else { return }
        capturesInFlight[itemID] = coverHash
        let store = store
        let encode = encode
        let outcome = await Task.detached(priority: .utility) { () -> LibraryCoverThumbnailStoreOutcome? in
            // A cheap read first: a thumbnail already kept for this cover needs no encoding. The
            // transaction below still checks it again.
            if (try? await store.storedCoverHash(for: itemID)) == coverHash { return .alreadyCurrent }
            guard let encoded = encode(image) else { return nil }
            return try? await store.store(encoded, itemID: itemID, coverUrl: coverUrl)
        }.value
        // `forget` clears the in-flight entry when the item leaves the Library; a capture finishing
        // after that must not remember a cover for an item that is gone.
        guard capturesInFlight[itemID] == coverHash else { return }
        capturesInFlight[itemID] = nil
        switch outcome {
        case .stored:
            evict(itemID)
            recordedHashes[itemID] = coverHash
            changes.send(itemID)
        case .alreadyCurrent:
            recordedHashes[itemID] = coverHash
        case .itemChanged, .rejected, nil:
            break
        }
    }

    nonisolated static func decode(_ stored: StoredCoverThumbnail) -> LibraryDurableCover? {
        guard let image = UIImage(data: stored.data) else { return nil }
        return LibraryDurableCover(image: image.preparingForDisplay() ?? image, coverURLSHA256: stored.coverURLSHA256)
    }
}

/// Where durable covers are not composed.
@MainActor
final class UnavailableLibraryCoverThumbnails: LibraryCoverThumbnailServing {
    func thumbnail(for itemID: String) async -> LibraryDurableCover? {
        _ = itemID
        return nil
    }

    func capture(itemID: String, coverUrl: String, image: UIImage) {
        _ = itemID
        _ = coverUrl
        _ = image
    }

    func forget(itemIDs: Set<String>) {
        _ = itemIDs
    }
}
