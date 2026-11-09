import Darwin
import Foundation
import UIKit

/// Filesystem failures the offline store acts on. Everything else is `.other`.
nonisolated enum OfflineFileSystemError: Error, Equatable, Sendable {
    case noSpace
    case permissionDenied
    case notFound
    case other
}

/// The file operations the offline store performs. Every mutation of the offline directory goes
/// through this seam, so crash and fault tests can replace it with an in-memory fake.
nonisolated protocol OfflineFileSystem: Sendable {
    /// Bytes free for important usage on the volume that holds `url`. Never cached.
    func availableCapacity(at url: URL) throws -> Int64
    /// Creates the root and applies the backup exclusion and file protection class.
    func prepareRoot(_ url: URL) throws
    /// Creates a directory and any missing parents. Existing directories are not an error.
    func createDirectory(_ url: URL) throws
    /// Whether anything exists at `url`. Throws on any error other than "not found", so a locked
    /// device is never mistaken for a missing file.
    func entryExists(at url: URL) throws -> Bool
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    /// Atomically creates or replaces a file with the offline protection class.
    func writeFile(_ data: Data, to url: URL) throws
    /// Streams a file in order. The body is never called with an empty chunk.
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws
    /// Renames within the same volume. The destination must not exist. A failure means nothing moved.
    func moveItem(at source: URL, to destination: URL) throws
    /// Removes a file or a directory tree. A missing item is not an error.
    func removeItem(at url: URL) throws
    /// Flushes a file or directory to stable storage.
    func synchronize(_ url: URL) throws
}

/// Whether the device's data-protection keys are available. Protected files and the database
/// become readable together, so reconciliation waits for this before touching anything.
nonisolated protocol ProtectedDataAvailability: Sendable {
    func isProtectedDataAvailable() async -> Bool
}

/// Production filesystem backed by `FileManager` and POSIX.
nonisolated struct LocalOfflineFileSystem: OfflineFileSystem {
    private var protectionAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        // A fresh URL, so no cached resource value from an earlier call is reused.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        do {
            let values = try fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
                throw OfflineFileSystemError.other
            }
            return capacity
        } catch {
            throw Self.mapped(error)
        }
    }

    func prepareRoot(_ url: URL) throws {
        try createDirectory(url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            throw Self.mapped(error)
        }
    }

    func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: protectionAttributes
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    func entryExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            let mapped = Self.mapped(error)
            if mapped == .notFound { return false }
            throw mapped
        }
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            throw Self.mapped(error)
        }
    }

    func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Self.mapped(error)
        }
    }

    func writeFile(_ data: Data, to url: URL) throws {
        do {
            // Atomic: the bytes land in a temporary file that is renamed over the destination, so a
            // crash leaves either the old file or the new one, never a partial marker.
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Self.mapped(error)
        }
        defer { try? handle.close() }
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw Self.mapped(error)
            }
            guard let chunk, !chunk.isEmpty else { return }
            try body(chunk)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        // Protection is applied before the rename: if it fails, nothing has moved, and a successful
        // rename never reports failure afterwards.
        do {
            try FileManager.default.setAttributes(protectionAttributes, ofItemAtPath: source.path)
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw Self.mapped(error)
        }
    }

    func removeItem(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let mapped = Self.mapped(error)
            if mapped == .notFound { return }
            throw mapped
        }
    }

    func synchronize(_ url: URL) throws {
        // POSIX, so that directories can be flushed too. `fsync` works on a read-only descriptor.
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw Self.mappedPOSIX(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Self.mappedPOSIX(errno) }
    }

    private static func mapped(_ error: Error) -> OfflineFileSystemError {
        if let known = error as? OfflineFileSystemError { return known }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return mappedPOSIX(Int32(nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteOutOfSpace:
                return .noSpace
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .notFound
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .permissionDenied
            default:
                break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return mappedPOSIX(Int32(underlying.code))
        }
        return .other
    }

    private static func mappedPOSIX(_ code: Int32) -> OfflineFileSystemError {
        switch POSIXErrorCode(rawValue: code) {
        case .ENOSPC?:
            return .noSpace
        case .EPERM?, .EACCES?:
            return .permissionDenied
        case .ENOENT?:
            return .notFound
        default:
            return .other
        }
    }
}

/// Production protected-data check. The app's main-actor `UIApplication` answers it.
nonisolated struct UIApplicationProtectedDataAvailability: ProtectedDataAvailability {
    func isProtectedDataAvailable() async -> Bool {
        await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    }
}
