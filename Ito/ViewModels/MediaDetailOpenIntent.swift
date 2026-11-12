/// Opens the reader once a media detail screen has loaded, for screens such as History that
/// show a chapter before its series' chapter list is known.
enum MediaDetailOpenIntent: Equatable {
    /// Where the series was left off, as the screen's Resume button would open it. The group read
    /// last is preferred for the next chapter when the series' own record cannot name it, such as
    /// after the series moved to another source.
    case resume(preferredScanlator: String?, preferredScanlatorID: String? = nil)
    /// One chapter or episode as history recorded it.
    case chapter(MediaDetailChapterReference)
}

extension MediaDetailOpenIntent {
    enum Target<Chapter> {
        case open(Chapter)
        /// The chapter is locked on the source.
        case locked
        /// The source no longer lists the chapter.
        case unavailable
    }

    /// The group History saw, for picking among several groups' releases.
    var preferredScanlator: String? {
        switch self {
        case .resume(let scanlator, _): scanlator
        case .chapter(let reference): reference.scanlator
        }
    }

    var preferredScanlatorID: String? {
        switch self {
        case .resume(_, let id): id
        case .chapter(let reference): reference.scanlatorID
        }
    }

    /// What to open in `chapters`, given what the series' Resume would open; nil when there is
    /// nothing to open, such as an empty chapter list.
    func target<Chapter: ChapterDisplayable>(in chapters: [Chapter], resume: Chapter?) -> Target<Chapter>? {
        let chapter: Chapter
        switch self {
        case .resume:
            guard let resume else { return nil }
            chapter = resume
        case .chapter(let reference):
            guard let match = chapters.chapter(matching: reference) else { return .unavailable }
            chapter = match
        }
        return chapter.isPaywalled ? .locked : .open(chapter)
    }
}

/// A chapter as history recorded it. The key is tried first; when the source no longer lists that
/// key, the same number (and volume) from the same group is tried. Another group's upload is never
/// opened in its place; see `chapter(matching:)`.
struct MediaDetailChapterReference: Equatable {
    let key: String
    let number: Float?
    let volume: Float?
    let scanlator: String?
    var scanlatorID: String?
}

extension Collection where Element: ChapterDisplayable {
    /// The chapter `reference` names in this list, by key, else by number and volume within the
    /// recorded group. An empty group name counts as no group, as History stores it.
    ///
    /// Another upload is accepted only when it cannot be another group's:
    /// - the record names a group the list no longer has, and the source names no groups at all, with
    ///   one candidate (the series moved to a source without groups);
    /// - the record names no group, the source now names a group for every chapter, and there is one
    ///   candidate (the source started reporting groups).
    /// A record without a group is ambiguous among several ungrouped uploads; anything else is too.
    func chapter(matching reference: MediaDetailChapterReference) -> Element? {
        if let exact = first(where: { $0.key == reference.key }) {
            return exact
        }
        guard let number = reference.number, number.isFinite else { return nil }
        let sameNumber = filter {
            $0.chapterNumber.map { $0.isFinite && abs($0 - number) < 0.0001 } == true
        }
        let candidates: [Element]
        if let volume = reference.volume {
            let sameVolume = sameNumber.filter {
                $0.volumeNumber.map { abs($0 - volume) < 0.0001 } == true
            }
            if !sameVolume.isEmpty {
                candidates = sameVolume
            } else {
                // Do not choose another volume, or an unknown volume among numbered volumes.
                guard sameNumber.allSatisfy({ $0.volumeNumber == nil }) else { return nil }
                candidates = sameNumber
            }
        } else {
            // A legacy reference cannot distinguish chapter 1 of two different volumes.
            let volumes = Set(sameNumber.compactMap(\.volumeNumber))
            let hasUnknownVolume = sameNumber.contains { $0.volumeNumber == nil }
            guard volumes.count <= 1, volumes.isEmpty || !hasUnknownVolume else { return nil }
            candidates = sameNumber
        }
        if let id = reference.scanlatorID {
            let matches = candidates.filter { $0.scanlatorID?.utf8.elementsEqual(id.utf8) == true }
            return matches.count == 1 ? matches.first : nil
        }
        let recorded = Self.group(reference.scanlator)
        let sameGroup = candidates.filter { Self.group($0.scanlator) == recorded }
        if recorded != nil {
            if !sameGroup.isEmpty { return sameGroup.count == 1 ? sameGroup.first : nil }
            guard allSatisfy({ Self.group($0.scanlator) == nil }), candidates.count == 1 else { return nil }
            return candidates.first
        }
        // The record's chapter named no group.
        if !sameGroup.isEmpty { return sameGroup.count == 1 ? sameGroup.first : nil }
        guard !contains(where: { Self.group($0.scanlator) == nil }), candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func group(_ scanlator: String?) -> String? {
        guard let scanlator, !scanlator.isEmpty else { return nil }
        return scanlator
    }
}

/// The chapter a series' Resume opens: the last unfinished chapter, else the first unread one,
/// else (a completed series read to the end) the first, else the last. When several groups
/// release that chapter, the group of the chapter read last is picked, else `fallbackGroup`.
struct MediaDetailResumeTarget<Chapter: ChapterDisplayable> {
    let chapter: Chapter
    /// Resume starts a finished series over.
    let isRereading: Bool
    /// History continues the last chapter of a fully read series instead of restarting it.
    let continuationChapter: Chapter

