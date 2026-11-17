import Foundation

/// Decides whether a plugin web view's own main-frame navigation may proceed. A site's script can take the
/// plugin's window to another site (an advertisement, for one), and the plugin then loses the page its
/// verification or chapter needs. Such a navigation is refused; the page stays where it is.
///
/// Subframes are not refused, so a site's embedded challenge keeps working. Non-web targets (`about:`,
/// `blob:`, `data:`) and same-site navigations, including same-site redirects, are allowed.
nonisolated enum PluginPageNavigation {
    /// Whether a main-frame navigation to `target` leaves the site of `pageURL`, the page the plugin loaded.
    static func refuses(target: URL, isMainFrame: Bool, pageURL: URL?) -> Bool {
        guard isMainFrame, let pageURL, isWeb(target), isWeb(pageURL) else { return false }
        return !isSameSite(target, pageURL)
    }

    /// Whether two web URLs belong to the same site: equal registrable domains, or equal hosts when a domain
    /// has no registrable part (an IP address, a single-label host).
    static func isSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = lhs.host, let right = rhs.host else { return false }
        return siteKey(for: left) == siteKey(for: right)
    }

    /// Second-level labels that, under a two-letter country code, form a public suffix of their own
    /// (`example.co.uk` belongs to `example.co.uk`, not `co.uk`). This covers the common cases, not the full list.
    private static let publicSecondLevelLabels: Set<String> = [
        "ac", "co", "com", "edu", "gov", "go", "gob", "net", "nic", "ne", "or", "org"
    ]

    /// The registrable domain of `host`, lowercased: its last two labels, or three under a country-code
    /// second-level suffix such as `co.jp`. An IP address is its own site.
    static func siteKey(for host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !isIPAddress(host) else { return host }
        let last = labels[labels.count - 1]
        let secondLast = labels[labels.count - 2]
        let count = last.count == 2 && publicSecondLevelLabels.contains(secondLast) ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}
