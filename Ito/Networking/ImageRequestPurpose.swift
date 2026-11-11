import Foundation
import ito_runner

/// Why a reader page image is requested. The reader marks each request in memory; `PluginDataLoader`
/// reads the mark, and an unmarked request counts as a cover image.
///
/// The mark is a URLProtocol property. Foundation does not serialize such properties into the HTTP
/// message, and `unmarked(_:)` removes it from every request handed to a network loader, so the
/// transport never receives it.
///
/// Nuke coalesces requests for one URL into one data task, and that task keeps the purpose of the first
/// request that started it. A later request for the same URL shares that purpose. No behaviour depends on the
/// purpose yet, so this is accepted rather than worked around.
nonisolated enum ImageRequestPurpose: String, Sendable {
    case foregroundReading
    case prefetch

    private static let propertyKey = "ito.imageRequestPurpose"

    var networkPurpose: NetworkOperationContext.Purpose {
        switch self {
        case .foregroundReading: .foregroundReading
        case .prefetch: .prefetch
        }
    }

    /// `request` carrying this purpose mark. The mark lives on a mutable copy, the only form URLProtocol takes.
    func applied(to request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return request }
        URLProtocol.setProperty(rawValue, forKey: Self.propertyKey, in: mutable)
        return mutable as URLRequest
    }

    /// The purpose marked on `request`, or nil when it carries no mark.
    static func marked(on request: URLRequest) -> ImageRequestPurpose? {
        (URLProtocol.property(forKey: propertyKey, in: request) as? String).flatMap(Self.init(rawValue:))
    }

    /// `request` without any purpose mark. Foundation removes the URLProtocol property from a mutable copy,
    /// so every other field is kept as it is. An unmarked request is returned unchanged.
    static func unmarked(_ request: URLRequest) -> URLRequest {
        guard URLProtocol.property(forKey: propertyKey, in: request) != nil,
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.removeProperty(forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }
}
