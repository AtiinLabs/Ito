import ito_runner

/// User overrides only; defaults and visibility remain the runner's responsibility.
@MainActor
final class SourceSearchFilters {
    private enum Scope: Hashable {
        case all
        case kind(MediaKind)
        init(_ kind: MediaKind?) { self = kind.map(Self.kind) ?? .all }
    }
    private var capabilitiesByKind: [Scope: SearchCapabilities] = [:]
    private var valuesByKind: [Scope: [String: ControlValue]] = [:]

    func capabilities(for kind: MediaKind?) -> SearchCapabilities? {
        capabilitiesByKind[Scope(kind)]
    }

    func values(for kind: MediaKind?) -> [String: ControlValue] {
        valuesByKind[Scope(kind)] ?? [:]
    }

    func setValue(_ value: ControlValue, for control: Control, kind: MediaKind?) {
        guard control.kind.accepts(value) else { return }
        valuesByKind[Scope(kind), default: [:]][control.id] = value
    }

    func apply(_ values: [String: ControlValue], kind: MediaKind?) {
        let controls = capabilities(for: kind)?.controls ?? []
        valuesByKind[Scope(kind)] = values.filter { id, value in
            controls.first(where: { $0.id == id })?.kind.accepts(value) == true
        }
    }

    func clear(kind: MediaKind?) {
        valuesByKind[Scope(kind)] = [:]
    }

    func updateCapabilities(_ capabilities: SearchCapabilities?, kind: MediaKind?) {
        capabilitiesByKind[Scope(kind)] = capabilities
        // Reconcile the latest user edits, never a snapshot captured before an async request.
        apply(values(for: kind), kind: kind)
    }
}
