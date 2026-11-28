import Combine
import SwiftUI

/// A detail root kept alive while its selection is shown, so SwiftUI does not rebuild
/// the detail when the arrangement re-parents it.
@MainActor
final class RetainedPaneRoot {
    let key: AnyHashable
    let view: AnyView
    var hasAppeared = false
    private(set) var isReleased = false

    init(key: AnyHashable, view: AnyView) {
        self.key = key
        self.view = view
    }

    func release() {
        isReleased = true
    }
}

/// Arrangement, coverage and detail retention for one `PaneHost`.
@MainActor
final class PaneHostState: ObservableObject {
    /// `nil` until the first layout pass; the host renders `.stack` until then.
    @Published private(set) var arrangement: PaneArrangement?

    let lifecycle = PaneLifecycleRegistry()
    private(set) var holdTokens: Set<UUID> = []
    private(set) var isRootCovered = false
    private(set) var isHostVisible = false
    private(set) var currentRoot: RetainedPaneRoot?

    private var widthClass: WidthClass = .compact
    private var hasDetail = false
    private var willCollapse: () -> Void = {}

    var holdSink: PaneHoldSink {
        PaneHoldSink { [weak self] token, active in
            self?.setModalHold(token, active: active)
        }
    }

    var stackLinkDestination: AnyView {
        guard let currentRoot else { return AnyView(EmptyView()) }
        return AnyView(PaneDetailRootView(root: currentRoot, state: self))
    }

    private var holdState: PaneHoldState {
        PaneHoldState(
            modalHoldCount: holdTokens.count,
            isRootCovered: isRootCovered,
            isHostVisible: isHostVisible
        )
    }

    func update(widthClass: WidthClass, hasDetail: Bool, willCollapse: @escaping () -> Void) {
        self.widthClass = widthClass
        self.hasDetail = hasDetail
        self.willCollapse = willCollapse
        recompute()
    }

    func setModalHold(_ token: UUID, active: Bool) {
        if active {
            holdTokens.insert(token)
        } else {
            holdTokens.remove(token)
        }
        recompute()
    }

    func rootPresenceDidChange() {
        isRootCovered = currentRoot.map { $0.hasAppeared && !lifecycle.isPresent($0) } ?? false
        recompute()
    }

    func hostVisibilityDidChange(_ visible: Bool) {
        isHostVisible = visible
        if !visible {
            lifecycle.flushPending()
        }
        recompute()
    }

    /// Called before `update` when the selection changes, so the outgoing root's
    /// pending disappear is settled and coverage from the old selection is cleared.
    func selectionDidChange() {
        lifecycle.flushPending()
        isRootCovered = false
    }

    /// Returns the retained root for `key`, building it once per selection. A `nil` key
    /// releases the current root.
    func root(for key: AnyHashable?, make: () -> AnyView = { AnyView(EmptyView()) }) -> RetainedPaneRoot? {
        guard let key else {
            currentRoot?.release()
            currentRoot = nil
            return nil
        }
        if let currentRoot, currentRoot.key == key, !currentRoot.isReleased {
            return currentRoot
        }
        currentRoot?.release()
        let root = RetainedPaneRoot(key: key, view: make())
        currentRoot = root
        return root
    }

    private func recompute() {
        let previous = arrangement
        let base = previous ?? .stack
        let next = PaneArrangement.next(
            from: base,
            widthClass: widthClass,
            hasDetail: hasDetail,
            isDetailHeld: holdState.isDetailHeld
        )
        guard next != previous else { return }
        if let previous, hasDetail, PaneArrangement.reparentsDetail(from: previous, to: next) {
            lifecycle.beginHandover()
        }
        if next == .stack, hasDetail, base != .stack {
            willCollapse()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            arrangement = next
        }
    }
}

/// Lets the host present a stack-mode detail through a `NavigationLink` owned by the list.
@MainActor
struct PaneStackLink {
    let isActive: Binding<Bool>
    let destination: AnyView
    let selectionID: AnyHashable?
}

/// Forwards a modal hold from a descendant to the host that owns the detail.
nonisolated struct PaneHoldSink: Sendable {
    let setHold: @MainActor @Sendable (UUID, Bool) -> Void
}

