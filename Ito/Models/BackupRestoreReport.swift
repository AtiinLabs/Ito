import Foundation

nonisolated public enum BackupRestoreMode: String, Codable, Equatable, Sendable {
    case wipe
    case merge
}

nonisolated public struct ComponentOutcome: Codable, Equatable, Sendable {
    nonisolated public enum ValidationError: Error, Equatable, Sendable {
        case negativeCount(component: BackupComponent, field: String)
    }

    public let component: BackupComponent
    public let inserted: Int
    public let replaced: Int
    public let preservedLocal: Int
    public let skipped: Int
    public let unresolved: Int
    public let dependencyRepaired: Int

    public var total: Int {
        inserted + replaced + preservedLocal + skipped + unresolved + dependencyRepaired
    }

    public var hasChanges: Bool {
        inserted > 0 || replaced > 0 || dependencyRepaired > 0
    }

    public init(
        component: BackupComponent,
        inserted: Int = 0,
        replaced: Int = 0,
        preservedLocal: Int = 0,
        skipped: Int = 0,
        unresolved: Int = 0,
        dependencyRepaired: Int = 0
    ) throws {
        let counts = [
            ("inserted", inserted),
            ("replaced", replaced),
            ("preservedLocal", preservedLocal),
            ("skipped", skipped),
            ("unresolved", unresolved),
            ("dependencyRepaired", dependencyRepaired)
        ]
        if let invalid = counts.first(where: { $0.1 < 0 }) {
            throw ValidationError.negativeCount(component: component, field: invalid.0)
        }

        self.component = component
        self.inserted = inserted
        self.replaced = replaced
        self.preservedLocal = preservedLocal
        self.skipped = skipped
        self.unresolved = unresolved
        self.dependencyRepaired = dependencyRepaired
    }

    private enum CodingKeys: CodingKey {
        case component
        case inserted
        case replaced
        case preservedLocal
        case skipped
        case unresolved
        case dependencyRepaired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            component: container.decode(BackupComponent.self, forKey: .component),
            inserted: container.decode(Int.self, forKey: .inserted),
            replaced: container.decode(Int.self, forKey: .replaced),
            preservedLocal: container.decode(Int.self, forKey: .preservedLocal),
            skipped: container.decode(Int.self, forKey: .skipped),
            unresolved: container.decode(Int.self, forKey: .unresolved),
            dependencyRepaired: container.decode(Int.self, forKey: .dependencyRepaired)
        )
    }
}

nonisolated public enum BackupPreflightReason: Codable, Equatable, Sendable {
    case invalidCapabilityMetadata(component: BackupComponent?, code: String)
    case invalidLibraryClosure(itemId: String, categoryId: String)
    case mediaIdentityCollision(pluginId: String, canonicalMediaId: String)
    case ambiguousPluginIdentity(identity: String)
    case missingPluginIdentity(pluginId: String)
    case orphanedRetainedPluginState(pluginId: String, component: BackupComponent)
    case credentialPayloadRejected(sourceDomain: String, sourceKey: String)
    case invalidComponentData(component: BackupComponent, code: String)
    case invalidKeyData(component: BackupComponent, key: String, code: String)

    fileprivate var deterministicKey: String {
        switch self {
        case let .invalidCapabilityMetadata(component, code):
            "invalidCapabilityMetadata|\(component?.rawValue ?? "")|\(code)"
        case let .invalidLibraryClosure(itemId, categoryId):
            "invalidLibraryClosure|\(itemId)|\(categoryId)"
        case let .mediaIdentityCollision(pluginId, canonicalMediaId):
            "mediaIdentityCollision|\(pluginId)|\(canonicalMediaId)"
        case let .ambiguousPluginIdentity(identity):
            "ambiguousPluginIdentity|\(identity)"
        case let .missingPluginIdentity(pluginId):
            "missingPluginIdentity|\(pluginId)"
        case let .orphanedRetainedPluginState(pluginId, component):
            "orphanedRetainedPluginState|\(pluginId)|\(component.rawValue)"
        case let .credentialPayloadRejected(sourceDomain, sourceKey):
            "credentialPayloadRejected|\(sourceDomain)|\(sourceKey)"
        case let .invalidComponentData(component, code):
            "invalidComponentData|\(component.rawValue)|\(code)"
        case let .invalidKeyData(component, key, code):
            "invalidKeyData|\(component.rawValue)|\(key)|\(code)"
        }
    }

    /// A short sentence for people; identifiers and codes stay out of the UI.
    public var userMessage: String {
        switch self {
        case .invalidCapabilityMetadata:
            "The backup's format information is damaged or from an unsupported version."
        case .invalidLibraryClosure:
            "A series in the backup belongs to a list the backup does not include."
        case .mediaIdentityCollision:
            "The backup contains the same series more than once."
        case .ambiguousPluginIdentity:
            "A source in the backup matches more than one installed source."
        case .missingPluginIdentity:
            "A series in the backup has no source."
        case .orphanedRetainedPluginState:
            "The backup has settings for a source it does not include."
        case .credentialPayloadRejected:
            "Saved sign-in data in the backup could not be used."
        case .invalidComponentData:
            "Part of the backup is damaged or from an unsupported version."
        case .invalidKeyData:
            "A setting in the backup is damaged or from an unsupported version."
        }
    }
}

nonisolated public struct BackupPreflightWarning: Codable, Equatable, Sendable {
    public let reason: BackupPreflightReason

    public init(reason: BackupPreflightReason) {
        self.reason = reason
    }
}

nonisolated public enum BackupPreflightError: Error, Codable, Equatable, Sendable {
    case rejected(BackupPreflightReason)
}

