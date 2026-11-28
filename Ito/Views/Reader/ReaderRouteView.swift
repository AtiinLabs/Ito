import SwiftUI
import ito_runner

extension ReaderRoutePresentation: Identifiable {
    var id: UUID { visitID }
}

/// The one reader screen of an opening. It shows whichever reader the route has chosen, and keeps the same
/// screen and navigation entry when the chapter after the current one is made for the other reader: the
/// destination is built behind the visible reader and replaces it only once it can be shown.
struct ReaderRouteView: View {
    @StateObject private var coordinator: ReaderRouteCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// Offers Sign In when a chapter's load needs the source's website; see `ReaderView`.
    private let pluginID: String
    private let signIn: PluginSignInSheets
    @State private var showHandoffSignIn = false
    /// The failed hand-off the sign-in sheet was opened for; closing the sheet tries it again.
    @State private var handoffSignInRequestID: UUID?

    /// `coordinator` is evaluated once, when SwiftUI first creates this view's state.
    init(coordinator: @autoclosure @escaping () -> ReaderRouteCoordinator, pluginID: String, signIn: PluginSignInSheets) {
        _coordinator = StateObject(wrappedValue: coordinator())
        self.pluginID = pluginID
        self.signIn = signIn
    }

    var body: some View {
        ZStack {
            // The staged reader sits underneath, and is replaced by identity: its views and model are the
            // ones that were built, never recreated at the swap.
            ForEach(visits) { visit in
                renderer(visit)
            }
            handoffStatus
        }
        .onDisappear { coordinator.close() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { coordinator.sceneDidLeaveActive() }
        }
        // Progress turning into a failure is announced: nothing the user is touching changes focus.
        .onChange(of: failedRequestID) { id in
            guard id != nil, case .failed(let request, let failure) = coordinator.phase else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: message(for: failure, request: request)
            )
        }
        .alert(
            String(localized: "Switch groups?", comment: "Reader consent title: open one exact upload from another translation group"),
            // The buttons decide: a setter that cancelled could run before Continue's action.
            isPresented: Binding(get: { consent != nil }, set: { _ in }),
            presenting: consent
        ) { consent in
            Button(String(localized: "Open This Upload", comment: "Reader consent alert button: opens the one upload from another translation group, for this reading only")) {
                coordinator.confirmHandoff(consentID: consent.id)
            }
            Button("Cancel", role: .cancel) { coordinator.cancelHandoff() }
        } message: { consent in
            Text(consent.message)
        }
        .sheet(isPresented: $showHandoffSignIn, onDismiss: {
            if let requestID = handoffSignInRequestID { coordinator.retryHandoff(requestID: requestID) }
        }) {
            if let target = signIn.target(pluginID: pluginID) {
                signIn.sheet(for: target)
            }
        }
    }

    private var consent: ReaderGroupSwitchConsent<Chapter>? {
        if case .awaitingConsent(_, let consent) = coordinator.phase { return consent }
        return nil
    }

    private var failedRequestID: UUID? {
        if case .failed(let request, _) = coordinator.phase { return request.id }
        return nil
    }

    /// Staged reader first, so the visible one is drawn over it.
    private var visits: [ReaderRoutePresentation] {
        var list: [ReaderRoutePresentation] = []
        if case .staging(_, let staged) = coordinator.phase { list.append(staged) }
        if let active = coordinator.active { list.append(active) }
        return list
    }

    @ViewBuilder
    private func renderer(_ visit: ReaderRoutePresentation) -> some View {
        let isStaged = visit.visitID != coordinator.active?.visitID
        let busy = coordinator.phase.isBusy
        Group {
            switch visit {
            case .pages(_, let model):
                ReaderView(
                    viewModel: model,
                    isHandoffBusy: busy,
                    onPresentationReady: coordinator.presentationReady,
                    onInitialImageVisibleLeaseAcquired: coordinator.initialImageVisibleLeaseAcquired,
                    signIn: signIn
                )
            case .text(_, let model):
                NovelReaderView(
                    viewModel: model,
                    onPresentationReady: coordinator.presentationReady,
                    onPresentationFailed: coordinator.presentationFailed,
                    onInitialImageVisibleLeaseAcquired: coordinator.initialImageVisibleLeaseAcquired,
                    signIn: signIn
                )
            }
        }
        // The visible reader waits while a handoff is pending, and the one behind it is not for the user yet.
        // Neither is reachable by touch or by VoiceOver: the status below is what is actionable.
        .allowsHitTesting(!isStaged && !busy)
        .accessibilityHidden(isStaged || busy)
    }

    // MARK: - Handoff status

    @ViewBuilder
    private var handoffStatus: some View {
        switch coordinator.phase {
        case .preparing(let request), .staging(let request, _):
            statusCard {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(progressMessage(for: request))
                }
                Button("Cancel") { coordinator.cancelHandoff() }
            }
        case .failed(let request, let failure):
            statusCard {
                Text(message(for: failure, request: request))
                HStack(spacing: 16) {
                    if failure == .needsSignIn, signIn.target(pluginID: pluginID) != nil {
                        Button("Sign In") {
                            handoffSignInRequestID = request.id
                            showHandoffSignIn = true
                        }
                    }
                    Button("Try Again") { coordinator.retryHandoff(requestID: request.id) }
                    Button("Cancel") { coordinator.cancelHandoff() }
                }
            }
        case .opening, .idle, .awaitingConsent, .closed:
            EmptyView()
        }
    }

    /// Stacked and allowed to wrap, so large text sizes grow the card instead of cutting its words.
    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                content()
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .accessibilityElement(children: .contain)
    }

    /// The status while a handoff is being prepared or staged: the chosen chapter's name, or the neighbor's direction.
    private func progressMessage(for request: ReaderHandoffRequest) -> String {
        switch request.event.target {
        case .chosen:
            ReaderJumpStatusText.opening(request.chapter)
        case .adjacent:
            request.event.direction == .next
                ? String(localized: "Opening the next chapter…", comment: "Reader: shown over the current chapter while the next one, made for the other reader, is being prepared")
                : String(localized: "Opening the previous chapter…", comment: "Reader: shown over the current chapter while the previous one, made for the other reader, is being prepared")
        }
    }

    private func message(for failure: ReaderHandoffFailure, request: ReaderHandoffRequest) -> String {
        switch failure {
        case .unavailableOffline:
            OfflineReadError.notDownloaded.errorDescription ?? ""
        case .protectedDataUnavailable:
            OfflineReadError.protectedDataUnavailable.errorDescription ?? ""
        case .localCopyUnavailable:
            OfflineReadError.localCopyUnavailable.errorDescription ?? ""
        case .needsSignIn:
            String(localized: "Sign in to this source to continue.")
        case .loadFailed, .presentationFailed:
            switch request.event.target {
            case .chosen:
                ReaderJumpStatusText.failed(request.chapter)
            case .adjacent:
                request.event.direction == .next
                    ? String(localized: "Couldn't open the next chapter.", comment: "Reader: the next chapter, made for the other reader, could not be opened; the current chapter stays")
                    : String(localized: "Couldn't open the previous chapter.", comment: "Reader: the previous chapter, made for the other reader, could not be opened; the current chapter stays")
            }
        }
    }
}