private struct PaneDetailRootView: View {
    let root: RetainedPaneRoot
    let state: PaneHostState

    var body: some View {
        root.view.paneLifecycle(
            owner: root,
            onAppear: {
                root.hasAppeared = true
                state.rootPresenceDidChange()
            },
            onDisappear: {
                state.rootPresenceDidChange()
            }
        )
    }
}

/// A list/detail surface that is one column on compact widths and two columns on wide
/// widths. The list is always the leading column; `navigator` owns the detail selection.
struct PaneHost<Selection: Hashable, ListRoot: View, Detail: View>: View {
    @ObservedObject private var navigator: PaneNavigator<Selection>
    @StateObject private var state = PaneHostState()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let placeholder: PanePlaceholder
    private let willCollapse: () -> Void
    private let listWidthRule: PaneListWidthRule
    private let list: () -> ListRoot
    private let detail: (Selection) -> Detail

    init(
        navigator: PaneNavigator<Selection>,
        placeholder: PanePlaceholder,
        listWidthRule: PaneListWidthRule,
        willCollapse: @escaping () -> Void = {},
        @ViewBuilder list: @escaping () -> ListRoot,
        detail: @escaping (Selection) -> Detail
    ) {
        _navigator = ObservedObject(wrappedValue: navigator)
        self.placeholder = placeholder
        self.willCollapse = willCollapse
        self.listWidthRule = listWidthRule
        self.list = list
        self.detail = detail
    }

    var body: some View {
        GeometryReader { proxy in
            layout(proxy)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .onDisappear {
            state.hostVisibilityDidChange(false)
        }
    }

    @ViewBuilder
    private func layout(_ proxy: GeometryProxy) -> some View {
        let insets = proxy.safeAreaInsets
        let arrangement = state.arrangement ?? .stack
        let frames = PaneMetrics.frames(
            for: arrangement,
            containerWidth: proxy.size.width,
            leadingInset: insets.leading,
            trailingInset: insets.trailing,
            listWidthRule: listWidthRule
        )
        let widthClass = WidthClass.make(
            size: CGSize(
                width: max(proxy.size.width - insets.leading - insets.trailing, 0),
                height: proxy.size.height
            ),
            verticallyRegular: verticalSizeClass == .regular
        )
        let selectionKey: AnyHashable? = navigator.selection.map { AnyHashable($0) }
        let root = retainedRoot()
        let stackLink = PaneStackLink(
            isActive: Binding(
                get: {
                    (state.arrangement ?? .stack) == .stack && navigator.selection != nil
                },
                set: { active in
                    if PaneStackLinkRule.clearsSelection(
                        whenSetActive: active,
                        arrangement: state.arrangement ?? .stack
                    ) {
                        navigator.clearSelection()
                    }
                }
            ),
            destination: state.stackLinkDestination,
            selectionID: selectionKey
        )

        ZStack(alignment: .topLeading) {
            NavigationView {
                list()
            }
            .navigationViewStyle(.stack)
            .frame(width: frames.listWidth)
            .opacity(arrangement == .detailOnly ? 0 : 1)
            .accessibilityHidden(arrangement == .detailOnly)
            .allowsHitTesting(arrangement != .detailOnly)
            .environment(\.paneArrangement, arrangement)
            .environment(\.paneShowsSelection, arrangement == .split)
            .environment(\.paneLifecycleRegistry, state.lifecycle)
            .environment(\.paneHoldSink, state.holdSink)
            .environment(\.paneStackLink, stackLink)

            if arrangement == .split {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: PaneMetrics.dividerWidth)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, frames.listWidth)
            }

            if arrangement != .stack {
                NavigationView {
                    if let root {
                        PaneDetailRootView(root: root, state: state)
                    } else {
                        placeholder
                    }
                }
                .navigationViewStyle(.stack)
                .id(selectionKey)
                .frame(width: frames.detailWidth)
                .background(Color(.systemBackground))
                .padding(.leading, frames.detailLeading)
                .environment(\.paneArrangement, arrangement)
                .environment(\.paneShowsSelection, arrangement == .split)
                .environment(\.paneLifecycleRegistry, state.lifecycle)
                .environment(\.paneHoldSink, state.holdSink)
            }
        }
        .onAppear {
            state.hostVisibilityDidChange(true)
            state.update(widthClass: widthClass, hasDetail: navigator.selection != nil, willCollapse: willCollapse)
        }
        .onChange(of: widthClass) { newValue in
            state.update(widthClass: newValue, hasDetail: navigator.selection != nil, willCollapse: willCollapse)
        }
        .onChange(of: navigator.selection) { _ in
            state.selectionDidChange()
            state.update(widthClass: widthClass, hasDetail: navigator.selection != nil, willCollapse: willCollapse)
        }
    }

    private func retainedRoot() -> RetainedPaneRoot? {
        guard let selection = navigator.selection else {
            return state.root(for: nil)
        }
        return state.root(for: AnyHashable(selection)) { AnyView(detail(selection)) }
    }
}

