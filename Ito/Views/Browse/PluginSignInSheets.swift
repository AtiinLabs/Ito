import Foundation
import ito_runner

/// The sign-in a source's screens may offer: the source's website, and the sheet that signs in there with the
/// source's own cookie jar. In an app scope with no cookie jar nothing is offered (`unavailable`).
@MainActor
struct PluginSignInSheets {
    private let pluginCookies: PluginCookieJar?
    private let installedPlugin: (String) -> InstalledPlugin?
    private let evictRunner: @MainActor (String) -> Void

    init(
        pluginCookies: PluginCookieJar?,
        installedPlugin: @escaping (String) -> InstalledPlugin?,
        evictRunner: @escaping @MainActor (String) -> Void
    ) {
        self.pluginCookies = pluginCookies
        self.installedPlugin = installedPlugin
        self.evictRunner = evictRunner
    }

    /// No source offers sign-in: the scope has no cookie jar.
    static var unavailable: PluginSignInSheets {
        PluginSignInSheets(pluginCookies: nil, installedPlugin: { _ in nil }, evictRunner: { _ in })
    }

    /// The source's website for signing in, or nil when it has none or sign-in isn't available.
    func target(pluginID: String) -> PluginSignInTarget? {
        guard pluginCookies != nil, let plugin = installedPlugin(pluginID) else { return nil }
        return PluginSignInTarget(pluginID: plugin.id, pluginName: plugin.info.name, siteURL: plugin.info.url)
    }

    /// The sign-in sheet for `target`; nil when sign-in isn't available in this app scope.
    func sheet(for target: PluginSignInTarget) -> PluginSignInSheet? {
        guard let pluginCookies else { return nil }
        return PluginSignInSheet(viewModel: PluginSignInViewModel(
            target: target,
            cookieJar: pluginCookies,
            evictRunner: evictRunner
        ))
    }
}
