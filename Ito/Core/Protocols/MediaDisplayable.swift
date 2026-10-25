import Foundation
@preconcurrency import ito_runner

public protocol MediaDisplayable: Identifiable, Codable, Sendable {
    var key: String { get }
    var mediaKind: MediaKind { get }
    var title: String { get }
    var cover: String? { get }
    var authors: [String]? { get }   // nil for anime
    var studios: [String]? { get }   // nil for manga/novel
    var tags: [String]? { get }
    var description: String? { get }
    var displayStatus: String? { get }

    associatedtype Chapter: ChapterDisplayable
    var chapterList: [Chapter]? { get }
}

nonisolated extension Manga: MediaDisplayable {
    public var mediaKind: MediaKind { .manga }
    public var chapterList: [Manga.Chapter]? { chapters }
    public var studios: [String]? { nil }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus: return "Hiatus"
        case .Unknown: return nil
        }
    }
}

nonisolated extension Anime: MediaDisplayable {
    public var mediaKind: MediaKind { .anime }
    public var authors: [String]? { nil }
    public var chapterList: [Anime.Episode]? { episodes }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus: return "Hiatus"
        case .Unknown: return nil
        }
    }
}

nonisolated extension Novel: MediaDisplayable {
    public var mediaKind: MediaKind { .novel }
    public var chapterList: [Novel.Chapter]? { chapters }
    public var studios: [String]? { nil }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus: return "Hiatus"
        case .Unknown: return nil
        }
    }
}
