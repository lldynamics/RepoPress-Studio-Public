import Combine
import Foundation

/// A narrow observation boundary for the Writing list.
///
/// Draft body text, derived word counts and content-write timestamps are
/// intentionally absent from the draft projection.  A body autosave therefore
/// updates the publishing store without rebuilding the sidebar's projection
/// tree.  List-visible metadata still invalidates this store, while task
/// badges and repository/privacy context have explicit, independent inputs.
@MainActor
public final class DraftListStore: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public private(set) var presentationRevision: UInt64 = 0
  public private(set) var taskQueueStateVersion = 0
  private(set) var searchIndexBuildCount = 0
  private var searchIndexCache: [SearchIndexCacheKey: DraftSearchIndex] = [:]

  public init(store: WorkbenchStore) {
    self.store = store
    // Structural changes are an O(1) fallback. Ordinary metadata mutations
    // enter through WorkbenchStore's explicit invalidation boundary, so a
    // body flush never walks the draft collection merely to suppress a UI
    // notification afterward.
    store.publishingStore.$drafts
      .map(\.count)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.invalidatePresentation()
      }
      .store(in: &cancellables)

    observe(
      Publishers.CombineLatest(
        store.publishingStore.$profiles,
        store.publishingStore.$activeProfileID
      )
      .map { profiles, activeProfileID in
        SearchProfileProjection(
          activeProfileID: activeProfileID,
          profiles: profiles.map(ProfileProjection.init).sorted {
            $0.id.uuidString < $1.id.uuidString
          }
        )
      }
    )
    observe(store.publishingStore.$draftListContentScope)
    observeTaskQueueValue(store.repositoryStore.$repositoryReport)
    observe(store.privacyProtectionStore.$privacySettings)
  }

  public var selectedDraftID: UUID? {
    store.publishingStore.selectedDraftID
  }

  public var contentScope: DraftListContentScope {
    store.publishingStore.draftListContentScope
  }

  public var repositoryReport: RepositoryScanReport? {
    store.repositoryReport
  }

  /// Returns a long-lived index for the requested corpus.  Metadata, privacy,
  /// profile and site-scope changes all advance presentationRevision, while
  /// body-only autosaves intentionally leave this cache untouched.
  public func searchIndex(for corpus: DraftSearchCorpus) -> DraftSearchIndex {
    let key = SearchIndexCacheKey(
      revision: presentationRevision,
      corpus: corpus,
      masksPrivateContent: store.privacyProtectionStore.privacySettings.masksPrivateContent
    )
    if let cached = searchIndexCache[key] {
      return cached
    }

    let drafts: [ArticleDraft]
    switch corpus {
    case .activeSite:
      drafts = store.visibleDrafts
    case .allDrafts:
      drafts = store.drafts
    }
    let index = DraftSearchIndex(
      drafts: drafts,
      profile: { [store] draft in store.profile(for: draft) },
      masksPrivateContent: key.masksPrivateContent,
      revision: presentationRevision
    )
    searchIndexBuildCount += 1
    searchIndexCache[key] = index
    if searchIndexCache.count > 4 {
      searchIndexCache = searchIndexCache.filter { $0.key.revision == presentationRevision }
    }
    return index
  }

  /// Kept as a read-only compatibility projection for list views that still
  /// use the image workbench's independent refresh token.  It is deliberately
  /// not observed by this store because image refresh is not list topology.
  public var imageInputRevision: UInt64 {
    store.imageWorkbenchInputRevision
  }

  /// Invalidates task badges without changing the folder/search projection.
  func invalidateTaskQueueState() {
    objectWillChange.send()
    taskQueueStateVersion += 1
  }

  func invalidatePresentation() {
    objectWillChange.send()
    presentationRevision &+= 1
    searchIndexCache.removeAll(keepingCapacity: true)
  }

  func invalidatePresentationAndTaskQueueState() {
    objectWillChange.send()
    presentationRevision &+= 1
    taskQueueStateVersion += 1
    searchIndexCache.removeAll(keepingCapacity: true)
  }

  private struct SearchIndexCacheKey: Hashable {
    let revision: UInt64
    let corpus: DraftSearchCorpus
    let masksPrivateContent: Bool
  }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.invalidatePresentation()
      }
      .store(in: &cancellables)
  }

  private func observeTaskQueueValue<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.invalidateTaskQueueState()
      }
      .store(in: &cancellables)
  }

  private struct ProfileProjection: Equatable {
    let id: UUID
    let contentRoot: String
    let markdownPathPattern: String

    init(_ profile: SiteProfile) {
      id = profile.id
      contentRoot = profile.contentRoot
      markdownPathPattern = profile.markdownPathPattern
    }
  }

  private struct SearchProfileProjection: Equatable {
    let activeProfileID: UUID
    let profiles: [ProfileProjection]
  }
}
