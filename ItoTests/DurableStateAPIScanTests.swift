import Foundation
import Testing

struct DurableStateAPIScanTests {
    @Test func fiveStoresContainNoDefaultsPersistence() throws {
        for path in storePaths {
            let source = try read(path)
            for forbidden in [
                "UserDefaults.standard",
                "defaults.set(",
                ".data(forKey:",
                ".dictionary(forKey:",
                "@AppStorage"
            ] {
                #expect(!source.contains(forbidden), "\(path) contains \(forbidden)")
            }
        }
    }

    @Test func productionContainsNoBareMediaDurableAPIOrSharedManagerAccess() throws {
        let production = try allProductionSwift()
        for forbidden in [
            "ReadProgressManager.shared",
            "TrackerManager.shared",
            "UpdateManager.shared",
            "RepoManager.shared",
            "PluginResolver.shared",
            "markAsRead(mangaId:",
            "markAsWatched(animeId:",
            "isRead(mangaId:",
            "markReadUpTo(mangaId:",
            "getLastRead(mangaId:",
            "getMediaId(for:",
            "link(localId:",
            "unlink(localId:",
            "updateProgress(localId:",
            "clearBadge(for itemId:"
        ] {
            #expect(!production.contains(forbidden), "Production contains \(forbidden)")
        }
    }

