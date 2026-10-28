import Combine
import Foundation
import XCTest
import ZIPFoundation
import ito_runner
@testable import Ito

@MainActor
final class PluginSettingsViewModelTests: XCTestCase {
    func testInitialLoadPreparesExactPluginThenReloadsAuthoritativeStore() async throws {
        let store = PR7BSettingsStoreSpy()
        let schema = try pr7bSettingsSchema()
        let viewModel = makeViewModel(schema: schema, store: store)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(store.preparedPluginIDs, ["plugin.manga"])
        XCTAssertEqual(store.reloadCount, 1)
        XCTAssertTrue(viewModel.isPrepared)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.loadError)
    }

    func testLegacySettingsAreProjectedIntoUnifiedPresentation() throws {
        let settings: [Setting] = [
            .toggle(id: "toggle", name: "Toggle", summary: nil, defaultValue: true),
            .text(id: "text", name: "Text", summary: "Summary", defaultValue: "value"),
            .picker(
                id: "picker",
                name: "Picker",
                summary: nil,
                options: ["one", "two"],
                defaultValue: "one"
            )
        ]
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: settings))

        XCTAssertEqual(viewModel.presentation.controls.count, 3)
        XCTAssertEqual(viewModel.plugin.id, "plugin.manga")
    }

    func testLegacyRawTextAndPickerValuesRemainReadableAndEditable() throws {
        let text = String(repeating: "é", count: 2_049) + "\u{0001}\n"
        let picker = String(repeating: "é", count: 129) + "\u{0001}"
        let store = PR7BSettingsStoreSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: [
            .text(id: "text", name: "Text", summary: nil, defaultValue: "default"),
            .picker(id: "picker", name: "Picker", summary: nil, options: [picker], defaultValue: picker)
        ]), store: store)
        let controls = viewModel.presentation.controls
        store.values["text"] = text
        store.values["picker"] = picker

        for (control, value) in zip(controls, [ControlValue.text(text), .select(picker)]) {
            XCTAssertEqual(viewModel.effectiveValue(for: control), value)
            XCTAssertEqual(viewModel.effectiveValueState(for: control).state, .valid)
        }
        XCTAssertTrue(viewModel.persistControlValue(.text(text + "edited"), for: controls[0]))
        XCTAssertTrue(viewModel.persistControlValue(.select(picker + "edited"), for: controls[1]))
        XCTAssertEqual(store.values["text"], text + "edited")
        XCTAssertEqual(store.values["picker"], picker + "edited")
        XCTAssertEqual(viewModel.effectiveValue(for: controls[0]), .text(text + "edited"))
        XCTAssertEqual(viewModel.effectiveValue(for: controls[1]), .select(picker + "edited"))
        XCTAssertFalse(viewModel.persistControlValue(.toggle(true), for: controls[0]))
        XCTAssertFalse(viewModel.persistControlValue(.text("wrong kind"), for: controls[1]))
        XCTAssertEqual(store.writes.count, 2)
        viewModel.cancel()
    }

    func testLegacyEmptyPickerOptionRoundTripsWithANonemptyDefault() throws {
        let store = PR7BSettingsStoreSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: [
            .picker(id: "emptyDefault", name: "Empty default", summary: nil, options: ["", "other"], defaultValue: ""),
            .picker(id: "choice", name: "Choice", summary: nil, options: ["", "other"], defaultValue: "other")
        ]), store: store)
        let emptyDefault = viewModel.presentation.controls[0]
        let choice = viewModel.presentation.controls[1]
        XCTAssertEqual(viewModel.effectiveValue(for: emptyDefault), .select(""))
        XCTAssertEqual(viewModel.effectiveValue(for: choice), .select("other"))
        XCTAssertEqual(viewModel.effectiveValueState(for: choice).state, .unset)
        let read = { viewModel.effectiveValue(for: choice) ?? .select(nil) }
        let write: (ControlValue) -> Void = { _ = viewModel.persistControlValue($0, for: choice) }
        XCTAssertTrue(ControlSelectionEditing.toggle("", control: choice, currentValue: read, onChange: write))
        XCTAssertEqual(store.values["choice"], "")
        XCTAssertEqual(read(), .select(""))
        XCTAssertEqual(read().selectedOptions, [""])
        XCTAssertEqual(viewModel.effectiveValueState(for: choice).state, .valid)
        XCTAssertTrue(viewModel.resetControl(choice))
        XCTAssertNil(store.values["choice"])
        XCTAssertEqual(read(), .select("other"))
        viewModel.cancel()
    }

    func testLegacyToggleUsesDefaultOnlyWhenAbsentAndExactTrueOtherwise() throws {
        let store = PR7BSettingsStoreSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: [
            .toggle(id: "toggle", name: "Toggle", summary: nil, defaultValue: true)
        ]), store: store)
        let control = viewModel.presentation.controls[0]
        XCTAssertEqual(viewModel.effectiveValue(for: control), .toggle(true))
        XCTAssertEqual(viewModel.effectiveValueState(for: control).state, .unset)
        for stored in ["false", "", "TRUE", "invalid"] {
            store.values["toggle"] = stored
            XCTAssertEqual(viewModel.effectiveValue(for: control), .toggle(false))
            XCTAssertEqual(viewModel.effectiveValueState(for: control).state, .valid)
        }
        store.values["toggle"] = "true"
        XCTAssertEqual(viewModel.effectiveValue(for: control), .toggle(true))
        XCTAssertTrue(viewModel.persistControlValue(.toggle(false), for: control))
        XCTAssertEqual(store.values["toggle"], "false")
        XCTAssertFalse(viewModel.persistControlValue(.text("true"), for: control))
        viewModel.cancel()
    }

    func testRichTextAndPickerStillRejectOversizedAndControlCharacterValues() {
        let store = PR7BSettingsStoreSpy()
        let text = richControl("text", .text(TextControl(defaultValue: "default", placeholder: nil, flags: [])))
        let picker = richControl("picker", .select(SelectControl(options: .inline([]), defaultValue: nil)))
        let viewModel = richViewModel([text, picker], store: store)
        for invalid in [String(repeating: "é", count: 2_049), "control\u{0001}"] {
            store.values["text"] = invalid
            XCTAssertEqual(viewModel.effectiveValue(for: text), .text("default"))
            XCTAssertEqual(viewModel.effectiveValueState(for: text).state, .invalid)
            XCTAssertFalse(viewModel.persistControlValue(.text(invalid), for: text))
            XCTAssertEqual(store.values["text"], invalid)
        }
        for invalid in [String(repeating: "é", count: 129), "control\u{0001}"] {
            store.values["picker"] = invalid
            XCTAssertEqual(viewModel.effectiveValue(for: picker), .select(nil))
            XCTAssertEqual(viewModel.effectiveValueState(for: picker).state, .invalid)
            XCTAssertFalse(viewModel.persistControlValue(.select(invalid), for: picker))
            XCTAssertEqual(store.values["picker"], invalid)
        }
        XCTAssertTrue(store.writes.isEmpty)
        viewModel.cancel()
    }

    func testExplicitRichSelectionClearKeepsMigratedKeyUntilReset() {
        let store = PR7BSettingsStoreSpy()
        store.values["discover_spotlight_genre"] = "Action"
        let control = richControl("discover_spotlight_genre_id", .select(SelectControl(
            options: .inline([ChoiceOption(value: "action", label: "Action")]), defaultValue: nil
        )))
        let viewModel = richViewModel([control], store: store)
        XCTAssertTrue(viewModel.persistControlValue(.select("action"), for: control))
        XCTAssertTrue(viewModel.persistControlValue(.select(nil), for: control))
        XCTAssertEqual(store.values[control.id], "")
        XCTAssertEqual(store.values["discover_spotlight_genre"], "Action")
        XCTAssertEqual(viewModel.effectiveValue(for: control), .select(nil))
        XCTAssertEqual(viewModel.effectiveValueState(for: control).state, .valid)
        XCTAssertTrue(viewModel.resetControl(control))
        XCTAssertNil(store.values[control.id])
        XCTAssertEqual(store.values["discover_spotlight_genre"], "Action")
        XCTAssertEqual(viewModel.effectiveValueState(for: control).state, .unset)
        viewModel.cancel()
    }
    func testIntegerDraftCommitsOnlyValidBoundedValues() {
        let kind = ControlKind.integer(IntegerControl(min: 1900, max: 2100, defaultValue: nil, unit: nil))
        var draft = IntegerControlDraft(value: .integer(nil))
        draft.edit(lower: "2101", kind: kind)
        XCTAssertNil(draft.committedValue(kind: kind))
        XCTAssertEqual(draft.lower, "2101")
        XCTAssertNotNil(draft.error)
        draft.edit(lower: " 2025 ", kind: kind)
        XCTAssertEqual(draft.committedValue(kind: kind), .integer(2025))
        XCTAssertNil(draft.error)
        draft.edit(lower: "", kind: kind)
        XCTAssertEqual(draft.committedValue(kind: kind), .integer(nil))
    }

    func testRapidMultiEditsReadStoreAndFailedWriteDoesNotBecomeNextInput() {
        let store = PR7BSettingsStoreSpy()
        let control = richControl("tags", .multiSelect(MultiSelectControl(
            options: .inline([]), defaultValue: [], maxSelected: 2
        )))
        let viewModel = richViewModel([control], store: store)
        let read = { viewModel.effectiveValue(for: control) ?? .multiSelect([]) }
        let write: (ControlValue) -> Void = { _ = viewModel.persistControlValue($0, for: control) }
        XCTAssertTrue(ControlSelectionEditing.toggle("a", control: control, currentValue: read, onChange: write))
        XCTAssertTrue(ControlSelectionEditing.toggle("b", control: control, currentValue: read, onChange: write))
        XCTAssertEqual(read(), .multiSelect(["a", "b"]))
        XCTAssertFalse(ControlSelectionEditing.toggle("c", control: control, currentValue: read, onChange: write))
        XCTAssertEqual(store.writes.count, 2)

        store.persistSucceeds = false
        XCTAssertTrue(ControlSelectionEditing.toggle("a", control: control, currentValue: read, onChange: write))
        XCTAssertEqual(read(), .multiSelect(["a", "b"]))
        XCTAssertNotNil(viewModel.persistenceError)
        store.persistSucceeds = true
        XCTAssertTrue(ControlSelectionEditing.toggle("b", control: control, currentValue: read, onChange: write))
        XCTAssertEqual(read(), .multiSelect(["a"]))
        viewModel.cancel()
    }

    func testByteDistinctMultiSelectionsRetainOrderLimitAndRollback() {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let store = PR7BSettingsStoreSpy()
        let control = richControl("tags", .multiSelect(MultiSelectControl(
            options: .inline([
                ChoiceOption(value: composed, label: "Composed", group: nil),
                ChoiceOption(value: decomposed, label: "Decomposed", group: nil),
                ChoiceOption(value: "other", label: "Other", group: nil)
            ]), defaultValue: [], maxSelected: 2
        )))
        let viewModel = richViewModel([control], store: store)
        let read = { viewModel.effectiveValue(for: control) ?? .multiSelect([]) }
        let write: (ControlValue) -> Void = { _ = viewModel.persistControlValue($0, for: control) }
        let identities = { read().selectedOptions.map { Data($0.utf8) } }
        XCTAssertTrue(ControlSelectionEditing.toggle(composed, control: control, currentValue: read, onChange: write))
        XCTAssertTrue(ControlSelectionEditing.toggle(decomposed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(identities(), [Data(composed.utf8), Data(decomposed.utf8)])
        XCTAssertFalse(ControlSelectionEditing.toggle("other", control: control, currentValue: read, onChange: write))
        XCTAssertEqual(store.writes.count, 2)

        store.persistSucceeds = false
        XCTAssertTrue(ControlSelectionEditing.toggle(decomposed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(identities(), [Data(composed.utf8), Data(decomposed.utf8)])
        XCTAssertNotNil(viewModel.persistenceError)
        store.persistSucceeds = true
        XCTAssertTrue(ControlSelectionEditing.toggle(composed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(identities(), [Data(decomposed.utf8)])
        XCTAssertTrue(ControlSelectionEditing.toggle(composed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(identities(), [Data(decomposed.utf8), Data(composed.utf8)])
        XCTAssertTrue(ControlSelectionEditing.toggle(decomposed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(identities(), [Data(composed.utf8)])
        viewModel.cancel()
    }

    func testByteDistinctSingleSelectionSwitchesToExactTappedValue() {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let store = PR7BSettingsStoreSpy()
        let control = richControl("language", .select(SelectControl(
            options: .inline([
                ChoiceOption(value: composed, label: "Composed", group: nil),
                ChoiceOption(value: decomposed, label: "Decomposed", group: nil)
            ]), defaultValue: nil
        )))
        let viewModel = richViewModel([control], store: store)
        let read = { viewModel.effectiveValue(for: control) ?? .select(nil) }
        let write: (ControlValue) -> Void = { _ = viewModel.persistControlValue($0, for: control) }
        XCTAssertTrue(ControlSelectionEditing.toggle(composed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(read().selectedOptions.map { Data($0.utf8) }, [Data(composed.utf8)])
        XCTAssertTrue(ControlSelectionEditing.toggle(decomposed, control: control, currentValue: read, onChange: write))
        XCTAssertEqual(read().selectedOptions.map { Data($0.utf8) }, [Data(decomposed.utf8)])
        viewModel.cancel()
    }

    func testInvalidStoredValueIsRetainedUntilAnExplicitEditOrReset() {
        let store = PR7BSettingsStoreSpy()
        let control = richControl("year", .integer(IntegerControl(min: 0, max: 100, defaultValue: 10, unit: nil)))
        store.values["year"] = "999"
        let viewModel = richViewModel([control], store: store)
        XCTAssertEqual(viewModel.effectiveValue(for: control), .integer(10))
        XCTAssertEqual(control.effectiveValue(stored: store.values["year"]).state, .invalid)
        XCTAssertEqual(store.values["year"], "999")
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(viewModel.persistControlValue(.integer(101), for: control))
        XCTAssertEqual(store.values["year"], "999")
        XCTAssertTrue(viewModel.resetControl(control))
        XCTAssertNil(store.values["year"])
        XCTAssertEqual(viewModel.effectiveValue(for: control), .integer(10))
        viewModel.cancel()
    }

    func testSelectFailureKeepsStoredSelectionAndResetRemovesTheKey() {
        let store = PR7BSettingsStoreSpy()
        let control = richControl("language", .select(SelectControl(options: .inline([]), defaultValue: nil)))
        let viewModel = richViewModel([control], store: store)
        XCTAssertTrue(viewModel.persistControlValue(.select("old"), for: control))
        store.persistSucceeds = false
        XCTAssertFalse(viewModel.persistControlValue(.select("new"), for: control))
        XCTAssertEqual(viewModel.effectiveValue(for: control), .select("old"))
        XCTAssertFalse(viewModel.resetControl(control))
        XCTAssertEqual(viewModel.effectiveValue(for: control), .select("old"))
        store.persistSucceeds = true
        XCTAssertTrue(viewModel.resetControl(control))
        XCTAssertNil(store.values["language"])
        XCTAssertEqual(viewModel.effectiveValue(for: control), .select(nil))
        viewModel.cancel()
    }

    func testVisibilityUsesEffectiveValuesAndPreservesHiddenStoredValues() {
        let store = PR7BSettingsStoreSpy()
        let toggle = richControl("advanced", .toggle(ToggleControl(defaultValue: false)))
        let dependent = Control(
            id: "detail", title: "Detail", summary: nil, flags: 0,
            visibleWhen: [ControlCondition(control: "advanced", anyOf: ["true"])],
            kind: .text(TextControl(defaultValue: "", placeholder: nil, flags: []))
        )
        store.values["detail"] = "kept"
        let viewModel = richViewModel([toggle, dependent], store: store)
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["advanced"])
        XCTAssertTrue(viewModel.persistControlValue(.toggle(true), for: toggle))
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["advanced", "detail"])
        XCTAssertTrue(viewModel.resetControl(toggle))
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["advanced"])
        XCTAssertEqual(store.values["detail"], "kept")
        viewModel.cancel()
    }

    func testFutureControlDoesNotHideSupportedDependentSettings() {
        let store = PR7BSettingsStoreSpy()
        let future = richControl("future", .unsupported(tag: 99))
        let dependent = Control(
            id: "detail", title: "Detail", visibleWhen: [
                ControlCondition(control: "future", anyOf: ["enabled"])
            ], kind: .toggle(ToggleControl(defaultValue: false))
        )
        let viewModel = richViewModel([future, dependent], store: store)
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["future", "detail"])
        viewModel.cancel()
    }

    func testVisibilityDistinguishesByteDistinctOptionValues() {
        let store = PR7BSettingsStoreSpy()
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        let target = richControl("choice", .select(SelectControl(
            options: .inline([
                ChoiceOption(value: composed, label: "First"),
                ChoiceOption(value: decomposed, label: "Second")
            ]), defaultValue: composed
        )))
        let dependent = Control(
            id: "detail", title: "Detail", visibleWhen: [
                ControlCondition(control: "choice", anyOf: [decomposed])
            ], kind: .toggle(ToggleControl(defaultValue: false))
        )
        let viewModel = richViewModel([target, dependent], store: store)
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["choice"])
        XCTAssertTrue(viewModel.persistControlValue(.select(decomposed), for: target))
        XCTAssertEqual(viewModel.visibleSections.flatMap(\.controls).map(\.id), ["choice", "detail"])
        viewModel.cancel()
    }

    func testIntegerRangesRejectInvalidDraftsWithoutChangingTheirText() {
        let kind = ControlKind.integerRange(IntegerRangeControl(
            min: -10, max: 100, defaultLower: nil, defaultUpper: nil, unit: nil
        ))
        var draft = IntegerControlDraft(value: .integerRange(lower: 1, upper: 10))
        for invalid in ["1.5", "101", "-11", "9223372036854775808", "text"] {
            draft.edit(lower: invalid, kind: kind)
            XCTAssertNil(draft.committedValue(kind: kind))
            XCTAssertEqual(draft.lower, invalid)
            XCTAssertNotNil(draft.error)
        }
        draft.edit(lower: "20", upper: "10", kind: kind)
        XCTAssertNil(draft.committedValue(kind: kind))
        XCTAssertEqual(draft.lower, "20")
        XCTAssertEqual(draft.upper, "10")
        draft.edit(lower: " -10 ", upper: "100", kind: kind)
        XCTAssertEqual(draft.committedValue(kind: kind), .integerRange(lower: -10, upper: 100))
        draft.edit(lower: "", upper: "100", kind: kind)
        XCTAssertEqual(draft.committedValue(kind: kind), .integerRange(lower: nil, upper: 100))
        draft.edit(lower: "", upper: "", kind: kind)
        XCTAssertEqual(draft.committedValue(kind: kind), .integerRange(lower: nil, upper: nil))
        XCTAssertNil(draft.error)
    }

    private func richControl(_ id: String, _ kind: ControlKind) -> Control {
        Control(id: id, title: id, summary: nil, flags: 0, visibleWhen: [], kind: kind)
    }

    private func richViewModel(_ controls: [Control], store: PR7BSettingsStoreSpy) -> PluginSettingsViewModel {
        PluginSettingsViewModel(
            plugin: pr7bPlugin(),
            surface: .form(SettingsForm(sections: [
                ControlSection(id: "rich", title: "Rich", summary: nil, flags: [], controls: controls)
            ])),
            settingsStore: store, messagePresenter: PR7BMessagePresenterSpy()
        )
    }

    func testBindingReadsAuthoritativeStoreAndTracksRevisionPublication() throws {
        let store = PR7BSettingsStoreSpy()
        store.values["theme"] = "dark"
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertEqual(viewModel.storedValue(key: "theme"), "dark")
        store.values["theme"] = "light"
        store.revision += 1

        XCTAssertEqual(viewModel.bindingRevision, 1)
        XCTAssertEqual(viewModel.storedValue(key: "theme"), "light")
        XCTAssertEqual(store.reads.map(\.key), ["theme", "theme"])
    }

    func testImmediatePersistenceSuccessWritesOnceAndReloads() async throws {
        let store = PR7BSettingsStoreSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertTrue(viewModel.persistValue(key: "theme", value: "dark"))
        await pr7bWaitUntil { store.reloadCount == 1 }

        XCTAssertEqual(store.writes.map { ($0.pluginID, $0.key, $0.value) }.count, 1)
        XCTAssertEqual(store.writes.first?.pluginID, "plugin.manga")
        XCTAssertEqual(store.writes.first?.key, "theme")
        XCTAssertEqual(store.writes.first?.value, "dark")
        XCTAssertEqual(store.values["theme"], "dark")
        XCTAssertNil(viewModel.persistenceError)
    }

    func testPersistenceFailureKeepsAuthoritativeValueAndPresentsFailure() throws {
        let store = PR7BSettingsStoreSpy()
        store.values["theme"] = "committed"
        store.persistSucceeds = false
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        XCTAssertFalse(viewModel.persistValue(key: "theme", value: "uncommitted"))

        XCTAssertEqual(store.values["theme"], "committed")
        XCTAssertEqual(viewModel.storedValue(key: "theme"), "committed")
        XCTAssertEqual(viewModel.persistenceError, "The setting could not be saved.")
        XCTAssertEqual(
            messages.messages,
            [.settingsPersistenceFailed(pluginName: "Fixture Source")]
        )
        XCTAssertEqual(store.reloadCount, 0)
    }

    func testPrepareFailureIsVisibleRecoverableAndDoesNotReload() async throws {
        let store = PR7BSettingsStoreSpy()
        store.prepareError = PR7BTestFailure.failed
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.isPrepared)
        XCTAssertEqual(viewModel.loadError, "fixture failure")
        XCTAssertEqual(store.reloadCount, 0)
        XCTAssertEqual(messages.messages, [
            .settingsLoadFailed(pluginName: "Fixture Source", reason: "fixture failure")
        ])

        store.prepareError = nil
        await viewModel.load()
        XCTAssertTrue(viewModel.isPrepared)
        XCTAssertEqual(store.reloadCount, 1)
    }

    func testReloadFailureIsVisibleAndRetryClearsFailure() async throws {
        let store = PR7BSettingsStoreSpy()
        store.reloadResults = [.failure(PR7BTestFailure.failed), .success(())]
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.reloadError, "fixture failure")
        XCTAssertEqual(messages.messages, [
            .settingsReloadFailed(pluginName: "Fixture Source", reason: "fixture failure")
        ])

        await viewModel.reload()
        XCTAssertNil(viewModel.reloadError)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertEqual(store.reloadCount, 2)
    }

    func testOlderNonCooperativeReloadCannotOverwriteNewerSuccess() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        let old = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 1 }
        let fresh = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 2 }

        store.completeReload(at: 0, with: .failure(PR7BTestFailure.failed))
        await old.value
        XCTAssertTrue(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)

        store.completeReload(at: 0, with: .success(()))
        await fresh.value
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testCancelSuppressesOutstandingReloadCompletion() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        let task = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 1 }
        viewModel.cancel()
        store.completeReload(with: .failure(PR7BTestFailure.failed))
        await task.value

        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testImmediateCancelOwnsPersistenceTriggeredReloadBeforeItCanStart() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertTrue(viewModel.persistValue(key: "theme", value: "dark"))
        viewModel.cancel()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(store.reloadCount, 0)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testOpeningSettingsNeverMaterializesSchemaDefaults() async throws {
        let store = PR7BSettingsStoreSpy()
        let settings: [Setting] = [
            .toggle(id: "toggle", name: "Toggle", summary: nil, defaultValue: true),
            .text(id: "text", name: "Text", summary: nil, defaultValue: "value")
        ]
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: settings), store: store)

        await viewModel.loadIfNeeded()

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(store.values["toggle"])
        XCTAssertNil(store.values["text"])
    }

    func testCompletionPresentationIsScopedToThisSourceWithFixedReasonText() throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([
            PluginCompletionSummary(
                pluginID: "other.source", pendingCount: 9, pausedCount: 9,
                pauseReasons: [.credentials]
            ),
            PluginCompletionSummary(
                pluginID: "plugin.manga", pendingCount: 2, pausedCount: 3,
                pauseReasons: [.retryLimit, .configurationChanged]
            )
        ])
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)

        XCTAssertEqual(viewModel.completionPresentation, CompletionPresentation(
            pendingCount: 2,
            pausedCount: 3,
            pauseReasons: [
                PluginCompletionPauseReason.configurationChanged.recoveryDescription,
                PluginCompletionPauseReason.retryLimit.recoveryDescription
            ]
        ))

        recovery.summaries.send([
            PluginCompletionSummary(
                pluginID: "plugin.manga", pendingCount: 1, pausedCount: 0, pauseReasons: []
            )
        ])
        XCTAssertEqual(viewModel.completionPresentation?.pendingCount, 1)
        XCTAssertEqual(viewModel.completionPresentation?.pauseReasons, [])

        recovery.summaries.send([])
        XCTAssertNil(viewModel.completionPresentation)
    }

    func testReauthorizeRequiresExplicitConfirmationAndTargetsThisSourceOnly() async throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([pausedSummary(pausedCount: 2)])
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)

        viewModel.requestCompletionRecovery(.reauthorize)
        XCTAssertEqual(viewModel.completionRecoveryRequest, .reauthorize)
        XCTAssertTrue(recovery.calls.isEmpty)

        viewModel.cancelCompletionRecoveryRequest()
        XCTAssertNil(viewModel.confirmCompletionRecovery())
        XCTAssertTrue(recovery.calls.isEmpty)

        viewModel.requestCompletionRecovery(.reauthorize)
        await viewModel.confirmCompletionRecovery()?.value

        XCTAssertEqual(recovery.calls, [.reauthorize("plugin.manga")])
        XCTAssertNil(viewModel.completionRecoveryRequest)
        XCTAssertFalse(viewModel.isRecoveringCompletion)
        XCTAssertNil(viewModel.completionRecoveryError)
    }

    func testDiscardRequiresExplicitConfirmation() async throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([pausedSummary(pausedCount: 1)])
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)

        viewModel.requestCompletionRecovery(.discard)
        XCTAssertTrue(recovery.calls.isEmpty)
        await viewModel.confirmCompletionRecovery()?.value

        XCTAssertEqual(recovery.calls, [.discard("plugin.manga")])
    }

    func testRecoveryIsNotOfferedWithoutPausedProgressOrRecoveryDependency() async throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([
            PluginCompletionSummary(
                pluginID: "plugin.manga", pendingCount: 4, pausedCount: 0, pauseReasons: []
            )
        ])
        let withRecovery = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)
        withRecovery.requestCompletionRecovery(.reauthorize)
        XCTAssertNil(withRecovery.completionRecoveryRequest)
        XCTAssertNil(withRecovery.confirmCompletionRecovery())

        let withoutRecovery = makeViewModel(schema: try pr7bSettingsSchema())
        withoutRecovery.requestCompletionRecovery(.discard)
        XCTAssertNil(withoutRecovery.completionRecoveryRequest)
        XCTAssertNil(withoutRecovery.completionPresentation)
        XCTAssertTrue(recovery.calls.isEmpty)
    }

    func testRecoveryFailureIsVisibleSanitizedAndRetryable() async throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([pausedSummary(pausedCount: 1)])
        recovery.error = PR7BTestFailure.failed
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)

        viewModel.requestCompletionRecovery(.reauthorize)
        await viewModel.confirmCompletionRecovery()?.value

        XCTAssertEqual(
            viewModel.completionRecoveryError,
            "The queued progress could not be updated. Try again."
        )
        XCTAssertFalse(viewModel.isRecoveringCompletion)

        recovery.error = nil
        viewModel.requestCompletionRecovery(.reauthorize)
        XCTAssertNil(viewModel.completionRecoveryError)
        await viewModel.confirmCompletionRecovery()?.value
        XCTAssertNil(viewModel.completionRecoveryError)
        XCTAssertEqual(recovery.calls.count, 2)
    }

    func testConfirmedRecoveryRunsOnceAndSurvivesSettingsClosing() async throws {
        let recovery = PR7BCompletionRecoverySpy()
        recovery.summaries.send([pausedSummary(pausedCount: 1)])
        recovery.suspends = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), recovery: recovery)

        viewModel.requestCompletionRecovery(.discard)
        let task = try XCTUnwrap(viewModel.confirmCompletionRecovery())
        await pr7bWaitUntil { recovery.calls.count == 1 }
        XCTAssertTrue(viewModel.isRecoveringCompletion)

        viewModel.requestCompletionRecovery(.reauthorize)
        XCTAssertNil(viewModel.completionRecoveryRequest)
        XCTAssertNil(viewModel.confirmCompletionRecovery())
        viewModel.cancel()
        XCTAssertTrue(viewModel.isRecoveringCompletion)

        recovery.complete()
        await task.value
        XCTAssertFalse(viewModel.isRecoveringCompletion)
        XCTAssertEqual(recovery.calls, [.discard("plugin.manga")])
    }

    func testArchivedDeletionConfirmationNamesExactStablePluginAndDoesNotActEarly() {
        let plugin = pr7bPlugin(id: "archived.exact", name: "Archived Exact", archived: true)
        let files = PR7BFileDeletionSpy()
        let viewModel = makeSourceDeletionViewModel(plugin: plugin, files: files)

        viewModel.requestArchivedPluginDeletion()

        XCTAssertTrue(viewModel.showArchivedPluginDeleteConfirmation)
        XCTAssertEqual(viewModel.plugin.id, "archived.exact")
        XCTAssertEqual(viewModel.plugin.info.name, "Archived Exact")
        XCTAssertEqual(files.snapshotPlugins.map(\.id), [plugin.id])
        XCTAssertTrue(files.stagedSnapshots.isEmpty)
    }

    func testArchivedDeletionSuccessPublishesAndDismissesOnlyAfterDurableCommit() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeSourceDeletionViewModel(publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        let task = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(files.transaction.commitCount, 0)

        publisher.complete()
        await task.value
        XCTAssertEqual(files.transaction.commitCount, 1)
        XCTAssertEqual(publisher.publishCount, 1)
        XCTAssertTrue(viewModel.shouldDismiss)
    }

    func testArchivedDeletionFailureDoesNotDismissAndUsesInjectedMessage() async {
        let files = PR7BFileDeletionSpy()
        files.transaction.commitError = PR7BTestFailure.failed
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeSourceDeletionViewModel(files: files, messages: messages)
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(files.transaction.rollbackCount, 1)
        XCTAssertEqual(messages.messages.count, 1)
        guard case .archivedPluginDeleteFailed(let name, let reason) = messages.messages[0] else {
            return XCTFail("Expected archived delete failure message")
        }
        XCTAssertEqual(name, "Fixture Source")
        XCTAssertEqual(reason, "fixture failure")
    }

    func testDuplicateArchivedDeletionTapIsSuppressed() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeSourceDeletionViewModel(publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        let first = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(files.stagedSnapshots.count, 1)
        XCTAssertEqual(publisher.callCount, 1)
        publisher.complete()
        await first.value
    }

    func testLocalFileDeletionTransactionUsesConfiguredDirectoryAndSupportsRollbackAndCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BFileBoundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pluginURL = root.appendingPathComponent("fixture.ito")
        let operations = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: root
        )

        let plugin = InstalledPlugin(
            url: pluginURL,
            info: PluginInfo(
                id: "fixture",
                name: "Archived Fixture",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga,
                archived: true
            ),
            iconData: nil
        )
        try makePluginArchive(id: plugin.id, archived: true).write(to: pluginURL)
        let rollbackSnapshot = try operations.snapshotPluginFile(for: plugin)
        let rollbackTransaction = try operations.stagePluginFileDeletion(from: rollbackSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        try rollbackTransaction.rollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginURL.path))

        let commitSnapshot = try operations.snapshotPluginFile(for: plugin)
        let commitTransaction = try operations.stagePluginFileDeletion(from: commitSnapshot)
        try commitTransaction.commit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFileSnapshotRejectsReplacementBetweenConfirmationAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BFileReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pluginURL = root.appendingPathComponent("fixture.ito")
        try makePluginArchive(id: "fixture", archived: true).write(to: pluginURL)
        let plugin = InstalledPlugin(
            url: pluginURL,
            info: PluginInfo(
                id: "fixture",
                name: "Archived Fixture",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga,
                archived: true
            ),
            iconData: nil
        )
        let operations = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: root
        )
        let snapshot = try operations.snapshotPluginFile(for: plugin)
        try makePluginArchive(id: "replacement", archived: true).write(
            to: pluginURL,
            options: .atomic
        )

        XCTAssertThrowsError(try operations.stagePluginFileDeletion(from: snapshot)) { error in
            XCTAssertEqual(
                error as? SourcePluginFileError,
                .stalePluginIdentity
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginURL.path))
    }

    func testArchivedDeletionIntegratesConfiguredFileBoundaryWithPluginManagerPublication() async throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BPluginManagerBoundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pluginURL = directory.appendingPathComponent("archived.fixture.ito")
        try makePluginArchive(id: "archived.fixture", archived: true).write(to: pluginURL)
        let domains = PR7BPluginDomainCatalog()
        let store = PluginSettingsStore(
            dbPool: testDatabase.dbPool,
            standardApplicationDomain: "test.pr7b",
            domainFactory: domains.domain
        )
        let manager = PluginManager(pluginSettingsStore: store, pluginsDirectory: directory)
        try await manager.discoverAndPrepareInstalledPlugins()
        let plugin = try XCTUnwrap(manager.installedPlugins["archived.fixture"])
        let files = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: directory
        )
        let viewModel = SourceViewModel(
            plugin: plugin,
            runnerProvider: PR7BSourceRunnerProviderSpy(),
            pluginStatePublisher: manager,
            fileDeletion: files,
            messagePresenter: PR7BMessagePresenterSpy(),
            searchDebounceNanoseconds: nil
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertTrue(manager.installedPlugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        XCTAssertTrue(viewModel.shouldDismiss)
    }

    func makeViewModel(
        schema: SettingsSchema,
        store: PR7BSettingsStoreSpy = PR7BSettingsStoreSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy(),
        recovery: (any PluginCompletionRecovering)? = nil,
        diagnostics: (any PluginSettingsDiagnosing)? = nil
    ) -> PluginSettingsViewModel {
        PluginSettingsViewModel(
            plugin: pr7bPlugin(),
            surface: .legacy(schema, formFailure: nil),
            settingsStore: store,
            messagePresenter: messages,
            completionRecovery: recovery,
            diagnostics: diagnostics
        )
    }

    private func pausedSummary(pausedCount: Int) -> PluginCompletionSummary {
        PluginCompletionSummary(
            pluginID: "plugin.manga",
            pendingCount: 0,
            pausedCount: pausedCount,
            pauseReasons: [.configurationChanged]
        )
    }

    private func makeSourceDeletionViewModel(
        plugin: InstalledPlugin = pr7bPlugin(archived: true),
        publisher: PR7BPluginStatePublisherSpy = PR7BPluginStatePublisherSpy(),
        files: PR7BFileDeletionSpy = PR7BFileDeletionSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy()
    ) -> SourceViewModel {
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: PR7BSourceRunnerProviderSpy(),
            pluginStatePublisher: publisher,
            fileDeletion: files,
            messagePresenter: messages,
            searchDebounceNanoseconds: nil
        )
    }

    private func makePluginArchive(id: String, archived: Bool) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BArchive-\(UUID().uuidString)")
        let archiveURL = directory.appendingPathComponent("fixture.ito")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let manifest = Data(
            """
            {
              "id": "\(id)",
              "name": "Archived Fixture",
              "version": "1.0",
              "min_app_version": "1.0",
              "type": "manga",
              "archived": \(archived)
            }
            """.utf8
        )
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count)
        ) { position, size in
            let start = Int(position)
            return manifest.subdata(in: start..<min(start + size, manifest.count))
        }
        return try Data(contentsOf: archiveURL)
    }

}

