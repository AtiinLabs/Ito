import SwiftUI

/// Tracks which detail roots are on screen so a re-parented detail is not reported as
/// disappeared. SwiftUI runs the old root's `onDisappear` and the new root's `onAppear`
/// in an unspecified order during a re-parent, so the registry reconciles both.
@MainActor
final class PaneLifecycleRegistry {
    private final class Entry {
        weak var owner: AnyObject?
        var tokens: Set<UUID> = []
        var appeared = false
        var pending = false
        var onDisappear: () -> Void = {}

        init(owner: AnyObject) {
            self.owner = owner
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Marks every live root as pending so the next uninstall does not report disappear.
    /// The new arrangement's install then reclaims the root without a spurious appear.
    func beginHandover() {
        for entry in entries.values where entry.appeared {
            entry.pending = true
        }
    }

    /// Reports disappear for roots left pending without a reinstall.
    func flushPending() {
        for (key, entry) in entries.filter({ $0.value.pending && $0.value.tokens.isEmpty }) {
            entries[key] = nil
            if entry.appeared {
                entry.appeared = false
                entry.onDisappear()
            }
        }
    }

    func isPresent(_ owner: AnyObject) -> Bool {
        guard let entry = entry(for: owner) else { return false }
        return !entry.tokens.isEmpty || entry.pending
    }

    func install(
        owner: AnyObject,
        token: UUID,
        onAppear: () -> Void,
        onDisappear: @escaping () -> Void
    ) {
        let entry = entry(for: owner) ?? makeEntry(owner: owner)
        entry.tokens.insert(token)
        entry.pending = false
        entry.onDisappear = onDisappear
        if !entry.appeared {
            entry.appeared = true
            onAppear()
        }
    }

    func uninstall(owner: AnyObject, token: UUID) {
        guard let entry = entry(for: owner) else { return }
        entry.tokens.remove(token)
        guard entry.tokens.isEmpty, !entry.pending else { return }
        entries[ObjectIdentifier(owner)] = nil
        if entry.appeared {
            entry.appeared = false
            entry.onDisappear()
        }
    }

    private func entry(for owner: AnyObject) -> Entry? {
        guard let entry = entries[ObjectIdentifier(owner)], entry.owner === owner else {
            return nil
        }
        return entry
    }

    private func makeEntry(owner: AnyObject) -> Entry {
        let entry = Entry(owner: owner)
        entries[ObjectIdentifier(owner)] = entry
        return entry
    }
}

private nonisolated struct PaneLifecycleRegistryKey: EnvironmentKey {
    static let defaultValue: PaneLifecycleRegistry? = nil
}

extension EnvironmentValues {
    var paneLifecycleRegistry: PaneLifecycleRegistry? {
        get { self[PaneLifecycleRegistryKey.self] }
        set { self[PaneLifecycleRegistryKey.self] = newValue }
    }
}

extension View {
    /// Reports appear and disappear for `owner` through the pane registry when one is
    /// installed, and directly otherwise.
    func paneLifecycle(
        owner: AnyObject,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void
    ) -> some View {
        modifier(PaneLifecycleModifier(owner: owner, onAppear: onAppear, onDisappear: onDisappear))
    }
}

private struct PaneLifecycleModifier: ViewModifier {
    let owner: AnyObject
    let onAppear: () -> Void
    let onDisappear: () -> Void

    @Environment(\.paneLifecycleRegistry) private var registry
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if let registry {
            content
                .onAppear {
                    registry.install(owner: owner, token: token, onAppear: onAppear, onDisappear: onDisappear)
                }
                .onDisappear {
                    registry.uninstall(owner: owner, token: token)
                }
        } else {
            content
                .onAppear(perform: onAppear)
                .onDisappear(perform: onDisappear)
        }
    }
}
