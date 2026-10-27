import Combine
import Foundation
import Nuke
import SwiftUI
import UIKit

struct ReaderPageImageKey: Hashable {
    private struct Header: Hashable {
        let name: String
        let value: String
    }

    private let url: URL?
    private let method: String?
    private let body: Data?
    private let cachePolicy: UInt
    private let headers: [Header]

    init(request: URLRequest) {
        url = request.url
        method = request.httpMethod
        body = request.httpBody
        cachePolicy = UInt(request.cachePolicy.rawValue)
        headers = (request.allHTTPHeaderFields ?? [:])
            .map { Header(name: $0.key.lowercased(), value: $0.value) }
            .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
    }
}

struct ReaderPageImageDescriptor {
    let pageID: String
    let request: URLRequest
    var key: ReaderPageImageKey { ReaderPageImageKey(request: request) }

    init(pageID: String, request: URLRequest) {
        self.pageID = pageID
        self.request = request
    }
}

enum ReaderImageConsumer: Equatable {
    case visible
    case prefetch
}

struct ReaderImageLease: Hashable {
    fileprivate let id: UUID
    let key: ReaderPageImageKey
}

enum ReaderPageImagePhase {
    case idle
    case loading
    case ready(UIImage)
    case failed
}

struct ReaderPageImageState {
    let phase: ReaderPageImagePhase
    let pixelSize: CGSize?
    let revision: UInt64
}

/// A subscription to one image request's state; cancelling it, or releasing it, ends it.
@MainActor
final class ReaderImageObservation {
    private var cancellation: (@MainActor @Sendable () -> Void)?

    fileprivate init(cancellation: @escaping @MainActor @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }

    deinit {
        // The last owner may release this anywhere; the session is only touched on the main actor.
        guard let cancellation else { return }
        Task { @MainActor in cancellation() }
    }
}

@MainActor
final class ReaderPageImageSession: ObservableObject {
    private struct Entry {
        var request: URLRequest?
        var phase: ReaderPageImagePhase = .idle
        var pixelSize: CGSize?
        var revision: UInt64 = 0
        var leases: [UUID: ReaderImageConsumer] = [:]
        var observers: [UUID: @MainActor (ReaderPageImageState) -> Void] = [:]
        var cancelTask: (() -> Void)?
        var generation: UInt64 = 0
        var taskIsPrefetch = false
        var isPrefetchQueued = false
    }

    private let pipeline: ImagePipeline
    private var entries: [ReaderPageImageKey: Entry] = [:]
    private var prefetchOrder: [ReaderPageImageKey] = []
    private var runningPrefetches = 0
    private let maximumPrefetches = 2

