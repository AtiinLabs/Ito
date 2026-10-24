import Combine
import Foundation

/// A source the user can sign in to: its website from the manifest, which must be an http(s)
/// address with a host. Sources without one offer no sign-in.
nonisolated struct PluginSignInTarget: Identifiable, Equatable, Sendable {
    let pluginID: String
    let pluginName: String
    let siteURL: URL

    var id: String { pluginID }

    init?(pluginID: String, pluginName: String, siteURL: String?) {
        guard let siteURL,
              let url = URL(string: siteURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.siteURL = url
    }

    /// Whether a cookie set while signing in belongs to this source's site: the site's host, a
    /// subdomain of it, or a parent domain of it with at least two labels (as `www.` sites set).
    /// A bare top-level domain such as `.com` never belongs to a site.
    func owns(cookieDomain: String) -> Bool {
        guard let host = Self.normalized(siteURL.host),
              let domain = Self.normalized(cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain)
        else { return false }
        if domain == host || domain.hasSuffix("." + host) { return true }
        return domain.contains(".") && host.hasSuffix("." + domain)
    }

    private static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

/// Keeps the cookies a sign-in left for one source and reloads that source.
@MainActor
final class PluginSignInViewModel: ObservableObject {
    static let saveFailureMessage = "The sign-in couldn't be saved. Try again."

    let target: PluginSignInTarget
    @Published private(set) var errorMessage: String?

    private let cookieJar: PluginCookieJar
    private let evictRunner: @MainActor (String) -> Void

    init(target: PluginSignInTarget, cookieJar: PluginCookieJar, evictRunner: @escaping @MainActor (String) -> Void) {
        self.target = target
        self.cookieJar = cookieJar
        self.evictRunner = evictRunner
    }

    /// The source's stored cookies, so the sign-in page opens with the current session.
    func existingCookies() -> [HTTPCookie] {
        cookieJar.cookies(pluginID: target.pluginID, for: target.siteURL)
    }

    /// Saves the site's cookies from the sign-in page. Returns false, with `errorMessage` set, when
    /// they couldn't be saved; the sheet then stays open.
    func finish(with cookies: [HTTPCookie]) -> Bool {
        let siteCookies = cookies.filter { target.owns(cookieDomain: $0.domain) }
        do {
            try cookieJar.store(siteCookies, pluginID: target.pluginID)
        } catch {
            errorMessage = Self.saveFailureMessage
            return false
        }
        errorMessage = nil
        evictRunner(target.pluginID)
        return true
    }
}
