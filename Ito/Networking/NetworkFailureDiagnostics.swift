import Darwin
import Foundation
import OSLog

/// Logs what a failed request looked like from inside this process, so a device log can tell the causes apart:
/// the system error, the lower-level error it wraps (for a failed name lookup, the resolver's own code), and how many
/// descriptors the process has open against its limit. A process out of descriptors can't open the socket a name
/// lookup needs, so its requests fail with "cannot find the host" while other apps on the device still connect.
///
/// Only codes, counts and the host are logged: never a path, query, header or body.
nonisolated enum NetworkFailureDiagnostics {
    struct Descriptors: Equatable {
        let open: Int
        let sockets: Int
        let limit: Int
    }

    /// Logs `error` if it is a transport failure. A cancelled request did not fail and is not logged.
    static func record(_ error: any Error, host: String?, transport: String) {
        guard let failure = failure(error) else { return }
        let descriptors = descriptors()
        AppLogger.network.error(
            """
            Transport failure transport=\(transport, privacy: .public) host=\(host ?? "-", privacy: .public) \
            code=\(failure.code, privacy: .public) underlying=\(failure.underlying, privacy: .public) \
            stream=\(failure.stream, privacy: .public) fds=\(descriptors.open, privacy: .public)/\
            \(descriptors.limit, privacy: .public) sockets=\(descriptors.sockets, privacy: .public)
            """
        )
    }

    struct Failure: Equatable {
        let code: Int
        /// `domain:code` of the wrapped error, or `-`.
        let underlying: String
        /// `domain:code` of the stream error CFNetwork reports with it, or `-`. Domain 12 is the resolver
        /// (`getaddrinfo`); its codes are the `EAI_` constants.
        let stream: String
    }

    /// The parts of `error` worth logging, or nil for a cancellation or an error that isn't a transport failure.
    static func failure(_ error: any Error) -> Failure? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return nil }
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain):\($0.code)" } ?? "-"
        let streamDomain = nsError.userInfo["_kCFStreamErrorDomainKey"] as? Int
        let streamCode = nsError.userInfo["_kCFStreamErrorCodeKey"] as? Int
        let stream = streamDomain.map { "\($0):\(streamCode ?? 0)" } ?? "-"
        return Failure(code: nsError.code, underlying: underlying, stream: stream)
    }

    /// The descriptors this process has open, how many are sockets, and the soft limit on them.
    static func descriptors() -> Descriptors {
        var limits = rlimit()
        let limit = getrlimit(RLIMIT_NOFILE, &limits) == 0 ? Int(clamping: limits.rlim_cur) : Int(getdtablesize())
        var open = 0
        var sockets = 0
        var info = stat()
        // Descriptors are numbered from zero; scanning past a few thousand would only cost time.
        for descriptor in 0..<Int32(clamping: min(limit, 8192)) where fstat(descriptor, &info) == 0 {
            open += 1
            if info.st_mode & S_IFMT == S_IFSOCK { sockets += 1 }
        }
        return Descriptors(open: open, sockets: sockets, limit: limit)
    }
}
