import Combine
import Foundation
import ito_runner

enum MigrationSourceDisposition: Equatable {
    case skipped
    case installed
    case remapped(aliasSaved: Bool)
}

struct MigrationReportOperation: Equatable {
    enum Kind: Equatable {
        case install
        case remap
    }

    let id: UUID
    let foreignID: String
    let kind: Kind
}

struct MigrationRemapPickerPresentation: Identifiable, Equatable {
    let foreignID: String
    var id: String { foreignID }
}

struct MigrationPluginOption: Identifiable, Equatable {
    let id: String
    let name: String
    let isInstalled: Bool
}

enum MigrationReportAlert: Identifiable, Equatable {
    case installFailed(foreignID: String, reason: String)
    case pluginNotFound(resolvedID: String)
    case remapFailed(reason: String)
    case remapAliasNotSaved

    var id: String {
        switch self {
        case .installFailed: "installFailed"
        case .pluginNotFound: "pluginNotFound"
        case .remapFailed: "remapFailed"
        case .remapAliasNotSaved: "remapAliasNotSaved"
        }
    }

    var title: String {
        switch self {
        case .installFailed, .pluginNotFound: "Installation Failed"
        case .remapFailed: "Remap Failed"
        case .remapAliasNotSaved: "Remap Partially Saved"
        }
    }

    var message: String {
        switch self {
        case .installFailed(let foreignID, let reason):
            "Could not install \"\(foreignID)\": \(reason)"
        case .pluginNotFound(let resolvedID):
            "The extension \"\(resolvedID)\" was not found in any of your repositories."
        case .remapFailed(let reason):
            reason
        case .remapAliasNotSaved:
            "Library items were remapped, but this mapping could not be remembered for future imports."
        }
    }
}

@MainActor
final class MigrationReportViewModel: ObservableObject {
    /// Baseline install-eligibility threshold, unchanged from the pre-PR16B view.
    private static let installConfidenceThreshold = 45

    let report: MigrationReport
    let isRemediationAllowed: Bool

    @Published private(set) var dispositions: [String: MigrationSourceDisposition] = [:]
    @Published private(set) var activeOperation: MigrationReportOperation?
    @Published private(set) var remapPicker: MigrationRemapPickerPresentation?
    @Published private(set) var alert: MigrationReportAlert?
    @Published var pickerSearchText = ""

    @Published private var installedPlugins: [String: InstalledPlugin]
    @Published private var repositories: [Repository]

    private let dependencies: PreparedMigrationReportDependencies?
    private let presentationLogger: (any PresentationEventLogging)?
    private var cancellables = Set<AnyCancellable>()

    /// Read-only: no dependencies, no logger, no subscriptions. Every remediation intent is rejected.
    init(readOnlyReport report: MigrationReport) {
        self.report = report
        isRemediationAllowed = false
        dependencies = nil
        presentationLogger = nil
        installedPlugins = [:]
        repositories = []
    }

