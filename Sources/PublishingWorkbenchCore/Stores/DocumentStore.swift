import Combine
import Foundation

/// Durable article-domain state.
///
/// Site navigation and publishing progress deliberately remain outside this
/// store.  This object is the sole mutable home for article collections and
/// their durable lifecycle records.
@MainActor
public final class DocumentStore: ObservableObject {
  @Published public internal(set) var drafts: [ArticleDraft]
  @Published public internal(set) var customMarkdownSnippets: [MarkdownSnippet]
  @Published public internal(set) var draftVersions: [DraftVersionSnapshot]
  @Published public internal(set) var recycledDrafts: [RecycledDraft]
  @Published public internal(set) var draftRepositoryCleanupRequests:
    [DraftRepositoryCleanupRequest]

  init(
    drafts: [ArticleDraft],
    customMarkdownSnippets: [MarkdownSnippet],
    draftVersions: [DraftVersionSnapshot],
    recycledDrafts: [RecycledDraft],
    draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest]
  ) {
    self.drafts = drafts
    self.customMarkdownSnippets = customMarkdownSnippets
    self.draftVersions = draftVersions
    self.recycledDrafts = recycledDrafts
    self.draftRepositoryCleanupRequests = draftRepositoryCleanupRequests
  }

  public func draft(for draftID: UUID) -> ArticleDraft? {
    drafts.first(where: { $0.id == draftID })
  }
}
