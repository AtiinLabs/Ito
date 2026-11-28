import SwiftUI
import Nuke
import NukeUI
import ito_runner

/// A button on a deferred series' failure screen. Its title is a fixed localized key.
private struct DeferredFailureAction {
    let title: LocalizedStringKey
    let perform: () -> Void
}

struct DeferredPluginView: View {
    @Environment(\.sourceCoverRequests) private var coverRequests
    @StateObject private var session: DeferredPluginSession
    let viewFactory: AppViewFactory

    private var viewModel: DeferredPluginViewModel { session.viewModel }

    /// The session is built on first mount; SwiftUI keeps that one session for the view's identity.
    init(session: @autoclosure @escaping () -> DeferredPluginSession, viewFactory: AppViewFactory) {
        _session = StateObject(wrappedValue: session())
        self.viewFactory = viewFactory
    }

    var body: some View {
        content.paneLifecycle(
            owner: viewModel,
            onAppear: { viewModel.appear() },
            onDisappear: { viewModel.disappear() }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .decoding, .loadingRunner, .loadingSavedDetails, .cancelled:
            loadingView(label: "Loading…")
        case .checkingPackage:
            loadingView(label: "Searching repositories…")
        case .installing:
            loadingView(label: "Installing extension…")
        case .pluginMissing:
            missingPluginView
        case .packageUnavailable:
            failureView(
                title: "Extension Not Found",
                message: Text("This extension was not found in your configured repositories."),
                actions: [DeferredFailureAction(title: "Search Again", perform: viewModel.installMissingPlugin)]
            )
        case .incompatible(let incompatibility):
            // Both actions run the lookup again, which refreshes every repository first, so a newer build can appear.
            failureView(
                title: "Extension Incompatible",
                message: Self.incompatibilityMessage(incompatibility),
                actions: [
                    DeferredFailureAction(title: "Refresh Sources", perform: viewModel.installMissingPlugin),
                    DeferredFailureAction(title: "Retry", perform: viewModel.installMissingPlugin)
                ]
            )
        case .failure(let failure):
            deferredFailureView(failure)
        case .ready(let route):
            session.destination(for: route.id) {
                AnyView(viewFactory.makeDeferredPluginDestination(route.destination, openIntent: route.openIntent).id(route.id))
            }
        }
    }