nonisolated public enum BackupExportError: Error, Codable, Equatable, Sendable {
    case incompleteMigration
}

nonisolated public enum BackupRestoreError: Error, Codable, Equatable, Sendable {
    case restoreCommittedRefreshPending(operationId: String)
}

nonisolated public struct BackupRestoreReport: Codable, Equatable, Sendable {
    nonisolated public enum ValidationError: Error, Equatable, Sendable {
        case emptyOperationId
        case duplicateComponent(BackupComponent)
        case missingOutcome(BackupComponent)
        case unauthorizedRepairOnlyComponent(BackupComponent)
        case unexpectedOutcome(BackupComponent)
    }

    nonisolated public struct Totals: Codable, Equatable, Sendable {
        public let inserted: Int
        public let replaced: Int
        public let preservedLocal: Int
        public let skipped: Int
        public let unresolved: Int
        public let dependencyRepaired: Int

        public var total: Int {
            inserted + replaced + preservedLocal + skipped + unresolved + dependencyRepaired
        }
    }

    public let operationId: String
    public let mode: BackupRestoreMode
    public let representedComponents: [BackupComponent]
    public let outcomes: [ComponentOutcome]
    public let preflightWarnings: [BackupPreflightWarning]
    public let migrationReport: MigrationReport?
    public let createdAt: Date

    public var totals: Totals {
        Totals(
            inserted: outcomes.reduce(0) { $0 + $1.inserted },
            replaced: outcomes.reduce(0) { $0 + $1.replaced },
            preservedLocal: outcomes.reduce(0) { $0 + $1.preservedLocal },
            skipped: outcomes.reduce(0) { $0 + $1.skipped },
            unresolved: outcomes.reduce(0) { $0 + $1.unresolved },
            dependencyRepaired: outcomes.reduce(0) { $0 + $1.dependencyRepaired }
        )
    }

    public init(
        operationId: String,
        mode: BackupRestoreMode,
        outcomes: [ComponentOutcome],
        preflightWarnings: [BackupPreflightWarning] = [],
        migrationReport: MigrationReport? = nil,
        createdAt: Date = Date()
    ) throws {
        try self.init(
            operationId: operationId,
            mode: mode,
            representedComponents: outcomes.map(\.component),
            outcomes: outcomes,
            preflightWarnings: preflightWarnings,
            migrationReport: migrationReport,
            createdAt: createdAt
        )
    }

    public init(
        operationId: String,
        mode: BackupRestoreMode,
        representedComponents: [BackupComponent],
        outcomes: [ComponentOutcome],
        preflightWarnings: [BackupPreflightWarning] = [],
        migrationReport: MigrationReport? = nil,
        createdAt: Date = Date()
    ) throws {
        guard !operationId.isEmpty else {
            throw ValidationError.emptyOperationId
        }

        var seen = Set<BackupComponent>()
        for outcome in outcomes where !seen.insert(outcome.component).inserted {
            throw ValidationError.duplicateComponent(outcome.component)
        }

        guard Set(representedComponents).count == representedComponents.count else {
            let duplicate = representedComponents.first {
                representedComponents.firstIndex(of: $0)
                    != representedComponents.lastIndex(of: $0)
            }!
            throw ValidationError.duplicateComponent(duplicate)
        }

        try Self.validateRepresentation(
            representedComponents: representedComponents,
            outcomes: outcomes
        )

        self.operationId = operationId
        self.mode = mode
        self.representedComponents = representedComponents.sorted {
            Self.componentOrder[$0, default: .max]
                < Self.componentOrder[$1, default: .max]
        }
        self.outcomes = outcomes.sorted {
            Self.componentOrder[$0.component, default: .max]
                < Self.componentOrder[$1.component, default: .max]
        }
        self.preflightWarnings = preflightWarnings.sorted {
            $0.reason.deterministicKey < $1.reason.deterministicKey
        }
        self.migrationReport = migrationReport
        self.createdAt = createdAt
    }

    private static func validateRepresentation(
        representedComponents: [BackupComponent],
        outcomes: [ComponentOutcome]
    ) throws {
        let represented = Set(representedComponents)
        let outcomeComponents = Set(outcomes.map(\.component))

        if let missing = BackupComponent.allCases.first(
            where: { represented.contains($0) && !outcomeComponents.contains($0) }
        ) {
            throw ValidationError.missingOutcome(missing)
        }

        for outcome in outcomes where !represented.contains(outcome.component) {
            guard outcome.component == .readingHistory else {
                throw ValidationError.unauthorizedRepairOnlyComponent(outcome.component)
            }
            guard outcome.dependencyRepaired > 0,
                  outcome.inserted == 0,
                  outcome.replaced == 0,
                  outcome.preservedLocal == 0,
                  outcome.skipped == 0,
                  outcome.unresolved == 0 else {
                throw ValidationError.unexpectedOutcome(outcome.component)
            }
        }
    }

    private static let componentOrder = Dictionary(
        uniqueKeysWithValues: BackupComponent.allCases.enumerated().map { ($0.element, $0.offset) }
    )

    private enum CodingKeys: CodingKey {
        case operationId
        case mode
        case representedComponents
        case outcomes
        case preflightWarnings
        case migrationReport
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationId: container.decode(String.self, forKey: .operationId),
            mode: container.decode(BackupRestoreMode.self, forKey: .mode),
            representedComponents: container.decode(
                [BackupComponent].self,
                forKey: .representedComponents
            ),
            outcomes: container.decode([ComponentOutcome].self, forKey: .outcomes),
            preflightWarnings: container.decode(
                [BackupPreflightWarning].self,
                forKey: .preflightWarnings
            ),
            migrationReport: container.decodeIfPresent(MigrationReport.self, forKey: .migrationReport),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }
}
