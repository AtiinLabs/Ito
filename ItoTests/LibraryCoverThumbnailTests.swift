import Foundation
import GRDB
import Testing
import UIKit
import ito_runner
@testable import Ito

/// The durable Library cover: captured from the cover a card already displayed, kept with its item, and
/// removed with it.
@MainActor
struct LibraryCoverThumbnailTests {
    private nonisolated static let pluginId = "plugin.test"
    private nonisolated static let coverA = "https://example.com/a.jpg"
    private nonisolated static let coverB = "https://example.com/b.jpg"

    private func makeDatabase(coverUrl: String? = LibraryCoverThumbnailTests.coverA) async throws -> TestDatabase {
        let database = try TestDatabase()
        try await database.dbPool.write { db in
            try LibraryItem(
                id: "series-1",
                title: "Series",
                coverUrl: coverUrl,
                pluginId: Self.pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: Data("payload".utf8),
                anilistId: nil
            ).insert(db)
        }
        return database
    }

    private func image(width: Int, height: Int, color: UIColor = .systemTeal) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func thumbnail(width: Int = 20, height: Int = 30, byte: UInt8 = 1) -> EncodedCoverThumbnail {
        EncodedCoverThumbnail(data: Data([byte, byte]), pixelWidth: width, pixelHeight: height)
    }

    private func rowCount(_ database: TestDatabase) async throws -> Int {
        try await database.dbPool.read { db in try LibraryCoverThumbnailRecord.fetchCount(db) }
    }

    // MARK: - Encoding

    @Test func aLargeCoverIsShrunkToTheThumbnailBoundsAndKeepsItsShape() throws {
        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(image(width: 1200, height: 1800)))

