import Combine
import Foundation
import ito_runner
@testable import Ito

struct DeferredSubject {
    let viewModel: DeferredPluginViewModel
    let plugins: DeferredPluginFake
    let installer: DeferredInstallerFake
    let logger: PresentationEventCaptureSpy
}

enum DeferredTestFailure: Error {
    case expected
}

@MainActor
final class DeferredPluginFake: LibraryPluginServing {
    enum RunnerResponse {
        case immediate(Result<ItoRunner, Error>)
        case suspended
    }

    private let subject: CurrentValueSubject<LibraryPluginSnapshot, Never>
    private let defaultKinds: Set<MediaKind>
    private var runnerResponses: [RunnerResponse]
    private var runnerContinuations: [CheckedContinuation<ItoRunner, Error>] = []
    private(set) var runnerRequests: [String] = []

    init(
        installedPluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>,
        runnerResponses: [RunnerResponse]
    ) {
        self.defaultKinds = supportedKinds
        subject = CurrentValueSubject(
            LibraryPluginSnapshot(
                publicationRevision: 0,
                plugins: Self.identities(
                    for: installedPluginIDs,
                    supportedKinds: supportedKinds,
                    version: "1.0.0"
                )
            )
        )
        self.runnerResponses = runnerResponses
    }

    var libraryPluginSnapshot: LibraryPluginSnapshot { subject.value }
    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }
    var pendingRunnerCount: Int { runnerContinuations.count }

    func publish(
        _ pluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>? = nil,
        version: String = "1.0.0"
    ) {
        subject.send(
            LibraryPluginSnapshot(
                publicationRevision: subject.value.publicationRevision &+ 1,
                plugins: Self.identities(
                    for: pluginIDs,
                    supportedKinds: supportedKinds ?? defaultKinds,
                    version: version
                )
            )
        )
    }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner {
        runnerRequests.append(plugin.id)
        guard subject.value.publicationRevision == publicationRevision,
              subject.value.plugins[plugin.id] == plugin else {
            throw DeferredTestFailure.expected
        }
        guard !runnerResponses.isEmpty else { throw DeferredTestFailure.expected }
        switch runnerResponses.removeFirst() {
        case .immediate(let result): return try result.get()
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                runnerContinuations.append(continuation)
            }
        }
    }

    func resolveRunner(at index: Int, result: Result<ItoRunner, Error>) {
        runnerContinuations.remove(at: index).resume(with: result)
    }

    private static func identities(
        for pluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>,
        version: String
    ) -> [String: LibraryInstalledPluginIdentity] {
        Dictionary(uniqueKeysWithValues: pluginIDs.map { pluginID in
            (
                pluginID,
                LibraryInstalledPluginIdentity(
                    id: pluginID,
                    version: version,
                    supportedKinds: supportedKinds,
                    fileIdentity: URL(fileURLWithPath: "/test/\(pluginID).ito")
                )
            )
        })
    }
}

@MainActor
final class DeferredInstallerFake: DeferredPluginInstalling {
    enum LookupResponse {
        case immediate(DeferredPluginPackageCandidate?)
        case failure(Error)
        case suspended
    }

    enum InstallResponse {
        case immediate(Result<Void, Error>)
        case suspended
    }

    private var lookupResponses: [LookupResponse]
    private var installResponses: [InstallResponse]
    private var lookupContinuations: [CheckedContinuation<DeferredPluginPackageCandidate?, Error>] = []
    private var installContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var lookupRequests: [String] = []
    private(set) var installRequests: [DeferredPluginPackageCandidate] = []
    var onInstallSuspended: (() -> Void)?

    init(
        lookupResponses: [LookupResponse],
        installResponses: [InstallResponse]
    ) {
        self.lookupResponses = lookupResponses
        self.installResponses = installResponses
    }

    var pendingLookupCount: Int { lookupContinuations.count }
    var pendingInstallCount: Int { installContinuations.count }

    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate? {
        lookupRequests.append(pluginID)
        guard !lookupResponses.isEmpty else { return nil }
        switch lookupResponses.removeFirst() {
        case .immediate(let candidate): return candidate
        case .failure(let error): throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                lookupContinuations.append(continuation)
            }
        }
    }

    func install(_ candidate: DeferredPluginPackageCandidate) async throws {
        installRequests.append(candidate)
        guard !installResponses.isEmpty else { throw DeferredTestFailure.expected }
        switch installResponses.removeFirst() {
        case .immediate(let result): try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { continuation in
                installContinuations.append(continuation)
                onInstallSuspended?()
            }
        }
    }

    func resolveLookup(at index: Int, candidate: DeferredPluginPackageCandidate?) {
        lookupContinuations.remove(at: index).resume(returning: candidate)
    }

    func resolveLookup(
        at index: Int,
        result: Result<DeferredPluginPackageCandidate?, Error>
    ) {
        lookupContinuations.remove(at: index).resume(with: result)
    }

    func resolveInstall(at index: Int, result: Result<Void, Error>) {
        installContinuations.remove(at: index).resume(with: result)
    }
}

@MainActor
final class DeferredDecoderFake: DeferredPluginPayloadDecoding {
    enum Response {
        case immediate(Result<DeferredPluginMedia, Error>)
        case suspended
    }

    private var responses: [Response]
    private var continuations: [CheckedContinuation<DeferredPluginMedia, Error>] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var pendingCount: Int { continuations.count }

    func decode(_ item: Ito.LibraryItem) async throws -> DeferredPluginMedia {
        _ = item
        guard !responses.isEmpty else { throw DeferredTestFailure.expected }
        switch responses.removeFirst() {
        case .immediate(let result): return try result.get()
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    func resolve(at index: Int, result: Result<DeferredPluginMedia, Error>) {
        continuations.remove(at: index).resume(with: result)
    }
}
