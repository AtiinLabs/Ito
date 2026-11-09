import Foundation
@testable import Ito

/// In-memory `OfflineFileSystem` with fault injection. Crash tests keep one instance across store
/// instances, so a "restart" sees exactly the bytes the previous instance left behind.
final class FakeOfflineFileSystem: OfflineFileSystem, @unchecked Sendable {
    enum Operation: Hashable, Sendable {
        case createDirectory
        case writeFile
        case readData
        case moveItem
        case removeItem
        case synchronize
    }

    private enum Node {
        case directory
        case file(Data)
    }

    private struct Fault {
        let operation: Operation
        let pathFragment: String
        var skip: Int
        let error: OfflineFileSystemError
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var faults: [Fault] = []
    private var holds: [(operation: Operation, pathFragment: String, hold: FakeFileSystemHold)] = []
    private var capacity: Int64
    private var isLocked = false

    init(capacity: Int64 = 10 * 1024 * 1024 * 1024) {
        self.capacity = capacity
    }

    // MARK: - OfflineFileSystem

    func availableCapacity(at url: URL) throws -> Int64 {
        try withLock { () throws -> Int64 in
            try checkAccess()
            return capacity
        }
    }

    func prepareRoot(_ url: URL) throws {
        try createDirectory(url)
    }

    func createDirectory(_ url: URL) throws {
        try withLock {
            try checkAccess()
            let path = Self.key(url)
            try inject(.createDirectory, path)
            if case .file? = nodes[path] { throw OfflineFileSystemError.other }
            var chain: [String] = []
            var current = path
            while current != "/" && !current.isEmpty {
                chain.append(current)
                current = Self.parent(current)
            }
            for directoryPath in chain.reversed() where nodes[directoryPath] == nil {
                nodes[directoryPath] = .directory
            }
        }
    }