extension View {
    /// Pushes the list's detail link when the host is in stack arrangement. Attach it
    /// to the list that owns the selection.
    func paneDetailLink(isEnabled: Bool) -> some View {
        modifier(PaneDetailLinkModifier(isEnabled: isEnabled))
    }

    /// Reports that this view is presenting a modal that must keep the detail on screen.
    func paneHold(_ isPresenting: Bool) -> some View {
        modifier(PaneHoldModifier(isPresenting: isPresenting))
    }
}

private struct PaneDetailLinkModifier: ViewModifier {
    let isEnabled: Bool

    @Environment(\.paneStackLink) private var stackLink

    func body(content: Content) -> some View {
        if isEnabled, let stackLink {
            content.background {
                NavigationLink(isActive: stackLink.isActive, destination: { stackLink.destination }) {
                    EmptyView()
                }
                .id(stackLink.selectionID)
            }
        } else {
            content
        }
    }
}

private struct PaneHoldModifier: ViewModifier {
    let isPresenting: Bool

    @Environment(\.paneHoldSink) private var sink
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                sink.setHold(token, isPresenting)
            }
            .onChange(of: isPresenting) { newValue in
                sink.setHold(token, newValue)
            }
            .onDisappear {
                sink.setHold(token, false)
            }
    }
}

struct PanePlaceholder: View {
    let systemImage: String
    let title: Text
    let message: Text

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            message
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A list row that marks the selected detail when the list and detail share the screen.
struct PaneSelectionButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let label: () -> Label

    @Environment(\.paneShowsSelection) private var showsSelection

    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isSelected = isSelected
        self.action = action
        self.label = label
    }

    var body: some View {
        let marksSelection = isSelected && showsSelection
        // A light accent tint: the system fills barely show on a grouped list, least of all in dark mode.
        let rowBackground: Color? = marksSelection ? Color.accentColor.opacity(0.2) : nil
        let traits: AccessibilityTraits = marksSelection ? .isSelected : []
        Button(action: action) {
            HStack {
                label()
                Spacer(minLength: 0)
                if !showsSelection {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground)
        .accessibilityAddTraits(traits)
    }
}

private nonisolated struct PaneStackLinkKey: EnvironmentKey {
    static let defaultValue: PaneStackLink? = nil
}

private nonisolated struct PaneArrangementKey: EnvironmentKey {
    static let defaultValue: PaneArrangement = .stack
}

private nonisolated struct PaneShowsSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

private nonisolated struct PaneHoldSinkKey: EnvironmentKey {
    static let defaultValue = PaneHoldSink(setHold: { _, _ in })
}

private extension EnvironmentValues {
    var paneStackLink: PaneStackLink? {
        get { self[PaneStackLinkKey.self] }
        set { self[PaneStackLinkKey.self] = newValue }
    }

    var paneHoldSink: PaneHoldSink {
        get { self[PaneHoldSinkKey.self] }
        set { self[PaneHoldSinkKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var paneArrangement: PaneArrangement {
        get { self[PaneArrangementKey.self] }
        set { self[PaneArrangementKey.self] = newValue }
    }

    var paneShowsSelection: Bool {
        get { self[PaneShowsSelectionKey.self] }
        set { self[PaneShowsSelectionKey.self] = newValue }
    }
}