    init?(
        chapters: [Chapter],
        lastReadKey: String?,
        fallbackGroup: String?,
        fallbackGroupID: String? = nil,
        useGroupIDs: Bool = false,
        isCompleted: Bool,
        isRead: (Chapter) -> Bool
    ) {
        let last = lastReadKey.flatMap { key in chapters.first { $0.key == key } }
        if let last, !isRead(last) {
            self.init(chapter: last, isRereading: false)
            return
        }
        let group = useGroupIDs
            ? (last.map(ReaderContinuationGroup.init) ?? ReaderContinuationGroup(id: fallbackGroupID, name: fallbackGroup))
            : ReaderContinuationGroup(id: nil, name: last?.scanlator ?? fallbackGroup)
        let ascending = chapters.sorted {
            let lhsVolume = $0.volumeNumber ?? -Float.infinity
            let rhsVolume = $1.volumeNumber ?? -Float.infinity
            if lhsVolume != rhsVolume { return lhsVolume < rhsVolume }
            return ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity)
        }
        let pick: (Chapter) -> Chapter = {
            Self.chapter(sameNumberAs: $0, in: chapters, preferring: group, useGroupIDs: useGroupIDs,
                         legacyName: last?.scanlator ?? fallbackGroup)
        }
        if let unread = ascending.first(where: { !isRead($0) }) {
            self.init(chapter: pick(unread), isRereading: false)
        } else if isCompleted, let first = ascending.first {
            self.init(chapter: pick(first), isRereading: true, continuation: last ?? pick(ascending[ascending.count - 1]))
        } else if let newest = ascending.last {
            self.init(chapter: pick(newest), isRereading: false)
        } else {
            return nil
        }
    }

    private init(chapter: Chapter, isRereading: Bool, continuation: Chapter? = nil) {
        self.chapter = chapter
        self.isRereading = isRereading
        self.continuationChapter = continuation ?? chapter
    }

    private static func chapter(sameNumberAs chapter: Chapter, in chapters: [Chapter], preferring group: ReaderContinuationGroup, useGroupIDs: Bool, legacyName: String?) -> Chapter {
        let matches: (Chapter) -> Bool = {
            useGroupIDs ? group.matches(ReaderContinuationGroup($0)) : $0.scanlator == legacyName
        }
        guard useGroupIDs ? (group.id != nil || group.name != nil) : legacyName != nil,
              !matches(chapter), let number = chapter.chapterNumber else { return chapter }
        return chapters.first {
            matches($0) && $0.volumeNumber == chapter.volumeNumber
                && $0.chapterNumber.map { abs($0 - number) < 0.0001 } == true
        } ?? chapter
    }
}
