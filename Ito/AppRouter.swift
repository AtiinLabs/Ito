import Combine
import Foundation

enum AppRootTab: Hashable, CaseIterable {
    case library
    case browse
    case discover
    case search
    case settings
}

struct RepositoryDeepLinkIntent: Identifiable, Equatable {
    let token: UUID
    let repositoryURL: URL

    var id: UUID { token }
}

enum RepositoryIntentDelivery: Equatable {
    case pending(RepositoryDeepLinkIntent)
    case claimed(RepositoryDeepLinkIntent)

    var intent: RepositoryDeepLinkIntent {
        switch self {
        case .pending(let intent), .claimed(let intent):
            return intent
        }
    }
}

@MainActor
protocol BrowseRepositoryIntentRouting: AnyObject {
    var repositoryIntentPublisher: AnyPublisher<Void, Never> { get }

    func claimPendingRepositoryIntent() -> RepositoryDeepLinkIntent?
    func acknowledgeRepositoryIntent(token: UUID)
}

@MainActor
protocol LibraryTabRouting: AnyObject {
    func showDiscover()
}

@MainActor
final class AppRouter: ObservableObject, BrowseRepositoryIntentRouting, LibraryTabRouting {
    @Published var selectedTab: AppRootTab = .library
    @Published private(set) var repositoryIntentDelivery: RepositoryIntentDelivery?
    @Published private var repositoryIntentRevision = 0

    private var repositoryIntents: [RepositoryDeepLinkIntent] = []
    private var claimedToken: UUID?

    var repositoryIntentPublisher: AnyPublisher<Void, Never> {
        $repositoryIntentRevision
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func showDiscover() {
        selectedTab = .discover
    }

    @discardableResult
    func handleRepositoryDeepLink(_ url: URL) -> Bool {
        guard let repositoryURL = Self.repositoryURL(from: url) else { return false }

        selectedTab = .browse

        guard !repositoryIntents.contains(where: { $0.repositoryURL == repositoryURL }) else {
            return true
        }

        repositoryIntents.append(
            RepositoryDeepLinkIntent(token: UUID(), repositoryURL: repositoryURL)
        )
        updateDelivery()
        repositoryIntentRevision += 1
        return true
    }

    func claimPendingRepositoryIntent() -> RepositoryDeepLinkIntent? {
        guard claimedToken == nil, let intent = repositoryIntents.first else { return nil }

        claimedToken = intent.token
        repositoryIntentDelivery = .claimed(intent)
        return intent
    }

    func acknowledgeRepositoryIntent(token: UUID) {
        guard claimedToken == token, repositoryIntents.first?.token == token else { return }

        repositoryIntents.removeFirst()
        claimedToken = nil
        updateDelivery()
        if !repositoryIntents.isEmpty {
            repositoryIntentRevision += 1
        }
    }

    private func updateDelivery() {
        guard let intent = repositoryIntents.first else {
            repositoryIntentDelivery = nil
            return
        }
        repositoryIntentDelivery = claimedToken == intent.token ? .claimed(intent) : .pending(intent)
    }

    private static func repositoryURL(from deepLink: URL) -> URL? {
        guard deepLink.scheme?.lowercased() == "ito",
              deepLink.host?.lowercased() == "repo",
              deepLink.path == "/add",
              let components = URLComponents(url: deepLink, resolvingAgainstBaseURL: false),
              let rawRepositoryURL = components.queryItems?
                .first(where: { $0.name == "url" })?
                .value,
              let repositoryURL = URL(string: rawRepositoryURL),
              let scheme = repositoryURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              repositoryURL.host != nil else {
            return nil
        }
        return repositoryURL
    }
}