    @Test func libraryAniListBareAdaptersAreAbsent() throws {
        let production = try allProductionSwift()
        for forbidden in [
            "setAnilistId",
            "removeAnilistId",
            "getAnilistId",
            "protocol LibraryManaging",
            ": LibraryManaging",
            "protocol ProgressTracking",
            ": ProgressTracking",
            "toggleSaveManga",
            "toggleSaveNovel",
            "toggleSaveAnime",
            "saveOrRemoveItem",
            "removeItem(withId:"
        ] {
            #expect(!production.contains(forbidden), "Production contains \(forbidden)")
        }
        for removedPath in [
            "Ito/Core/Protocols/LibraryManaging.swift",
            "Ito/Core/Protocols/ProgressTracking.swift",
            "Ito/ViewModels/ReaderViewModel.swift"
        ] {
            #expect(
                !FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(removedPath).path
                ),
                "\(removedPath) still exists"
            )
        }
    }

    @Test func mediaDetailRelinkDelegatesToSharedRemapperTransaction() throws {
        let viewModel = try read("Ito/ViewModels/MediaDetailViewModel.swift")
        let dependencies = try read("Ito/Services/MediaDetail/MediaDetailDependencies.swift")
        #expect(viewModel.contains("dependencies.relink.relink("))
        #expect(dependencies.contains("extension LibrarySourceRemapper: MediaDetailRelinkServing"))
        #expect(dependencies.contains("_ = try await relink("))
        #expect(dependencies.contains("possibleSourceItemIds: possibleSourceItemIDs"))
        for source in [viewModel, dependencies] {
            #expect(!source.contains("AppDatabase.shared"))
            #expect(!source.contains("UPDATE itemCategoryLink"))
            #expect(!source.contains("UPDATE readingHistory"))
            #expect(!source.contains("readProgressKey"))
            #expect(!source.contains("trackerLink"))
            #expect(!source.contains("updateBadge"))
        }
    }

    @Test func missingItemUpdateDeletesScopedBadgeInDatabaseTransaction() throws {
        let source = try read("Ito/Managers/UpdateManager.swift")
        let missingBranch = try #require(source.range(of: "guard var dbItem"))
        let badgeDelete = try #require(
            source.range(
                of: "try UpdateBadgeRecord",
                range: missingBranch.lowerBound..<source.endIndex
            )
        )
        let publishRemoval = try #require(
            source.range(
                of: "if committed.itemWasMissing",
                range: badgeDelete.upperBound..<source.endIndex
            )
        )
        #expect(badgeDelete.lowerBound < publishRemoval.lowerBound)
    }

    @Test func gatedRuntimeUsesNoManagerSharedAccess() throws {
        let production = try allProductionSwift()
        for manager in [
            "LibraryManager",
            "PluginManager",
            "StorageManager",
            "DiscordRPCManager",
            "HistoryManager",
            "NotificationManager",
            "BackupManager",
            "ReadProgressManager",
            "TrackerManager",
            "UpdateManager",
            "RepoManager",
            "PluginResolver"
        ] {
            #expect(
                !production.contains("\(manager).shared"),
                "Production runtime accesses \(manager).shared"
            )
        }
        for path in [
            "Ito/Managers/DiscordRPCManager.swift",
            "Ito/Managers/HistoryManager.swift",
            "Ito/Managers/LibraryManager.swift",
            "Ito/Managers/NotificationManager.swift",
            "Ito/Views/Shared/SnackBarOverlay.swift"
        ] {
            let source = try read(path)
            #expect(!source.contains("static let shared"), "\(path) still declares static let shared")
        }
    }

    @Test func durableManagersExposeNoPublicStringKeyedMap() throws {
        for path in [
            "Ito/Managers/ReadProgressManager.swift",
            "Ito/Tracking/TrackerManager.swift",
            "Ito/Managers/UpdateManager.swift"
        ] {
            let source = try read(path)
            let expression = try NSRegularExpression(
                pattern: #"public[^\n]*\[\s*String\s*:"#
            )
            let range = NSRange(source.startIndex..., in: source)
            #expect(expression.firstMatch(in: source, range: range) == nil)
            #expect(
                !source.contains("@Published public") || !source.contains("[String:"),
                "\(path) exposes public String-keyed durable state"
            )
        }
    }

    @Test func everyScopedConsumerConstructsOrForwardsMediaIdentity() throws {
        let consumers = [
            "Ito/ViewModels/Discover/SourceResolverViewModel.swift",
            "Ito/ViewModels/MangaReaderViewModel.swift",
            "Ito/ViewModels/NovelReaderViewModel.swift",
            "Ito/ViewModels/VideoPlayerViewModel.swift",
            "Ito/ViewModels/MediaDetailViewModel.swift",
            "Ito/ViewModels/Tracking/TrackerDetailsViewModel.swift",
            "Ito/ViewModels/LibraryViewModel.swift"
        ]
        let scopedCallPatterns = [
            "Ito/ViewModels/Discover/SourceResolverViewModel.swift": [
                "MediaIdentity(pluginId:route.pluginID,itemId:itemKey)",
                "trackerLinker.linkAniList(media:mediaIdentity"
            ],
            "Ito/ViewModels/MangaReaderViewModel.swift": [
                "MediaIdentity(pluginId:pluginID,itemId:manga.key)",
                "progress.markChapterRead(",
                "tracker.updateMangaProgress(media:identity"
            ],
            "Ito/ViewModels/NovelReaderViewModel.swift": [
                "MediaIdentity(pluginId:pluginID,itemId:novel.key)",
                "progress.markNovelChapterRead(",
                "tracker.updateNovelProgress(media:identity"
            ],
            "Ito/ViewModels/VideoPlayerViewModel.swift": [
                "MediaIdentity(pluginId:pluginID,itemId:anime.key)",
                "progress.markEpisodeWatched(",
                "tracker.updateVideoProgress(media:mediaIdentity"
            ],
            "Ito/ViewModels/MediaDetailViewModel.swift": [
                "dependencies.progress.isRead(",
                "dependencies.tracker.state(for:mediaIdentity)"
            ],
            "Ito/ViewModels/Tracking/TrackerDetailsViewModel.swift": [
                "linkStore.link(media:",
                "linkStore.unlink(media:"
            ],
            "Ito/ViewModels/LibraryViewModel.swift": [
                "MediaIdentity(pluginId:item.pluginId,itemId:item.id)",
                "updateSnapshot.badgeCount(for:mediaIdentity(for:item))",
                "updates.clearLibraryBadge(for:media)"
            ]
        ]
        for path in consumers {
            let source = try read(path)
            let whitespaceInsensitiveSource = source.filter { !$0.isWhitespace }
            for pattern in scopedCallPatterns[path, default: []] {
                #expect(
                    whitespaceInsensitiveSource.contains(pattern),
                    "\(path) does not contain scoped call \(pattern)"
                )
            }
            for forbidden in [
                "mangaId:", "animeId:", "localId:"
            ] {
                #expect(
                    !source.contains(forbidden),
                    "\(path) contains banned durable call label \(forbidden)"
                )
            }
        }
    }

    @Test func bootstrapInspectsRestoreJournalBeforeOrdinaryPreparation() throws {
        let source = try read("Ito/Managers/DurableStateBootstrap.swift")
        #expect(!source.contains("ito-bootstrap-unavailable.sqlite"))
        #expect(!source.contains("sourceDatabaseURL: URL ="))
        let prepareStart = try #require(source.range(of: "public func prepare() async -> Bool"))
        let prepareEnd = try #require(
            source.range(
                of: "public func retry() async -> Bool",
                range: prepareStart.upperBound..<source.endIndex
            )
        )
        let prepare = prepareStart.lowerBound..<prepareEnd.lowerBound
        let pendingInspection = try #require(
            source.range(of: "if try await hasPendingRestoreJournalEntries()", range: prepare)
        )
        let sourcePreparation = try #require(
            source.range(of: "try await prepareDurableSources()", range: prepare)
        )
        let makeRuntimeCall = try #require(
            source.range(of: "makeRuntime()", range: sourcePreparation.upperBound..<prepareEnd.lowerBound)
        )
        let journalRecovery = try #require(
            source.range(of: "try await recoverCommittedRestores(runtime)", range: prepare)
        )
        #expect(pendingInspection.lowerBound < sourcePreparation.lowerBound)
        #expect(sourcePreparation.lowerBound < makeRuntimeCall.lowerBound)
        #expect(makeRuntimeCall.lowerBound < journalRecovery.lowerBound)

        let readyInspection = try #require(
            source.range(
                of: "journalAccess.loadReadyToPresentReport()",
                range: journalRecovery.upperBound..<prepareEnd.lowerBound
            )
        )
        let ordinarySourcePreparation = try #require(
            source.range(
                of: "try await prepareDurableSources()",
                range: readyInspection.upperBound..<prepareEnd.lowerBound
            )
        )
        let ordinaryRuntimeConstruction = try #require(
            source.range(
                of: "makeRuntime()",
                range: ordinarySourcePreparation.upperBound..<prepareEnd.lowerBound
            )
        )
        let ordinaryPreparation = try #require(
            source.range(of: "try await finishOrdinaryPreparation(runtime)", range: prepare)
        )
        #expect(readyInspection.lowerBound < ordinarySourcePreparation.lowerBound)
        #expect(ordinarySourcePreparation.lowerBound < ordinaryRuntimeConstruction.lowerBound)
        #expect(ordinaryRuntimeConstruction.lowerBound < ordinaryPreparation.lowerBound)
        #expect(source.range(of: "install(runtime)", range: prepare) == nil)

        let acknowledgmentStart = try #require(
            source.range(of: "public func acknowledgeRestoreReport() async -> Bool")
        )
        let acknowledgmentEnd = try #require(
            source.range(
                of: "private func makeRuntime() -> Runtime",
                range: acknowledgmentStart.upperBound..<source.endIndex
            )
        )
        let acknowledgment = acknowledgmentStart.lowerBound..<acknowledgmentEnd.lowerBound
        let journalAcknowledgment = try #require(
            source.range(
                of: "journalAccess.acknowledgeReadyToPresent(",
                range: acknowledgment
            )
        )
        let remainingJournalInspection = try #require(
            source.range(
                of: "if try await hasPendingRestoreJournalEntries()",
                range: acknowledgment
            )
        )
        let resumedSourcePreparation = try #require(
            source.range(of: "try await prepareDurableSources()", range: acknowledgment)
        )
        let resumedRuntimeConstruction = try #require(
            source.range(
                of: "makeRuntime()",
                range: resumedSourcePreparation.upperBound..<acknowledgmentEnd.lowerBound
            )
        )
        let remainingJournalRecovery = try #require(
            source.range(of: "try await recoverCommittedRestores(runtime)", range: acknowledgment)
        )
        #expect(journalAcknowledgment.lowerBound < remainingJournalInspection.lowerBound)
        #expect(remainingJournalInspection.lowerBound < remainingJournalRecovery.lowerBound)
        #expect(resumedSourcePreparation.lowerBound < resumedRuntimeConstruction.lowerBound)
        #expect(resumedRuntimeConstruction.lowerBound < remainingJournalRecovery.lowerBound)

        let sourcePreparationStart = try #require(
            source.range(of: "private func prepareDurableSources() async throws")
        )
        let makeRuntimeStart = try #require(
            source.range(
                of: "private func makeRuntime() -> Runtime",
                range: sourcePreparationStart.upperBound..<source.endIndex
            )
        )
        let durableSourcePreparation =
            sourcePreparationStart.lowerBound..<makeRuntimeStart.lowerBound
        var sourceStep = try #require(
            source.range(of: "try await migration()", range: durableSourcePreparation)
        )
        for operation in [
            "for bootstrapExtension in extensions",
            "try await bootstrapExtension.prepare(dbPool: dbPool)",
            "sourcesPrepared = true"
        ] {
            let current = try #require(
                source.range(of: operation, range: durableSourcePreparation)
            )
            #expect(sourceStep.lowerBound < current.lowerBound)
            sourceStep = current
        }

        let makeRuntimeEnd = try #require(
            source.range(
                of: "private func finishOrdinaryPreparation(_ runtime: Runtime) async throws",
                range: makeRuntimeStart.upperBound..<source.endIndex
            )
        )
        let makeRuntime = makeRuntimeStart.lowerBound..<makeRuntimeEnd.lowerBound
        for constructor in [
            "let updates = UpdateManager(",
            "let progress = ReadProgressManager(",
            "let tracker = TrackerManager(",
            "let repositories = RepoManager(",
            "let resolver = PluginResolver(",
            "let library = LibraryManager(",
            "let plugins = PluginManager(",
            "let storage = StorageManager(",
            "let discord = DiscordRPCManager(",
            "let history = HistoryManager(",
            "let notifications = NotificationManager()",
            "let backup = BackupManager(",
            "let remapper = LibrarySourceRemapper("
        ] {
            #expect(
                source.range(of: constructor, range: makeRuntime) != nil,
                "makeRuntime must construct \(constructor)"
            )
        }
        for forbidden in [
            "try await migration()",
            "consumerConstructors",
            "onReady()",
            "state = .ready",
            "ItoRunner()",
            "AppDefaultsModule("
        ] {
            #expect(
                source.range(of: forbidden, range: makeRuntime) == nil,
                "makeRuntime eagerly performs ordinary work via \(forbidden)"
            )
        }

        let recoveryStart = try #require(
            source.range(
                of: "private func recoverCommittedRestores(_ runtime: Runtime) async throws",
                range: makeRuntimeEnd.upperBound..<source.endIndex
            )
        )
        let finishOrdinaryPreparation =
            makeRuntimeEnd.lowerBound..<recoveryStart.lowerBound
        var previous = try #require(
            source.range(
                of: "try await runtime.settingsStore.reload()",
                range: finishOrdinaryPreparation
            )
        )
        for operation in [
            "scalarConsumerConfiguration(runtime.settingsStore)",
            "try await runtime.pluginManager.discoverAndPrepareInstalledPlugins()",
            "try await runtime.libraryManager.reload()",
            "try await runtime.historyManager.reload()",
            "try await runtime.updateManager.reload()",
            "try await runtime.readProgressManager.reload()",
            "try await runtime.trackerManager.reload()",
            "try await runtime.repoManager.reload()",
            "try await runtime.pluginResolver.reload()",
            "try runtime.storageManager.reload()",
            "runtime.appearanceManager.reload()",
            "install(runtime)",
            "for constructor in consumerConstructors",
            "onReady()",
            "state = .ready"
        ] {
            let current = try #require(
                source.range(of: operation, range: finishOrdinaryPreparation)
            )
            #expect(
                previous.lowerBound < current.lowerBound,
                "\(operation) must remain after its preceding runtime preparation step"
            )
            previous = current
        }
        for forbidden in [
            "try await migration()",
            "for bootstrapExtension in extensions"
        ] {
            #expect(source.range(of: forbidden, range: finishOrdinaryPreparation) == nil)
        }

        let recoveryEnd = try #require(
            source.range(
                of: "private func hasPendingRestoreJournalEntries() async throws",
                range: recoveryStart.upperBound..<source.endIndex
            )
        )
        let recovery = recoveryStart.lowerBound..<recoveryEnd.lowerBound
        #expect(source.range(of: "install(runtime)", range: recovery) == nil)
        #expect(source.range(of: "state = .ready", range: recovery) == nil)

        let pluginManager = try read("Ito/Managers/PluginManager.swift")
        let initializerStart = try #require(
            pluginManager.range(of: "public init(")
        )
        let initializerEnd = try #require(
            pluginManager.range(
                of: "public func getRunner(for pluginId:",
                range: initializerStart.upperBound..<pluginManager.endIndex
            )
        )
        let initializer = initializerStart.lowerBound..<initializerEnd.lowerBound
        let settingsParameter = try #require(
            pluginManager.range(
                of: "pluginSettingsStore: PluginSettingsStore",
                range: initializer
            )
        )
        let directoryParameter = try #require(
            pluginManager.range(
                of: "pluginsDirectory: URL? = nil",
                range: settingsParameter.upperBound..<initializer.upperBound
            )
        )
        let settingsAssignment = try #require(
            pluginManager.range(
                of: "self.pluginSettingsStore = pluginSettingsStore",
                range: initializer
            )
        )
        let directoryAssignment = try #require(
            pluginManager.range(
                of: "self.pluginsDirectory = pluginsDirectory",
                range: settingsAssignment.upperBound..<initializer.upperBound
            )
        )
        #expect(settingsParameter.lowerBound < directoryParameter.lowerBound)
        #expect(directoryParameter.lowerBound < settingsAssignment.lowerBound)
        #expect(settingsAssignment.lowerBound < directoryAssignment.lowerBound)
        for forbidden in [
            "Task {",
            "discoverAndPrepareInstalledPlugins(",
            "reloadInstalledPlugins(",
            "scanInstalledPlugins(",
            "prepareForDurableSnapshot(",
            "pluginSettingsStore.prepare(",
            "ItoRunner()",
            "AppDefaultsModule(",
            "runnerCache[",
            "installedPlugins ="
        ] {
            #expect(
                pluginManager.range(of: forbidden, range: initializer) == nil,
                "PluginManager initializer eagerly performs \(forbidden)"
            )
        }

        let scanStart = try #require(
            pluginManager.range(of: "private func scanInstalledPlugins(")
        )
        let scanEnd = try #require(
            pluginManager.range(
                of: "private func publishInstalledPlugins(",
                range: scanStart.upperBound..<pluginManager.endIndex
            )
        )
        let scan = scanStart.lowerBound..<scanEnd.lowerBound
        let injectedDirectoryCheck = try #require(
            pluginManager.range(of: "if let pluginsDirectory", range: scan)
        )
        let injectedDirectoryUse = try #require(
            pluginManager.range(
                of: "pluginsDir = pluginsDirectory",
                range: injectedDirectoryCheck.upperBound..<scan.upperBound
            )
        )
        let defaultDirectoryBranch = try #require(
            pluginManager.range(
                of: "} else {",
                range: injectedDirectoryUse.upperBound..<scan.upperBound
            )
        )
        let defaultDirectoryBranchEnd = try #require(
            pluginManager.range(
                of: "guard fileManager.fileExists",
                range: defaultDirectoryBranch.upperBound..<scan.upperBound
            )
        )
        let defaultDirectoryFallback =
            defaultDirectoryBranch.lowerBound..<defaultDirectoryBranchEnd.lowerBound
        let applicationSupportLookup = try #require(
            pluginManager.range(
                of: "for: .applicationSupportDirectory",
                range: defaultDirectoryFallback
            )
        )
        let userDomainLookup = try #require(
            pluginManager.range(
                of: "in: .userDomainMask",
                range: applicationSupportLookup.upperBound..<defaultDirectoryFallback.upperBound
            )
        )
        let defaultPluginsDirectory = try #require(
            pluginManager.range(
                of: "appSupportDir.appendingPathComponent(\"Plugins\")",
                range: userDomainLookup.upperBound..<defaultDirectoryFallback.upperBound
            )
        )
        #expect(injectedDirectoryCheck.lowerBound < injectedDirectoryUse.lowerBound)
        #expect(injectedDirectoryUse.lowerBound < defaultDirectoryBranch.lowerBound)
        #expect(defaultDirectoryBranch.lowerBound < applicationSupportLookup.lowerBound)
        #expect(applicationSupportLookup.lowerBound < userDomainLookup.lowerBound)
        #expect(userDomainLookup.lowerBound < defaultPluginsDirectory.lowerBound)
    }

    @Test func bootstrapAndReadyUIFailClosedOnMissingInstalledEvidenceOrRuntime() throws {
        let bootstrap = try read("Ito/Managers/DurableStateBootstrap.swift")
        let extensionStart = try #require(
            bootstrap.range(of: "struct InstalledPluginSuiteBootstrapExtension")
        )
        let extensionSource = bootstrap[extensionStart.lowerBound..<bootstrap.endIndex]
        #expect(extensionSource.contains("throw InstalledPluginSuiteDiscoveryError"))
        #expect(!extensionSource.contains("Failed to extract plugin info"))

        let app = try read("Ito/ItoApp.swift")
        let readyStart = try #require(app.range(of: "case .ready:"))
        let failedStart = try #require(
            app.range(of: "case .failed(let message):", range: readyStart.upperBound..<app.endIndex)
        )
        let readyUI = app[readyStart.lowerBound..<failedStart.lowerBound]
        #expect(readyUI.contains("BootstrapFailureView("))
        #expect(readyUI.contains("retryRuntimeInvariantFailure()"))
    }

    @Test func productionPluginDefaultsUseOnlyAppOwnedGRDBBridge() throws {
        let production = try allProductionSwift()
        #expect(!production.contains("DefaultDefaultsModule"))
        #expect(!production.contains("UserDefaults(suiteName: \"moe.ito.runners."))

        let manager = try read("Ito/Managers/PluginManager.swift")
        let getRunnerStart = try #require(manager.range(of: "public func getRunner(for pluginId:"))
        let getRunnerEnd = try #require(
            manager.range(
                of: "public func evictRunner(for pluginId:",
                range: getRunnerStart.upperBound..<manager.endIndex
            )
        )
        let getRunner = getRunnerStart.lowerBound..<getRunnerEnd.lowerBound
        let installedPluginGuard = try #require(
            manager.range(
                of: "guard let plugin = installedPlugins[pluginId] else",
                range: getRunner
            )
        )
        let prepare = try #require(
            manager.range(of: "pluginSettingsStore.prepare(pluginId:", range: getRunner)
        )
        let cachedRunner = try #require(
            manager.range(of: "if let cached = runnerCache[pluginId]", range: getRunner)
        )
        let runner = try #require(
            manager.range(of: "let runner = ItoRunner()", range: getRunner)
        )
        let injection = try #require(
            manager.range(of: "AppDefaultsModule(pluginId:", range: getRunner)
        )
        #expect(installedPluginGuard.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < cachedRunner.lowerBound)
        #expect(cachedRunner.lowerBound < runner.lowerBound)
        #expect(prepare.lowerBound < runner.lowerBound)
        #expect(runner.lowerBound < injection.lowerBound)

        let bootstrap = try read("Ito/Managers/DurableStateBootstrap.swift")
        #expect(bootstrap.contains("PluginSettingsStore(dbPool: dbPool)"))
        #expect(bootstrap.contains("PluginManager(pluginSettingsStore: pluginSettings)"))
        #expect(!bootstrap.contains("PluginManager()"))
        let storage = try read("Ito/Managers/StorageManager.swift")
        #expect(!storage.contains("PluginManager()"))
    }

    @Test func trackerSheetsPublishOnlyAfterPersistenceCommitAndSurfaceFailures() throws {
        let viewModel = try read("Ito/ViewModels/Tracking/TrackerDetailsViewModel.swift")
        let sheets = try read("Ito/Views/Tracker/TrackerSheets.swift")

        let saveStart = try #require(viewModel.range(of: "func save()"))
        let unlinkStart = try #require(
            viewModel.range(of: "func stopTracking()", range: saveStart.upperBound..<viewModel.endIndex)
        )
        let saveRange = saveStart.lowerBound..<unlinkStart.lowerBound
        let remoteUpdate = try #require(
            viewModel.range(of: "try await detailsService.updateProgress(", range: saveRange)
        )
        let remoteFailure = try #require(
            viewModel.range(of: "failure = .remoteUpdate", range: remoteUpdate.upperBound..<saveRange.upperBound)
        )
        let conditionalLink = try #require(
            viewModel.range(of: "if !isLocallyLinked {", range: remoteFailure.upperBound..<saveRange.upperBound)
        )
        let awaitedLink = try #require(
            viewModel.range(of: "try await linkStore.link(", range: conditionalLink.upperBound..<saveRange.upperBound)
        )
        let linkFailure = try #require(
            viewModel.range(
                of: "failure = .linkPersistenceAfterRemoteUpdate",
                range: awaitedLink.upperBound..<saveRange.upperBound
            )
        )
        let savedOutput = try #require(
            viewModel.range(of: "output = TrackerDetailsOutput(", range: linkFailure.upperBound..<saveRange.upperBound)
        )
        #expect(remoteUpdate.lowerBound < remoteFailure.lowerBound)
        #expect(remoteFailure.lowerBound < conditionalLink.lowerBound)
        #expect(conditionalLink.lowerBound < awaitedLink.lowerBound)
        #expect(awaitedLink.lowerBound < linkFailure.lowerBound)
        #expect(linkFailure.lowerBound < savedOutput.lowerBound)
        #expect(
            viewModel.range(of: "return", range: remoteFailure.upperBound..<conditionalLink.lowerBound) != nil,
            "Remote failure must return before local linking"
        )
        #expect(
            viewModel.range(of: "return", range: linkFailure.upperBound..<savedOutput.lowerBound) != nil,
            "Link failure must return before publishing save success"
        )

        let unlinkEnd = try #require(
            viewModel.range(of: "func cancel()", range: unlinkStart.upperBound..<viewModel.endIndex)
        )
        let unlinkRange = unlinkStart.lowerBound..<unlinkEnd.lowerBound
        let awaitedUnlink = try #require(
            viewModel.range(of: "try await linkStore.unlink(", range: unlinkRange)
        )
        let unlinkFailure = try #require(
            viewModel.range(of: "failure = .unlinkPersistence", range: awaitedUnlink.upperBound..<unlinkRange.upperBound)
        )
        let unlinkOutput = try #require(
            viewModel.range(
                of: "output = TrackerDetailsOutput(id: UUID(), kind: .unlinked)",
                range: unlinkFailure.upperBound..<unlinkRange.upperBound
            )
        )
        #expect(awaitedUnlink.lowerBound < unlinkFailure.lowerBound)
        #expect(unlinkFailure.lowerBound < unlinkOutput.lowerBound)
        #expect(
            viewModel.range(of: "return", range: unlinkFailure.upperBound..<unlinkOutput.lowerBound) != nil,
            "Unlink failure must return before publishing unlinked success"
        )

        #expect(!sheets.contains("trackerManager.link("))
        #expect(!sheets.contains("trackerManager.unlink("))
        #expect(!sheets.contains("error.localizedDescription"))
        #expect(sheets.contains("case .saved(let progress, let status):"))
        #expect(sheets.contains("case .unlinked:"))
        #expect(sheets.contains("onTracked?(media, progress, status)"))
        #expect(sheets.contains("onTracked?(media, nil, nil)"))
        #expect(sheets.contains(".alert(\"Tracker Change Not Saved\""))
        #expect(viewModel.contains("messagePresenter.present(.remoteUpdateFailed)"))
        #expect(viewModel.contains("messagePresenter.present(.linkPersistenceFailed)"))
        #expect(viewModel.contains("messagePresenter.present(.unlinkFailed)"))
        #expect(!viewModel.contains("error.localizedDescription"))
    }

    private var storePaths: [String] {
        [
            "Ito/Managers/ReadProgressManager.swift",
            "Ito/Tracking/TrackerManager.swift",
            "Ito/Managers/UpdateManager.swift",
            "Ito/Managers/RepoManager.swift",
            "Ito/Managers/Importers/PluginResolver.swift"
        ]
    }

    private func allProductionSwift() throws -> String {
        let root = repositoryRoot.appendingPathComponent("Ito")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        )
        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