private final class PR7BPluginDomainCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String: PR7BEmptyPluginDomain] = [:]

    func domain(_ name: String) -> any LegacyDefaultsDomain {
        lock.withLock {
            if let domain = domains[name] { return domain }
            let domain = PR7BEmptyPluginDomain(name: name)
            domains[name] = domain
            return domain
        }
    }
}

private final class PR7BEmptyPluginDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String

    init(name: String) {
        domainName = name
    }

    func persistentDomain() -> [String: Any] { [:] }
    func removeObject(forKey key: String) { _ = key }
}

@MainActor
private final class PR7BCompletionRecoverySpy: PluginCompletionRecovering {
    enum Call: Equatable {
        case reauthorize(String)
        case discard(String)
    }

    let summaries = CurrentValueSubject<[PluginCompletionSummary], Never>([])
    private(set) var calls: [Call] = []
    var error: (any Error)?
    var suspends = false
    private var continuation: CheckedContinuation<Void, Never>?

    var completionSummariesPublisher: AnyPublisher<[PluginCompletionSummary], Never> {
        summaries.eraseToAnyPublisher()
    }

    func reauthorize(pluginID: String) async throws {
        calls.append(.reauthorize(pluginID))
        try await finish()
    }

    func discard(pluginID: String) async throws {
        calls.append(.discard(pluginID))
        try await finish()
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }

    private func finish() async throws {
        if suspends {
            await withCheckedContinuation { continuation = $0 }
        }
        if let error { throw error }
    }
}