        #expect(encoded.pixelWidth <= 300)
        #expect(encoded.pixelHeight <= 450)
        #expect(encoded.pixelWidth == 300)
        #expect(encoded.pixelHeight == 450)
        #expect(encoded.isStorable)
        let decoded = try #require(UIImage(data: encoded.data))
        #expect(Int(decoded.size.width * decoded.scale) == encoded.pixelWidth)
        #expect(Int(decoded.size.height * decoded.scale) == encoded.pixelHeight)
    }

    @Test func aWideCoverIsLimitedByItsWidth() throws {
        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(image(width: 1000, height: 100)))

        #expect(encoded.pixelWidth == 300)
        #expect(encoded.pixelHeight == 30)
    }

    @Test func aSmallCoverIsNotEnlarged() throws {
        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(image(width: 100, height: 150)))

        #expect(encoded.pixelWidth == 100)
        #expect(encoded.pixelHeight == 150)
    }

    @Test func aNoisyCoverStillFitsTheTableLimit() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var generator = SplitMix64(seed: 0x1705)
        let noisy = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { context in
            for y in stride(from: 0, to: 900, by: 3) {
                for x in stride(from: 0, to: 600, by: 3) {
                    UIColor(
                        red: .random(in: 0...1, using: &generator),
                        green: .random(in: 0...1, using: &generator),
                        blue: .random(in: 0...1, using: &generator),
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 3, height: 3))
                }
            }
        }

        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(noisy))

        #expect(encoded.isStorable)
        #expect(encoded.data.count <= LibraryCoverThumbnailRecord.maximumByteCount)
    }

    @Test func anImageWithNoAreaIsNotEncoded() {
        #expect(LibraryCoverThumbnailEncoder.encode(UIImage()) == nil)
    }

    // MARK: - Store lifecycle

    @Test func theStoreKeepsOneThumbnailPerItemAndSkipsOneItAlreadyHasForTheSameCover() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)

        #expect(try await store.store(thumbnail(byte: 1), itemID: "series-1", coverUrl: Self.coverA) == .stored)
        #expect(try await store.store(thumbnail(byte: 2), itemID: "series-1", coverUrl: Self.coverA) == .alreadyCurrent)

        #expect(try await store.storedThumbnail(for: "series-1")?.data == Data([1, 1]))
        #expect(try await rowCount(database) == 1)
        let row = try #require(try await database.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchOne(db, key: "series-1")
        })
        #expect(row.coverURLSHA256 == OfflineDigest.sha256Hex(Data(Self.coverA.utf8)))
    }

    @Test func aChangedCoverAddressReplacesTheThumbnailOnTheNextLoad() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        #expect(try await store.store(thumbnail(byte: 1), itemID: "series-1", coverUrl: Self.coverA) == .stored)
        try await database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET coverUrl = ? WHERE id = 'series-1'", arguments: [Self.coverB])
        }

        // An image displayed for the old address is never kept for the new one.
        #expect(try await store.store(thumbnail(byte: 9), itemID: "series-1", coverUrl: Self.coverA) == .itemChanged)
        #expect(try await store.storedThumbnail(for: "series-1")?.data == Data([1, 1]))

        #expect(try await store.store(thumbnail(byte: 2), itemID: "series-1", coverUrl: Self.coverB) == .stored)
        #expect(try await store.storedThumbnail(for: "series-1")?.data == Data([2, 2]))
        #expect(try await rowCount(database) == 1)
    }

    @Test func nothingIsKeptForAnItemThatIsGoneOrHasNoCover() async throws {
        let database = try await makeDatabase(coverUrl: nil)
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)

        #expect(try await store.store(thumbnail(), itemID: "series-1", coverUrl: Self.coverA) == .itemChanged)
        #expect(try await store.store(thumbnail(), itemID: "missing", coverUrl: Self.coverA) == .itemChanged)
        #expect(try await rowCount(database) == 0)
    }

    @Test func aThumbnailOutsideTheTableLimitsIsRejectedBeforeItReachesTheTable() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        let oversized = EncodedCoverThumbnail(
            data: Data(count: LibraryCoverThumbnailRecord.maximumByteCount + 1),
            pixelWidth: 10,
            pixelHeight: 10
        )

        #expect(try await store.store(oversized, itemID: "series-1", coverUrl: Self.coverA) == .rejected)
        #expect(try await store.store(thumbnail(width: 0), itemID: "series-1", coverUrl: Self.coverA) == .rejected)
        #expect(try await store.store(thumbnail(height: 1537), itemID: "series-1", coverUrl: Self.coverA) == .rejected)
        #expect(try await store.store(
            EncodedCoverThumbnail(data: Data(), pixelWidth: 10, pixelHeight: 10),
            itemID: "series-1",
            coverUrl: Self.coverA
        ) == .rejected)
        #expect(try await rowCount(database) == 0)
    }

    @Test func removingTheSeriesFromTheLibraryRemovesItsThumbnail() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        #expect(try await store.store(thumbnail(), itemID: "series-1", coverUrl: Self.coverA) == .stored)
        let manager = LibraryManager(dbPool: database.dbPool)

        try await manager.removeItemDurably(
            media: MediaIdentity(pluginId: Self.pluginId, canonicalMediaId: "series-1", mediaKind: .manga)
        )

        #expect(try await rowCount(database) == 0)
        #expect(try await store.storedThumbnail(for: "series-1")?.data == nil)
    }

    @Test func relinkingTheSeriesRemovesTheThumbnailOfItsOldItem() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        #expect(try await store.store(thumbnail(), itemID: "series-1", coverUrl: Self.coverA) == .stored)

        _ = try await LibrarySourceRemapper(dbPool: database.dbPool).relink(
            pluginId: Self.pluginId,
            mediaKind: .manga,
            possibleSourceItemIds: ["series-1"],
            destinationItemId: "series-2",
            title: "Relinked",
            coverUrl: Self.coverA,
            rawPayload: Data("relinked".utf8)
        )

        #expect(try await rowCount(database) == 0)
        // The new item gets its own thumbnail from its own next cover load.
        #expect(try await store.store(thumbnail(), itemID: "series-2", coverUrl: Self.coverA) == .stored)
    }

    @Test func remappingTheSeriesToAnotherSourceRemovesTheThumbnailOfItsOldItem() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        #expect(try await store.store(thumbnail(), itemID: "series-1", coverUrl: Self.coverA) == .stored)

        _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: Self.pluginId,
            newPluginId: "plugin.other",
            affectedItemIds: ["series-1"]
        )

        #expect(try await rowCount(database) == 0)
    }

    // MARK: - Service

    @Test func aCapturedCoverIsReadBackAsAnImage() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let service = LibraryCoverThumbnails(database: database.dbPool)

        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 600, height: 900))

        let cover = try #require(await service.thumbnail(for: "series-1"))
        #expect(Int(cover.image.size.width * cover.image.scale) == 300)
        #expect(Int(cover.image.size.height * cover.image.scale) == 450)
        // It says which cover address it was captured for, so a card can tell whether it still applies.
        #expect(cover.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(Self.coverA))
        #expect(await service.thumbnail(for: "series-2") == nil)
    }

    @Test func aSecondServiceReadsTheThumbnailTheFirstKept() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        await LibraryCoverThumbnails(database: database.dbPool)
            .record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))

        // A new process, an empty network cache: the card still has its cover.
        let afterRelaunch = LibraryCoverThumbnails(database: database.dbPool)

        #expect(await afterRelaunch.thumbnail(for: "series-1") != nil)
    }

    @Test func aCoverTheServiceAlreadyKeptIsNotWrittenAgainInTheSameSession() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let service = LibraryCoverThumbnails(database: database.dbPool)
        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))
        try await database.dbPool.write { db in
            _ = try LibraryCoverThumbnailRecord.deleteAll(db)
        }

        // The card appears again with the same cover: the service does not touch the database.
        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))

        #expect(try await rowCount(database) == 0)
    }

    @Test func aFreshServiceWithACurrentRowNeitherEncodesNorWrites() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        #expect(try await store.store(thumbnail(byte: 7), itemID: "series-1", coverUrl: Self.coverA) == .stored)
        let before = try #require(try await database.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchOne(db, key: "series-1")
        })
        let encodes = EncodeCounter()
        let service = LibraryCoverThumbnails(store: store) { image in
            encodes.increment()
            return LibraryCoverThumbnailEncoder.encode(image)
        }

        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))

        #expect(encodes.count == 0)
        let after = try #require(try await database.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchOne(db, key: "series-1")
        })
        #expect(after == before)
        // Whereas a cover that is not stored yet is encoded.
        await service.record(itemID: "series-1", coverUrl: Self.coverB, image: image(width: 300, height: 450))
        #expect(encodes.count == 1)
    }

    @Test func forgettingAnItemDropsWhatTheServiceHoldsForIt() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let service = LibraryCoverThumbnails(database: database.dbPool)
        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))
        #expect(await service.thumbnail(for: "series-1") != nil)
        try await database.dbPool.write { db in
            _ = try LibraryCoverThumbnailRecord.deleteAll(db)
        }
        // Still served from memory.
        #expect(await service.thumbnail(for: "series-1") != nil)

        service.forget(itemIDs: ["series-1"])

        #expect(await service.thumbnail(for: "series-1") == nil)
        // And a returning item is captured again, as the recorded cover address was forgotten too.
        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))
        #expect(try await rowCount(database) == 1)
    }

    @Test func aNewCoverReplacesTheThumbnailAndTheCachedImage() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let service = LibraryCoverThumbnails(database: database.dbPool)
        await service.record(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 300, height: 450))
        #expect(await service.thumbnail(for: "series-1")?.image.size.width == 300)
        try await database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET coverUrl = ? WHERE id = 'series-1'", arguments: [Self.coverB])
        }

        await service.record(itemID: "series-1", coverUrl: Self.coverB, image: image(width: 150, height: 225))

        #expect(await service.thumbnail(for: "series-1")?.image.size.width == 150)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aReadThatBeganBeforeANewCaptureNeverRepopulatesTheCache() async throws {
        let database = try await makeDatabase()
        defer { database.cleanup() }
        let store = LibraryCoverThumbnailStore(database: database.dbPool)
        let first = try #require(LibraryCoverThumbnailEncoder.encode(image(width: 300, height: 450)))
        #expect(try await store.store(first, itemID: "series-1", coverUrl: Self.coverA) == .stored)
        let gate = FirstDecodeGate()
        let service = LibraryCoverThumbnails(store: store, decode: { await gate.decode($0) })

        let staleRead = Task { await service.thumbnail(for: "series-1") }
        for await _ in gate.arrivals { break }
        try await database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET coverUrl = ? WHERE id = 'series-1'", arguments: [Self.coverB])
        }
        await service.record(itemID: "series-1", coverUrl: Self.coverB, image: image(width: 150, height: 225))
        gate.open()

        // The older read still answers its own caller, which checks the cover address it was given.
        #expect(await staleRead.value?.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(Self.coverA))
        let current = await service.thumbnail(for: "series-1")
        #expect(current?.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(Self.coverB))
        #expect(current?.image.size.width == 150)
    }

    @Test func theUnavailableServiceKeepsAndReturnsNothing() async {
        let service = UnavailableLibraryCoverThumbnails()

        service.capture(itemID: "series-1", coverUrl: Self.coverA, image: image(width: 10, height: 15))

        #expect(await service.thumbnail(for: "series-1") == nil)
    }
}

/// A fixed pseudo-random sequence, so the noisy cover is the same on every run.
private nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Counts how often the encoder ran; it runs off the main actor.
private nonisolated final class EncodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Holds the first decode until the test opens it, so a read can be overtaken deterministically.
private nonisolated final class FirstDecodeGate: @unchecked Sendable {
    let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var calls = 0

    init() {
        (arrivals, arrived) = AsyncStream<Void>.makeStream()
        (releases, release) = AsyncStream<Void>.makeStream()
    }

    private func isFirstCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 1
    }

    func decode(_ stored: StoredCoverThumbnail) async -> LibraryDurableCover? {
        if isFirstCall() {
            arrived.yield(())
            for await _ in releases { break }
        }
        return LibraryCoverThumbnails.decode(stored)
    }

    func open() { release.yield(()) }
}
