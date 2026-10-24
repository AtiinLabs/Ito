import Foundation
import Security

/// Website cookies of each plugin: what a source's site set on its responses and what the user's
/// sign-in left behind. Kept in the Keychain, one item per plugin, so one source never sees
/// another's session and backups never carry them. Cookie names and values are never logged.
nonisolated public final class PluginCookieJar: @unchecked Sendable {
    public static let productionService = "moe.itoapp.ito.plugin-cookies"

    private let keychain: any PluginSecretKeychain
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Stored cookies by plugin id; each plugin's item is read from the Keychain once.
    private var cache: [String: [StoredCookie]] = [:]

    public init(
        keychain: any PluginSecretKeychain = SystemPluginSecretKeychain(service: PluginCookieJar.productionService),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.now = now
    }

    /// Cookies of `pluginID` that a browser would send to `url`: unexpired, on the url's host or a
    /// parent domain of it, on a path prefix of it, and secure ones over https only.
    public func cookies(pluginID: String, for url: URL) -> [HTTPCookie] {
        guard let host = Self.normalizedHost(url.host) else { return [] }
        let isSecure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let date = now()
        lock.lock()
        defer { lock.unlock() }
        return load(pluginID).filter { cookie in
            (cookie.expires.map { $0 > date } ?? true)
                && Self.domain(cookie.domain, matches: host)
                && Self.path(cookie.path, matches: path)
                && (!cookie.secure || isSecure)
        }.compactMap(\.httpCookie)
    }

    /// Adds or replaces cookies by name, domain and path; an already expired cookie removes the
    /// stored one, as a site does to sign out.
    public func store(_ cookies: [HTTPCookie], pluginID: String) throws {
        guard !cookies.isEmpty else { return }
        let date = now()
        lock.lock()
        defer { lock.unlock() }
        let previous = load(pluginID)
        var stored = previous
        for cookie in cookies {
            let incoming = StoredCookie(cookie)
            stored.removeAll { $0.identity == incoming.identity }
            if incoming.expires.map({ $0 > date }) ?? true {
                stored.append(incoming)
            }
        }
        stored.removeAll { $0.expires.map { $0 <= date } ?? false }
        // Sites that resend the same cookie on every response cost no Keychain write.
        guard Set(stored) != Set(previous) else { return }
        let status: OSStatus
        if stored.isEmpty {
            status = keychain.delete(account: pluginID)
        } else {
            status = keychain.setData(try JSONEncoder().encode(stored), account: pluginID)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            cache.removeValue(forKey: pluginID)
            throw PluginSecretStoreError(status: status)
        }
        cache[pluginID] = stored
    }

    /// Removes one plugin's cookies, for example when the user deletes the plugin.
    public func removeAll(pluginID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = keychain.delete(account: pluginID)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            cache.removeValue(forKey: pluginID)
            throw PluginSecretStoreError(status: status)
        }
        cache[pluginID] = []
    }

    /// Removes every plugin's cookies.
    public func removeEveryPlugin() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = keychain.deleteAll()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            cache.removeAll()
            throw PluginSecretStoreError(status: status)
        }
        cache.removeAll()
    }

    /// Callers hold `lock`. A locked Keychain (background launch) reads as no cookies and is not
    /// cached, so the next request reads it again.
    private func load(_ pluginID: String) -> [StoredCookie] {
        if let cached = cache[pluginID] { return cached }
        let (status, data) = keychain.data(account: pluginID)
        switch status {
        case errSecSuccess:
            let stored = data.flatMap { try? JSONDecoder().decode([StoredCookie].self, from: $0) } ?? []
            cache[pluginID] = stored
            return stored
        case errSecItemNotFound:
            cache[pluginID] = []
            return []
        default:
            return []
        }
    }

    /// True when a cookie for `domain` may be sent to `host`. A domain cookie (`.example.com`)
    /// goes to that host and its subdomains; a host-only cookie (`example.com`, set without a
    /// Domain attribute) goes to that exact host only.
    static func domain(_ domain: String, matches host: String) -> Bool {
        let isDomainCookie = domain.hasPrefix(".")
        guard let cookieHost = normalizedHost(isDomainCookie ? String(domain.dropFirst()) : domain) else {
            return false
        }
        return host == cookieHost || (isDomainCookie && host.hasSuffix("." + cookieHost))
    }

    private static func path(_ cookiePath: String, matches path: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard path.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || path.count == cookiePath.count
            || path[path.index(path.startIndex, offsetBy: cookiePath.count)] == "/"
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

private nonisolated struct StoredCookie: Codable, Hashable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain.lowercased()
        path = cookie.path.isEmpty ? "/" : cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
    }

    /// Domain and host-only cookies of the same name are different cookies, as in browsers.
    var identity: String { "\(name)\u{1F}\(domain)\u{1F}\(path)" }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}