    init(
        report: MigrationReport,
        dependencies: PreparedMigrationReportDependencies,
        presentationLogger: any PresentationEventLogging
    ) {
        self.report = report
        isRemediationAllowed = true
        self.dependencies = dependencies
        self.presentationLogger = presentationLogger
        installedPlugins = dependencies.plugins.installedPlugins
        repositories = dependencies.repositories.repositories

        dependencies.plugins.installedPluginsPublisher
            .sink { [weak self] in self?.installedPlugins = $0 }
            .store(in: &cancellables)
        dependencies.repositories.repositoriesPublisher
            .sink { [weak self] in self?.repositories = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    var activeUnresolvedCount: Int {
        report.unresolvedPlugins.filter { dispositions[$0.foreignId] == nil }.count
    }

    var isAllResolved: Bool { activeUnresolvedCount == 0 }

    var isBusy: Bool { activeOperation != nil }

    func disposition(for foreignID: String) -> MigrationSourceDisposition? {
        dispositions[foreignID]
    }

    func canInstall(_ plugin: MigrationReport.UnresolvedPlugin) -> Bool {
        isRemediationAllowed
            && disposition(for: plugin.foreignId) == nil
            && !plugin.isInstalled
            && plugin.confidence >= Self.installConfidenceThreshold
    }

    func isInstalling(foreignID: String) -> Bool {
        activeOperation?.kind == .install && activeOperation?.foreignID == foreignID
    }

    /// Installed plugins win duplicate IDs; repository packages fill the rest in repository/package order.
    /// Sorted case-insensitively by name, ties broken by ID.
    var pickerOptions: [MigrationPluginOption] {
        guard isRemediationAllowed else { return [] }
        var options = installedPlugins.map {
            MigrationPluginOption(id: $0.key, name: $0.value.info.name, isInstalled: true)
        }
        var seenIDs = Set(options.map(\.id))
        for repository in repositories {
            for package in repository.index?.packages ?? [] where !seenIDs.contains(package.id) {
                seenIDs.insert(package.id)
                options.append(MigrationPluginOption(id: package.id, name: package.name, isInstalled: false))
            }
        }
        return options.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    var filteredPickerOptions: [MigrationPluginOption] {
        let query = pickerSearchText
        guard !query.isEmpty else { return pickerOptions }
        return pickerOptions.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Intents

    /// Synchronously claims the operation before launching work. Returns nil without any state change or service call when rejected.
    @discardableResult
    func install(foreignID: String) -> Task<Void, Never>? {
        guard let plugin = claimableRow(foreignID: foreignID),
              canInstall(plugin),
              let dependencies else { return nil }

        let operation = claimOperation(foreignID: foreignID, kind: .install)
        let logger = presentationLogger
        logger?.log(.started(feature: .migrationReport, kind: .pluginInstall, operationID: operation.id))
        let repositoryProvider = dependencies.repositories

        return Task { @MainActor [weak self] in
            var disposition: MigrationSourceDisposition?
            var alert: MigrationReportAlert?
            var outcome: PresentationEventOutcome

            await repositoryProvider.refreshAll()
            if let match = Self.findPackage(resolvedID: plugin.resolvedId, in: repositoryProvider.repositories) {
                do {
                    try await repositoryProvider.installPackage(match.package, repositoryURL: match.repositoryURL)
                    disposition = .installed
                    outcome = .succeeded
                } catch {
                    alert = .installFailed(foreignID: foreignID, reason: error.localizedDescription)
                    outcome = .failed(.unknown)
                }
            } else {
                alert = .pluginNotFound(resolvedID: plugin.resolvedId)
                outcome = .failed(.pluginUnavailable)
            }

            logger?.log(.finished(
                feature: .migrationReport,
                kind: .pluginInstall,
                operationID: operation.id,
                outcome: outcome
            ))
            self?.finishOperation(operation, disposition: disposition, alert: alert)
        }
    }

    @discardableResult
    func presentRemapPicker(foreignID: String) -> Bool {
        guard claimableRow(foreignID: foreignID) != nil else { return false }
        pickerSearchText = ""
        remapPicker = MigrationRemapPickerPresentation(foreignID: foreignID)
        return true
    }

    /// Dismissal never touches a durable operation; it only clears picker presentation.
    func cancelRemapPicker() {
        remapPicker = nil
        pickerSearchText = ""
    }

    /// Rejects unknown option IDs without closing the picker or touching state.
    @discardableResult
    func selectRemapTarget(pluginID: String) -> Task<Void, Never>? {
        guard let picker = remapPicker,
              let plugin = claimableRow(foreignID: picker.foreignID),
              let dependencies,
              pickerOptions.contains(where: { $0.id == pluginID }) else { return nil }

        remapPicker = nil
        pickerSearchText = ""
        let operation = claimOperation(foreignID: plugin.foreignId, kind: .remap)
        let logger = presentationLogger
        logger?.log(.started(feature: .migrationReport, kind: .relink, operationID: operation.id))
        let remapper = dependencies.remapper
        let request = MigrationRemapRequest(
            foreignID: plugin.foreignId,
            oldPluginID: plugin.resolvedId,
            newPluginID: pluginID,
            affectedItemIDs: plugin.affectedItemIds
        )

        return Task { @MainActor [weak self] in
            var disposition: MigrationSourceDisposition?
            var alert: MigrationReportAlert?
            var outcome: PresentationEventOutcome

            do {
                switch try await remapper.remapSource(request) {
                case .remappedAndAliased:
                    disposition = .remapped(aliasSaved: true)
                    outcome = .succeeded
                case .remappedAliasNotSaved:
                    disposition = .remapped(aliasSaved: false)
                    alert = .remapAliasNotSaved
                    outcome = .partiallySucceeded(.persistence)
                }
            } catch {
                alert = .remapFailed(reason: error.localizedDescription)
                outcome = .failed(.persistence)
            }

            logger?.log(.finished(
                feature: .migrationReport,
                kind: .relink,
                operationID: operation.id,
                outcome: outcome
            ))
            self?.finishOperation(operation, disposition: disposition, alert: alert)
        }
    }

    @discardableResult
    func skip(foreignID: String) -> Bool {
        guard claimableRow(foreignID: foreignID) != nil else { return false }
        dispositions[foreignID] = .skipped
        return true
    }

    func dismissAlert() {
        alert = nil
    }

    // MARK: - Private

    /// Gate shared by every remediation intent: remediation enabled, no active operation, row pending, row known.
    private func claimableRow(foreignID: String) -> MigrationReport.UnresolvedPlugin? {
        guard isRemediationAllowed,
              dependencies != nil,
              activeOperation == nil,
              disposition(for: foreignID) == nil else { return nil }
        return report.unresolvedPlugins.first { $0.foreignId == foreignID }
    }

    private func claimOperation(foreignID: String, kind: MigrationReportOperation.Kind) -> MigrationReportOperation {
        let operation = MigrationReportOperation(id: UUID(), foreignID: foreignID, kind: kind)
        activeOperation = operation
        alert = nil
        return operation
    }

    /// Publishes only if this operation is still the active one. Logging already happened in the caller.
    private func finishOperation(
        _ operation: MigrationReportOperation,
        disposition: MigrationSourceDisposition?,
        alert: MigrationReportAlert?
    ) {
        guard activeOperation?.id == operation.id else { return }
        if let disposition {
            dispositions[operation.foreignID] = disposition
        }
        if let alert {
            self.alert = alert
        }
        activeOperation = nil
    }

    private static func findPackage(
        resolvedID: String,
        in repositories: [Repository]
    ) -> (package: RepoPackage, repositoryURL: String)? {
        for repository in repositories {
            if let package = repository.index?.packages.first(where: { $0.id == resolvedID }) {
                return (package, repository.url)
            }
        }
        return nil
    }
}
