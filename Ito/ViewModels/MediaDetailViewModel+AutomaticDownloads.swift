import Foundation
import ito_runner

/// The series screen as the rule of automatic downloads sees it. The rule's own state lives in `automaticRule`, which
/// reads the database and never checks a source.
extension MediaDetailViewModel: SubscriptionRuleHost {
    var ruleIsSaved: Bool { isSaved }
    var ruleScanlatorOptions: [ScanlatorOption] { downloadBatch.scanlatorOptions() }
    var ruleDefaultSelection: EditionSelection { downloadBatch.rememberedSelection }
    var ruleCatalogDigest: String { catalogDigest }

    /// Whether the series offers automatic downloads at all: they are composed and the series is a manga or a novel.
    var showsAutomaticDownloads: Bool {
        if case .hidden = automaticRule.entry { return false }
        return true
    }
}
