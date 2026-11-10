import Combine
import UIKit
@testable import Ito

/// Connectivity the test drives. Delivery is synchronous, so a view model sees a change at once.
@MainActor
final class ConnectivityFake: ConnectivityServing {
    private let subject: CurrentValueSubject<Bool, Never>

    init(isOffline: Bool = false) {
        subject = CurrentValueSubject(isOffline)
    }

    var isOffline: Bool { subject.value }
    var isOfflinePublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }

    func set(isOffline: Bool) {
        subject.send(isOffline)
    }
}

/// Durable covers the test controls: it records what the Library captured and answers with what it is given.
@MainActor
final class LibraryCoverThumbnailsFake: LibraryCoverThumbnailServing {
    struct Capture {
        let itemID: String
        let coverUrl: String
        let image: UIImage
    }

    var thumbnails: [String: LibraryDurableCover] = [:]
    private(set) var forgotten: [Set<String>] = []
    private(set) var captures: [Capture] = []
    private(set) var thumbnailRequests: [String] = []

    func thumbnail(for itemID: String) async -> LibraryDurableCover? {
        thumbnailRequests.append(itemID)
        return thumbnails[itemID]
    }

    func capture(itemID: String, coverUrl: String, image: UIImage) {
        captures.append(Capture(itemID: itemID, coverUrl: coverUrl, image: image))
    }

    func forget(itemIDs: Set<String>) {
        forgotten.append(itemIDs)
    }
}
