import SwiftUI

enum SettingsDestination: CaseIterable {
    case appearance
    case library
    case privacy
    case trackers
    case backup
    case readerUnavailable
    case storage
    case networkUnavailable
    case extensionsUnavailable
    case debugLogs
}

struct SettingsView: View {
    let viewFactory: AppViewFactory

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("General")) {
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .appearance)) {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .library)) {
                        Label("Library", systemImage: "books.vertical")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .privacy)) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .readerUnavailable)) {
                        Label("Reader", systemImage: "book")
                    }
                }

                Section(header: Text("Data")) {
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .storage)) {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .networkUnavailable)) {
                        Label("Network", systemImage: "wifi")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .trackers)) {
                        Label("Trackers", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .backup)) {
                        Label("Backup & Restore", systemImage: "arrow.triangle.2.circlepath.doc")
                    }
                }

                Section(header: Text("Extensions")) {
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .extensionsUnavailable)) {
                        Label("Browse Installers", systemImage: "puzzlepiece.extension")
                    }
                }

                Section(header: Text("Developer")) {
                    NavigationLink(destination: viewFactory.makeSettingsDestination(for: .debugLogs)) {
                        Label("Debug Logs", systemImage: "ladybug")
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(AppVersion.marketing) (\(AppVersion.build))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}
