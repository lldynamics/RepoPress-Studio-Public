import Foundation
import PublishingDomainContracts

/// Inspector-lifetime memo. Exact inputs prevent stale values after unsaved edits;
/// one retained entry bounds memory, and internal updates never publish view changes.
@MainActor
final class ArticleProvenancePresentationCache {
  private struct Key: Equatable {
    let draftID: UUID
    let tags: [String]
    let bodyMarkdown: String
  }

  private var cachedKey: Key?
  private var cachedProvenance: ArticleProvenance?

  func provenance(
    draftID: UUID,
    tags: [String],
    bodyMarkdown: String,
    classify: () -> ArticleProvenance
  ) -> ArticleProvenance {
    let key = Key(draftID: draftID, tags: tags, bodyMarkdown: bodyMarkdown)
    if key == cachedKey, let cachedProvenance {
      return cachedProvenance
    }

    let provenance = classify()
    cachedKey = key
    cachedProvenance = provenance
    return provenance
  }
}
