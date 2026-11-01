/// Opens the reader once a media detail screen has loaded, for screens such as History that
/// show a chapter before its series' chapter list is known.
enum MediaDetailOpenIntent: Equatable {
    /// Where the series was left off, as the screen's Resume button would open it.
    case resume
    /// One chapter or episode, by key. Nothing opens if the loaded list does not contain it.
    case chapter(key: String)
}