    private func loadingView(label: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingPluginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("Extension Required")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(
                    "To read this content, you must install the '\(viewModel.item.pluginId)' extension."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            Button(action: viewModel.installMissingPlugin) {
                Text("Search Repositories & Install")
                    .font(.headline)
                    .foregroundColor(.itoOnAccent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.top, 10)
            if viewModel.canOpenSavedDetails {
                Button(action: viewModel.openSavedDetails) {
                    Text(
                        "Open Saved Details",
                        comment: "Button on a library series whose source is unavailable: shows the details saved in the library."
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The buttons for an installed source that failed to load. A source built for an older ABI, or a damaged file, is
    /// replaced by a compatible build from a repository, so that build is offered before a plain retry.
    private var runnerLoadActions: [DeferredFailureAction] {
        var actions: [DeferredFailureAction] = []
        if viewModel.runnerRefusal?.needsSourceUpdate == true {
            actions.append(DeferredFailureAction(title: "Update Source", perform: viewModel.installMissingPlugin))
        }
        actions.append(DeferredFailureAction(title: "Retry", perform: viewModel.retry))
        return actions
    }

    @ViewBuilder
    private func deferredFailureView(_ failure: DeferredPluginFailure) -> some View {
        switch failure {
        case .packageLookup:
            failureView(
                title: "Repository Search Failed",
                message: Text("The configured repositories could not be refreshed. Please try again."),
                actions: [DeferredFailureAction(title: "Search Again", perform: viewModel.installMissingPlugin)]
            )
        case .pluginTypeMismatch:
            failureView(
                title: "Extension Type Mismatch",
                message: Text("The saved item and extension types do not match."),
                actions: [DeferredFailureAction(title: "Retry", perform: viewModel.retry)]
            )
        case .install:
            failureView(
                title: "Installation Failed",
                message: viewModel.installRefusal.map { Text(verbatim: $0.message) }
                    ?? Text("The extension could not be installed. Please try again."),
                actions: [DeferredFailureAction(title: "Retry Install", perform: viewModel.installMissingPlugin)]
            )
        case .runnerLoad:
            failureView(
                title: "Couldn't Load Plugin",
                message: viewModel.runnerRefusal.map { Text(verbatim: $0.message) }
                    ?? Text("The installed extension could not be loaded."),
                actions: runnerLoadActions
            )
        case .payloadDecode:
            failureView(
                title: "Couldn't Load Saved Item",
                message: Text("The saved media data is invalid or incompatible."),
                actions: [DeferredFailureAction(title: "Retry", perform: viewModel.retry)],
                savedFields: viewModel.savedFieldsFallback
            )
        }
    }

    /// The explanation on a saved series' screen when its source is refused by the repositories' feed. Text that is
    /// already localized is passed verbatim, so it is never looked up again as a key.
    private static func incompatibilityMessage(_ incompatibility: PluginIncompatibility) -> Text {
        switch incompatibility {
        case .requiresNewerApp(let minimumVersion?):
            return Text("This extension requires Ito \(minimumVersion) or later.")
        case .requiresNewerApp(nil):
            return Text("This extension requires a newer version of Ito.")
        case .requiresSourceUpdate:
            // Reached only from the feed lookup, which checks every repository for a compatible build first.
            return Text(verbatim: String(
                localized: "No compatible source update is available yet.",
                comment: "Shown where a source was built for an older version of Ito and no repository offers a compatible version: a source package's status label, and a saved series' failure message. The source's publisher must release an update."
            ))
        case .unsupportedFile:
            return Text(verbatim: incompatibility.message)
        }
    }

    private func failureView(
        title: LocalizedStringKey,
        message: Text,
        actions: [DeferredFailureAction] = [],
        savedFields: DeferredSavedFields? = nil
    ) -> some View {
        // Scrolls, so Retry stays reachable at accessibility text sizes; short content stays centered.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if let savedFields {
                        savedFieldsHeader(savedFields)
                    }
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 42, weight: .thin))
                        .foregroundStyle(.red)
                    Text(title).font(.headline)
                    message
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].title, action: actions[index].perform)
                            .itoProminentButtonStyle()
                    }
                    if viewModel.canOpenSavedDetails {
                        Button(action: viewModel.openSavedDetails) {
                            Text(
                                "Open Saved Details",
                                comment: "Button on a library series whose source is unavailable: shows the details saved in the library."
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    /// The series the Library row still names, with the cover it saved: the cover from the network cache, or
    /// the one this device kept while that is loading or failed.
    private func savedFieldsHeader(_ savedFields: DeferredSavedFields) -> some View {
        VStack(spacing: 8) {
            savedCover(savedFields)
                .frame(width: 96, height: 144)
                .cornerRadius(8)
                .clipped()
                .accessibilityHidden(true)
            Text(verbatim: savedFields.title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func savedCover(_ savedFields: DeferredSavedFields) -> some View {
        let loadKey = "\(viewModel.item.id)\u{1F}\(viewModel.item.coverUrl ?? "")"
        if let url = savedFields.coverURL {
            LazyImage(request: coverRequests.request(url, pluginID: viewModel.item.pluginId)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    DurableCoverFallback(
                        loadKey: loadKey, load: viewModel.savedCover, width: 96,
                        saturation: 1, failed: state.error != nil
                    ) { _ in Color.itoCardBackground }
                }
            }
        } else {
            DurableCoverFallback(
                loadKey: loadKey, load: viewModel.savedCover, width: 96,
                saturation: 1, failed: false
            ) { _ in Color.itoCardBackground }
        }
    }
}
