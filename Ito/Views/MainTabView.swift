import SwiftUI

struct MainTabView: View {
    let appScope: AppScope

    var body: some View {
        MainTabContentView(
            appScope: appScope,
            router: appScope.router,
            messageCenter: appScope.messageCenter
        )
    }
}

private struct MainTabContentView: View {
    let appScope: AppScope
    @ObservedObject var router: AppRouter
    @ObservedObject var messageCenter: AppMessageCenter

    var body: some View {
        ZStack {
            TabView(selection: $router.selectedTab) {
                appScope.viewFactory.makeLibraryView()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .tag(AppRootTab.library)

                appScope.viewFactory.makeBrowseView()
                    .tabItem {
                        Label("Browse", systemImage: "globe")
                    }
                    .tag(AppRootTab.browse)

                appScope.viewFactory.makeDiscoverView()
                    .tabItem {
                        Label("Discover", systemImage: "sparkles")
                    }
                    .tag(AppRootTab.discover)

                appScope.viewFactory.makeSearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .tag(AppRootTab.search)

                appScope.viewFactory.makeSettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(AppRootTab.settings)
            }

            VStack {
                Spacer()
                SnackBarOverlay(
                    messageCenter: messageCenter,
                    categoryHistoryViewFactory: appScope.viewFactory.categoryHistoryViewFactory
                )
            }

            #if DEBUG
            if UITestLaunchConfiguration.current.repositoryDeepLinkEnabled {
                VStack {
                    Button("Redeliver Repository Deep Link") {
                        UITestLaunchFixtureCoordinator.shared
                            .redeliverRepositoryDeepLink(using: router)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("redeliver-repository-deep-link")
                    Spacer()
                }
                .padding(.top, 8)
            }
            if UITestLaunchConfiguration.current.mangaReaderEnabled {
                UITestMangaReaderFixtureButton(dependencies: appScope.dependencies.mangaReader)
            }
            #endif
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        Text("MainTabView requires a prepared runtime")
    }
}
