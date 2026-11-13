import SwiftUI

extension LibraryItemView {
    /// Manga and novel badges count exact uploads, including alternate translations; anime keeps episodes.
    var updateBadgeAccessibilityLabel: Text {
        item.isAnime
            ? Text("\(badgeCount) episode updates", comment: "Library update badge for anime; preserves numbered episode counting.")
            : Text("\(badgeCount) edition updates", comment: "Library manga/novel badge counts exact uploads, including alternate translations, not logical chapters.")
    }
}
