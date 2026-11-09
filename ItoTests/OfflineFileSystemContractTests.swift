import Foundation
import Testing
@testable import Ito

/// The contract every `OfflineFileSystem` meets. It runs against the in-memory fake and against
/// `LocalOfflineFileSystem` on a temporary directory, so the fake cannot drift from the real file
/// operations the store depends on.
enum OfflineFileSystemBackend: String, CaseIterable, Sendable {
    case fake
    case local
}

/// One backend and a root directory that exists. A local root lives in a unique temporary directory
/// that is removed on deinit.
final class OfflineFileSystemHarness {
    let fileSystem: any OfflineFileSystem
    let root: URL
    private let temporaryDirectory: URL?

    init(_ backend: OfflineFileSystemBackend) throws {
        switch backend {
        case .fake:
            fileSystem = FakeOfflineFileSystem()
            root = URL(fileURLWithPath: "/ito-offline-contract/OfflineChapters", isDirectory: true)
            temporaryDirectory = nil
        case .local:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OfflineFileSystemContract-\(UUID().uuidString)", isDirectory: true)
            fileSystem = LocalOfflineFileSystem()
            root = directory.appendingPathComponent("OfflineChapters", isDirectory: true)
            temporaryDirectory = directory
        }
        try fileSystem.createDirectory(root)
    }

    deinit {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }
}

struct OfflineFileSystemContractTests {
    @Test(arguments: OfflineFileSystemBackend.allCases)
    func createDirectoryIsIdempotentAndCreatesMissingParents(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        let nested = harness.url("a/b/c")

        try harness.fileSystem.createDirectory(nested)
        try harness.fileSystem.createDirectory(nested)

        #expect(try harness.fileSystem.entryExists(at: nested))
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func writeFileReplacesContentAndLeavesOnlyTheDestination(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        try harness.fileSystem.writeFile(Data("one".utf8), to: harness.url("file.bin"))
        try harness.fileSystem.writeFile(Data("two".utf8), to: harness.url("file.bin"))

        #expect(try harness.fileSystem.readData(at: harness.url("file.bin")) == Data("two".utf8))
        #expect(try harness.fileSystem.contentsOfDirectory(harness.root).map(\.lastPathComponent) == ["file.bin"])
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func readOfAMissingFileIsNotFound(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        #expect(throws: OfflineFileSystemError.notFound) {
            try harness.fileSystem.readData(at: harness.url("missing.bin"))
        }
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func entryExistsDistinguishesFilesDirectoriesAndAbsence(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        try harness.fileSystem.createDirectory(harness.url("folder"))
        try harness.fileSystem.writeFile(Data("x".utf8), to: harness.url("file.bin"))

        #expect(try harness.fileSystem.entryExists(at: harness.url("folder")))
        #expect(try harness.fileSystem.entryExists(at: harness.url("file.bin")))
        #expect(try !harness.fileSystem.entryExists(at: harness.url("absent")))
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func contentsOfAMissingDirectoryIsNotFound(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        #expect(throws: OfflineFileSystemError.notFound) {
            try harness.fileSystem.contentsOfDirectory(harness.url("absent"))
        }
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func forEachChunkYieldsOrderedNonEmptyChunksThatRebuildTheFile(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        let payload = Data("0123456789".utf8)
        try harness.fileSystem.writeFile(payload, to: harness.url("stream.bin"))

        var rebuilt = Data()
        var sizes: [Int] = []
        try harness.fileSystem.forEachChunk(of: harness.url("stream.bin"), chunkSize: 4) { chunk in
            rebuilt.append(chunk)
            sizes.append(chunk.count)
        }

        #expect(rebuilt == payload)
        #expect(sizes == [4, 4, 2])
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func moveItemRenamesADirectoryTreeWithoutLeavingTheSource(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        try harness.fileSystem.createDirectory(harness.url("source"))
        try harness.fileSystem.writeFile(Data("page".utf8), to: harness.url("source/p0000.jpg"))

        try harness.fileSystem.moveItem(at: harness.url("source"), to: harness.url("destination"))

        #expect(try harness.fileSystem.readData(at: harness.url("destination/p0000.jpg")) == Data("page".utf8))
        #expect(try !harness.fileSystem.entryExists(at: harness.url("source")))
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func moveOntoAnExistingDestinationFailsAndMovesNothing(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        try harness.fileSystem.writeFile(Data("a".utf8), to: harness.url("a.bin"))
        try harness.fileSystem.writeFile(Data("b".utf8), to: harness.url("b.bin"))

        #expect(throws: OfflineFileSystemError.other) {
            try harness.fileSystem.moveItem(at: harness.url("a.bin"), to: harness.url("b.bin"))
        }

        #expect(try harness.fileSystem.readData(at: harness.url("a.bin")) == Data("a".utf8))
        #expect(try harness.fileSystem.readData(at: harness.url("b.bin")) == Data("b".utf8))
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func moveOfAMissingSourceIsNotFound(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        #expect(throws: OfflineFileSystemError.notFound) {
            try harness.fileSystem.moveItem(at: harness.url("absent"), to: harness.url("destination"))
        }
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func removeOfAMissingItemIsNoOpAndRemoveOfATreeRemovesEverything(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        try harness.fileSystem.removeItem(at: harness.url("absent"))

        try harness.fileSystem.createDirectory(harness.url("tree/inner"))
        try harness.fileSystem.writeFile(Data("x".utf8), to: harness.url("tree/inner/file.bin"))
        try harness.fileSystem.removeItem(at: harness.url("tree"))

        #expect(try !harness.fileSystem.entryExists(at: harness.url("tree")))
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func synchronizeSucceedsForFilesAndDirectories(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)
        try harness.fileSystem.writeFile(Data("x".utf8), to: harness.url("file.bin"))

        try harness.fileSystem.synchronize(harness.url("file.bin"))
        try harness.fileSystem.synchronize(harness.root)
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func synchronizeOfAMissingItemIsNotFound(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        #expect(throws: OfflineFileSystemError.notFound) {
            try harness.fileSystem.synchronize(harness.url("absent"))
        }
    }

    @Test(arguments: OfflineFileSystemBackend.allCases)
    func availableCapacityIsPositive(backend: OfflineFileSystemBackend) throws {
        let harness = try OfflineFileSystemHarness(backend)

        #expect(try harness.fileSystem.availableCapacity(at: harness.root) > 0)
    }

    /// Backup exclusion and the protection class on the real filesystem. The simulator and macOS
    /// do not enforce data protection the way a device does, so the protection readback asserts only
    /// what is reported: nil, `.none`, or the requested class. Device behaviour is spike S2.
    @Test func localRootIsExcludedFromBackupAndNewFilesReportNoOtherProtectionClass() throws {
        let harness = try OfflineFileSystemHarness(.local)
        try harness.fileSystem.prepareRoot(harness.root)
        try harness.fileSystem.writeFile(Data("x".utf8), to: harness.url("protected.bin"))

        let excluded = try URL(fileURLWithPath: harness.root.path, isDirectory: true)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup
        #expect(excluded == true)

        let attributes = try FileManager.default.attributesOfItem(atPath: harness.url("protected.bin").path)
        let reported = attributes[.protectionKey] as? FileProtectionType
        let isAcceptable = reported == nil
            || reported == FileProtectionType.none
            || reported == FileProtectionType.completeUntilFirstUserAuthentication
        #expect(isAcceptable)
    }
}