    func entryExists(at url: URL) throws -> Bool {
        try withLock { () throws -> Bool in
            try checkAccess()
            return nodes[Self.key(url)] != nil
        }
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try withLock { () throws -> [URL] in
            try checkAccess()
            let path = Self.key(url)
            guard case .directory? = nodes[path] else { throw OfflineFileSystemError.notFound }
            return nodes.keys
                .filter { $0 != path && Self.parent($0) == path }
                .sorted()
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    func readData(at url: URL) throws -> Data {
        try withLock { () throws -> Data in
            try checkAccess()
            let path = Self.key(url)
            try inject(.readData, path)
            switch nodes[path] {
            case .file(let data)?:
                return data
            case .directory?:
                throw OfflineFileSystemError.other
            case nil:
                throw OfflineFileSystemError.notFound
            }
        }
    }

    func writeFile(_ data: Data, to url: URL) throws {
        try withLock {
            try checkAccess()
            let path = Self.key(url)
            try inject(.writeFile, path)
            guard case .directory? = nodes[Self.parent(path)] else { throw OfflineFileSystemError.notFound }
            if case .directory? = nodes[path] { throw OfflineFileSystemError.other }
            nodes[path] = .file(data)
        }
    }

    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        // The body runs outside the lock, so it may call back into the fake.
        let data = try readData(at: url)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try body(data.subdata(in: offset..<end))
            offset = end
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        waitIfHeld(.moveItem, Self.key(destination))
        try withLock {
            try checkAccess()
            let from = Self.key(source)
            let to = Self.key(destination)
            try inject(.moveItem, to)
            guard nodes[from] != nil else { throw OfflineFileSystemError.notFound }
            guard nodes[to] == nil else { throw OfflineFileSystemError.other }
            guard case .directory? = nodes[Self.parent(to)] else { throw OfflineFileSystemError.notFound }
            let moved = nodes.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
            for path in moved.keys {
                nodes[path] = nil
            }
            for (path, node) in moved {
                nodes[to + String(path.dropFirst(from.count))] = node
            }
        }
    }

    func removeItem(at url: URL) throws {
        try withLock {
            try checkAccess()
            let path = Self.key(url)
            try inject(.removeItem, path)
            for key in Array(nodes.keys) where key == path || key.hasPrefix(path + "/") {
                nodes[key] = nil
            }
        }
    }

    func synchronize(_ url: URL) throws {
        try withLock {
            try checkAccess()
            let path = Self.key(url)
            try inject(.synchronize, path)
            guard nodes[path] != nil else { throw OfflineFileSystemError.notFound }
        }
    }

    // MARK: - Test controls

    /// Fails the next matching call. `skipping` lets that many matching calls succeed first.
    func failNext(
        _ operation: Operation,
        pathContaining fragment: String,
        skipping: Int = 0,
        with error: OfflineFileSystemError
    ) {
        withLock {
            faults.append(Fault(operation: operation, pathFragment: fragment, skip: skipping, error: error))
        }
    }

    /// While locked, every call fails with `.permissionDenied`, as a locked device does.
    func setLocked(_ locked: Bool) {
        withLock { isLocked = locked }
    }

    func setCapacity(_ bytes: Int64) {
        withLock { capacity = bytes }
    }

    /// Parks the next matching call until `release()`, so a test can act while the store is inside a
    /// synchronous step such as the publish rename.
    func holdNext(_ operation: Operation, pathContaining fragment: String) -> FakeFileSystemHold {
        let hold = FakeFileSystemHold()
        withLock { holds.append((operation: operation, pathFragment: fragment, hold: hold)) }
        return hold
    }

    func exists(_ url: URL) -> Bool {
        withLock { nodes[Self.key(url)] != nil }
    }

    func fileData(at url: URL) -> Data? {
        withLock { () -> Data? in
            if case .file(let data)? = nodes[Self.key(url)] { return data }
            return nil
        }
    }

    /// Names of the direct children of `url`, sorted.
    func childNames(of url: URL) -> [String] {
        withLock { () -> [String] in
            let path = Self.key(url)
            return nodes.keys
                .filter { $0 != path && Self.parent($0) == path }
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .sorted()
        }
    }

    /// Overwrites an existing file's bytes without going through the store, to simulate damage.
    func replaceFile(at url: URL, with data: Data) {
        withLock {
            let path = Self.key(url)
            if case .file? = nodes[path] {
                nodes[path] = .file(data)
            }
        }
    }

    // MARK: - Private

    private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func checkAccess() throws {
        if isLocked { throw OfflineFileSystemError.permissionDenied }
    }

    /// Blocks the calling thread at a held operation until the test releases it. It runs before the
    /// lock is taken, so the test can read the file system while the store is parked here.
    private func waitIfHeld(_ operation: Operation, _ path: String) {
        let hold = withLock { () -> FakeFileSystemHold? in
            guard let index = holds.firstIndex(where: {
                $0.operation == operation && path.contains($0.pathFragment)
            }) else { return nil }
            return holds.remove(at: index).hold
        }
        hold?.park()
    }

    private func inject(_ operation: Operation, _ path: String) throws {
        guard let index = faults.firstIndex(where: {
            $0.operation == operation && path.contains($0.pathFragment)
        }) else { return }
        if faults[index].skip > 0 {
            faults[index].skip -= 1
            return
        }
        let error = faults[index].error
        faults.remove(at: index)
        // A write that runs out of space leaves the volume full, as a real disk does.
        if case .noSpace = error {
            capacity = 0
        }
        throw error
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

/// One parked file-system call. The store's thread waits on a semaphore inside a synchronous step, and
/// the test awaits its arrival, acts, then releases it. Nothing sleeps or polls.
nonisolated final class FakeFileSystemHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called on the store's thread. Returns once the test calls `release()`.
    func park() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            arrived = true
            defer { arrivalWaiters = [] }
            return arrivalWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
        gate.wait()
    }

    /// Returns once the held call has been reached.
    func awaitArrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reachedAlready = lock.withLock { () -> Bool in
                if arrived { return true }
                arrivalWaiters.append(continuation)
                return false
            }
            if reachedAlready {
                continuation.resume()
            }
        }
    }

    func release() {
        gate.signal()
    }
}

/// Protected-data availability that a test switches explicitly. A locked class rather than an actor:
/// the protocol is nonisolated, and its async requirement is all callers need.
nonisolated final class FakeProtectedDataAvailability: ProtectedDataAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable: Bool

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func setAvailable(_ available: Bool) async {
        lock.withLock { isAvailable = available }
    }

    func isProtectedDataAvailable() async -> Bool {
        lock.withLock { isAvailable }
    }
}