    init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline
    }

    func state(for key: ReaderPageImageKey) -> ReaderPageImageState {
        guard let entry = entries[key] else {
            return ReaderPageImageState(phase: .idle, pixelSize: nil, revision: 0)
        }
        return snapshot(entry)
    }

    func acquire(_ descriptor: ReaderPageImageDescriptor, consumer: ReaderImageConsumer) -> ReaderImageLease {
        let key = descriptor.key
        var entry = entries[key] ?? Entry(request: descriptor.request)
        entry.request = descriptor.request
        let id = UUID()
        entry.leases[id] = consumer
        if consumer == .visible, entry.isPrefetchQueued {
            entry.isPrefetchQueued = false
            prefetchOrder.removeAll { $0 == key }
        }
        entries[key] = entry
        if case .idle = entry.phase {
            switch consumer {
            case .visible: start(key)
            case .prefetch: enqueuePrefetch(key)
            }
        } else if consumer == .visible, entry.isPrefetchQueued {
            start(key)
        }
        return ReaderImageLease(id: id, key: key)
    }

    func release(_ lease: ReaderImageLease) {
        guard var entry = entries[lease.key], let consumer = entry.leases.removeValue(forKey: lease.id) else { return }
        var shouldPublish = false
        if consumer == .visible, !entry.leases.values.contains(.visible), case .ready = entry.phase {
            entry.phase = .idle
            shouldPublish = true
        }
        if entry.leases.isEmpty, entry.isPrefetchQueued {
            prefetchOrder.removeAll { $0 == lease.key }
            entry.isPrefetchQueued = false
        }
        if entry.leases.isEmpty, let cancelTask = entry.cancelTask {
            entry.generation &+= 1
            if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
            cancelTask()
            entry.cancelTask = nil
            entry.taskIsPrefetch = false
            if case .loading = entry.phase { entry.phase = .idle }
            shouldPublish = true
        }
        entries[lease.key] = entry
        if shouldPublish { publish(lease.key) }
        startQueuedPrefetches()
    }

    func observe(_ key: ReaderPageImageKey, handler: @escaping @MainActor (ReaderPageImageState) -> Void) -> ReaderImageObservation {
        var entry = entries[key] ?? Entry(request: nil)
        let id = UUID()
        entry.observers[id] = handler
        entries[key] = entry
        return ReaderImageObservation { [weak self] in
            self?.entries[key]?.observers.removeValue(forKey: id)
        }
    }

    func setPrefetch(_ descriptors: [ReaderPageImageDescriptor]) {
        let desired = Set(descriptors.map(\.key))
        let staleKeys = entries.compactMap { key, entry in
            entry.leases.values.contains(.prefetch) && !desired.contains(key) ? key : nil
        }
        for key in staleKeys {
            guard let entry = entries[key] else { continue }
            let ids = entry.leases.compactMap { $0.value == .prefetch ? $0.key : nil }
            ids.forEach { release(ReaderImageLease(id: $0, key: key)) }
        }
        var submitted = Set<ReaderPageImageKey>()
        for descriptor in descriptors where submitted.insert(descriptor.key).inserted {
            guard !(entries[descriptor.key]?.leases.values.contains(.prefetch) ?? false) else { continue }
            _ = acquire(descriptor, consumer: .prefetch)
        }
    }

    func retry(_ descriptor: ReaderPageImageDescriptor) {
        let key = descriptor.key
        guard var entry = entries[key] else { return }
        guard case .failed = entry.phase else { return }
        entry.phase = .idle
        entry.pixelSize = nil
        entry.request = descriptor.request
        entries[key] = entry
        if entry.leases.values.contains(.visible) {
            start(key)
        } else if !entry.leases.isEmpty {
            enqueuePrefetch(key)
        } else {
            publish(key)
        }
    }

    func retainRequests(_ keys: Set<ReaderPageImageKey>) {
        for key in Array(entries.keys) where !keys.contains(key) {
            guard var entry = entries.removeValue(forKey: key) else { continue }
            entry.generation &+= 1
            if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
            entry.cancelTask?()
            prefetchOrder.removeAll { $0 == key }
        }
        startQueuedPrefetches()
    }

    func deactivate() {
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            entry.generation &+= 1
            entry.cancelTask?()
            entry.cancelTask = nil
            entry.taskIsPrefetch = false
            entry.leases.removeAll()
            entry.observers.removeAll()
            entry.isPrefetchQueued = false
            if case .loading = entry.phase { entry.phase = .idle }
            if case .ready = entry.phase { entry.phase = .idle }
            entries[key] = entry
            publish(key)
        }
        prefetchOrder.removeAll()
        runningPrefetches = 0
    }

    private func start(_ key: ReaderPageImageKey) {
        guard var entry = entries[key], entry.cancelTask == nil, let request = entry.request else { return }
        if case .failed = entry.phase { return }
        entry.isPrefetchQueued = false
        prefetchOrder.removeAll { $0 == key }
        entry.generation &+= 1
        let generation = entry.generation
        entry.phase = .loading
        let countsAsPrefetch = !entry.leases.values.contains(where: { $0 == .visible })
        if countsAsPrefetch { runningPrefetches += 1 }
        entry.taskIsPrefetch = countsAsPrefetch
        entries[key] = entry
        let task = pipeline.imageTask(with: ImageRequest(urlRequest: request))
        entries[key]?.cancelTask = { task.cancel() }
        publish(key)
        Task { [weak self] in
            do {
                let response = try await task.response
                self?.complete(key, generation: generation, response: response)
            } catch {
                self?.fail(key, generation: generation)
            }
        }
    }

    private func complete(_ key: ReaderPageImageKey, generation: UInt64, response: ImageResponse) {
        guard var entry = entries[key], entry.generation == generation else { startQueuedPrefetches(); return }
        if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
        entry.cancelTask = nil
        entry.taskIsPrefetch = false
        let image = response.image
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            entry.pixelSize = size
            entry.phase = entry.leases.values.contains(where: { $0 == .visible }) ? .ready(image) : .idle
        } else {
            entry.phase = .failed
        }
        entries[key] = entry
        publish(key)
        startQueuedPrefetches()
    }

    private func fail(_ key: ReaderPageImageKey, generation: UInt64) {
        guard var entry = entries[key], entry.generation == generation else { startQueuedPrefetches(); return }
        if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
        entry.cancelTask = nil
        entry.taskIsPrefetch = false
        if !entry.leases.isEmpty { entry.phase = .failed } else { entry.phase = .idle }
        entries[key] = entry
        publish(key)
        startQueuedPrefetches()
    }

    private func enqueuePrefetch(_ key: ReaderPageImageKey) {
        guard var entry = entries[key], entry.cancelTask == nil else { return }
        if case .failed = entry.phase { return }
        guard !entry.isPrefetchQueued else { return }
        entry.isPrefetchQueued = true
        entries[key] = entry
        prefetchOrder.append(key)
        startQueuedPrefetches()
    }

    private func startQueuedPrefetches() {
        while runningPrefetches < maximumPrefetches, let key = prefetchOrder.first {
            prefetchOrder.removeFirst()
            guard var entry = entries[key], entry.isPrefetchQueued,
                  entry.leases.values.contains(where: { $0 == .prefetch }) else { continue }
            entry.isPrefetchQueued = false
            entries[key] = entry
            start(key)
        }
    }

    private func publish(_ key: ReaderPageImageKey) {
        guard var entry = entries[key] else { return }
        entry.revision &+= 1
        entries[key] = entry
        let value = snapshot(entry)
        entry.observers.values.forEach { $0(value) }
    }

    private func snapshot(_ entry: Entry) -> ReaderPageImageState {
        ReaderPageImageState(phase: entry.phase, pixelSize: entry.pixelSize, revision: entry.revision)
    }
}
