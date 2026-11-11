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
    /// The source marks the series finished; no more chapters are expected.
    var isCompleted: Bool { get }

    associatedtype Chapter: ChapterDisplayable
    var chapterList: [Chapter]? { get }
    /// What `chapterList` covers, as the source described it. Nil when the source said nothing about it.
    var chapterCatalog: ChapterCatalog? { get }
}

nonisolated extension Manga: MediaDisplayable {
    public var mediaKind: MediaKind { .manga }
    public var chapterList: [Manga.Chapter]? { chapters }
    public var chapterCatalog: ChapterCatalog? { catalog }
    public var studios: [String]? { nil }
    public var isCompleted: Bool { status == .Completed }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return String(localized: "Ongoing")
        case .Completed: return String(localized: "Completed")
        case .Cancelled: return String(localized: "Cancelled")
        case .Hiatus: return String(localized: "Hiatus")
        case .Unknown: return nil
        }
    }
}

nonisolated extension Anime: MediaDisplayable {
    public var mediaKind: MediaKind { .anime }
    public var authors: [String]? { nil }
    public var chapterList: [Anime.Episode]? { episodes }
    public var chapterCatalog: ChapterCatalog? { nil }
    public var isCompleted: Bool { status == .Completed }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return String(localized: "Ongoing")
        case .Completed: return String(localized: "Completed")
        case .Cancelled: return String(localized: "Cancelled")
        case .Hiatus: return String(localized: "Hiatus")
        case .Unknown: return nil
        }
    }
}

nonisolated extension Novel: MediaDisplayable {
    public var mediaKind: MediaKind { .novel }
    public var chapterList: [Novel.Chapter]? { chapters }
    public var chapterCatalog: ChapterCatalog? { catalog }
    public var studios: [String]? { nil }
    public var isCompleted: Bool { status == .Completed }
    public var displayStatus: String? {
        switch self.status {
        case .Ongoing: return String(localized: "Ongoing")
        case .Completed: return String(localized: "Completed")
        case .Cancelled: return String(localized: "Cancelled")
        case .Hiatus: return String(localized: "Hiatus")
        case .Unknown: return nil
        }
    }
}
