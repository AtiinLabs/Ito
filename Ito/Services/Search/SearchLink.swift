import Foundation

/// A search query that is a web address. Search asks only the sources whose declared website
/// serves that address to open it, through their optional `handle_url` export; other sources
/// are not searched for the address text.
nonisolated struct SearchLink: Equatable, Sendable {
    let url: String
    private let host: String

    init?(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = Self.normalizedHost(components.host) else { return nil }
        url = trimmed
        self.host = host
    }

    /// True when `siteURL` (a plugin manifest's website) is this link's site or a parent domain
    /// of it: `https://mangafire.to` matches links on `mangafire.to` and `www.mangafire.to`.
    func belongs(toSite siteURL: String?) -> Bool {
        guard let siteURL,
              let siteHost = Self.normalizedHost(URLComponents(string: siteURL)?.host) else { return false }
        return host == siteHost || host.hasSuffix("." + siteHost)
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}
