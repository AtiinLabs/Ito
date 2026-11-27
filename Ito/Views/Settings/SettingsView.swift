import SwiftUI

enum SettingsDestination: CaseIterable, Hashable {
    case appearance
    case library
    case privacy
    case trackers
    case backup
    case storage
    case network
    case debugLogs
}

private enum CommunityLink {
    static let discord = URL(string: "https://discord.gg/kewAMeJypQ")!
    static let newGitHubIssue = URL(string: "https://github.com/AtiinLabs/Ito/issues/new")!
}

struct SettingsView: View {
    let viewFactory: AppViewFactory
    @ObservedObject var navigator: PaneNavigator<SettingsDestination>

    var body: some View {
        PaneHost(
            navigator: navigator,
            placeholder: PanePlaceholder(
                systemImage: "gearshape",
                title: Text("No Setting Selected", comment: "Title shown in the Settings detail column when no category is selected"),
                message: Text("Choose a category.", comment: "Message shown in the Settings detail column when no category is selected")
            ),
            list: { settingsList },
            detail: { viewFactory.makeSettingsDestination(for: $0) }
        )
    }

    private var settingsList: some View {
        List {
            Section(header: Text("General")) {
                categoryRow(.appearance, title: "Appearance", systemImage: "paintpalette")
                categoryRow(.library, title: "Library", systemImage: "books.vertical")
                categoryRow(.privacy, title: "Privacy", systemImage: "hand.raised")
            }

            Section(header: Text("Data")) {
                categoryRow(.storage, title: "Storage", systemImage: "internaldrive")
                categoryRow(.network, title: "Network", systemImage: "wifi")
                categoryRow(.trackers, title: "Trackers", systemImage: "arrow.triangle.2.circlepath")
                categoryRow(.backup, title: "Backup & Restore", systemImage: "externaldrive.badge.timemachine")
            }

            Section(header: Text("Developer")) {
                categoryRow(.debugLogs, title: "Debug Logs", systemImage: "ladybug")
            }

            Section(header: Text("Community")) {
                Link(destination: CommunityLink.discord) {
                    Label("Join the Ito Discord", systemImage: "bubble.left.and.bubble.right")
                }
                Menu {
                    Link(destination: CommunityLink.discord) {
                        Label("Ask on Discord", systemImage: "bubble.left.and.bubble.right")
                    }
                    Link(destination: CommunityLink.newGitHubIssue) {
                        Label("Report on GitHub", systemImage: "exclamationmark.bubble")
                    }
                } label: {
                    Label("Get Help or Report a Bug", systemImage: "questionmark.circle")
                }
            }

            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(verbatim: "\(AppVersion.marketing) (\(AppVersion.build))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .paneDetailLink(isEnabled: true)
    }

    private func categoryRow(_ destination: SettingsDestination, title: LocalizedStringKey, systemImage: String) -> some View {
        PaneSelectionButton(
            isSelected: navigator.selection == destination,
            action: { navigator.select(destination) }
        ) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}
