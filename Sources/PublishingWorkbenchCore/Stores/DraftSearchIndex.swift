import Foundation

/// The two draft corpora used by workspace search surfaces.  They are kept
/// separate because the all-drafts palette must not reuse the active-site
/// projection (and vice versa).
public enum DraftSearchCorpus: Hashable, Sendable {
  case activeSite
  case allDrafts
}

/// Immutable, query-ready draft metadata.  Construction performs the only
/// sort and string concatenation; subsequent keystrokes only scan this value.
public struct DraftSearchIndex: Sendable {
  public struct Entry: Sendable {
    public let draft: ArticleDraft
    fileprivate let key: String
  }

  public let entries: [Entry]
  public let sourceRevision: UInt64

  init(
    drafts: [ArticleDraft],
    profile: (ArticleDraft) -> SiteProfile,
    masksPrivateContent: Bool,
    revision: UInt64
  ) {
    sourceRevision = revision
    let ordered = drafts.sorted {
      if $0.metadataUpdatedAt == $1.metadataUpdatedAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.metadataUpdatedAt > $1.metadataUpdatedAt
    }
    entries = ordered.map { draft in
      let fields: [String]
      if draft.isPrivate, masksPrivateContent {
        fields = [draft.title, "私密文章", "内容已遮挡"]
      } else {
        let siteProfile = profile(draft)
        fields = [
          draft.title,
          draft.slug,
          draft.summary,
          draft.tags.joined(separator: " "),
          draft.categories.joined(separator: " "),
          siteProfile.markdownPath(for: draft),
        ]
      }
      return Entry(draft: draft, key: fields.joined(separator: " ").lowercased())
    }
  }

  public func matching(
    query: String,
    preferredDraftIDs: [UUID]? = nil
  ) -> [ArticleDraft] {
    let normalized = query.trimmedForPublishing.lowercased()
    let matched = entries.filter { normalized.isEmpty || $0.key.contains(normalized) }
    guard let preferredDraftIDs else { return matched.map(\.draft) }

    let matchedByID = Dictionary(uniqueKeysWithValues: matched.map { ($0.draft.id, $0.draft) })
    return preferredDraftIDs.compactMap { matchedByID[$0] }
  }
}
