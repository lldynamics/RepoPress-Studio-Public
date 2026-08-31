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
  let presentationDidChange = CurrentValueSubject<UInt64, Never>(0)

  public private(set) var presentationRevision: UInt64 = 0
  public private(set) var taskQueueStateVersion = 0
  private(set) var searchIndexBuildCount = 0
  private var searchIndexCache: [SearchIndexCacheKey: DraftSearchIndex] = [:]
  private var lastPresentationInput: PresentationInput?
  // @Published emits from willSet. A structural publisher can therefore send
  // the list its one required notification before the store exposes the new
  // value to a fingerprint read. The next explicit boundary synchronizes the
  // fingerprint without issuing a duplicate notification.
  private var presentationInputNeedsSynchronization = false
  private var presentationInputSynchronizationGeneration: UInt64 = 0

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
    _ = recordCurrentPresentationInputIfChanged()
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
    presentationInputNeedsSynchronization = true
    presentationInputSynchronizationGeneration &+= 1
    let synchronizationGeneration = presentationInputSynchronizationGeneration
    objectWillChange.send()
    presentationRevision &+= 1
    presentationDidChange.send(presentationRevision)
    searchIndexCache.removeAll(keepingCapacity: true)
    // If no explicit Workbench boundary follows this publisher event (privacy
    // settings and navigation can take that path), synchronize after willSet
    // has committed. The generation prevents an older deferred read from
    // overwriting a newer input.
    Task { @MainActor [weak self] in
      guard let self,
        self.presentationInputNeedsSynchronization,
        self.presentationInputSynchronizationGeneration == synchronizationGeneration
      else { return }
      self.lastPresentationInput = self.currentPresentationInput()
      self.presentationInputNeedsSynchronization = false
    }
  }

  func invalidatePresentationAndTaskQueueState(
    suppressDuplicatePresentation: Bool = false
  ) {
    // Metadata edits schedule both an immediate cache refresh and a delayed
    // preflight refresh.  The latter must not rebuild the same list a second
    // time when no list input has changed in between. Repository/task-only
    // publishers use `invalidateTaskQueueState()` independently.
    let input = currentPresentationInput()
    if presentationInputNeedsSynchronization {
      presentationInputNeedsSynchronization = false
      lastPresentationInput = input
      taskQueueStateVersion += 1
      return
    }
    if lastPresentationInput != input {
      lastPresentationInput = input
      objectWillChange.send()
      presentationRevision &+= 1
      presentationDidChange.send(presentationRevision)
      taskQueueStateVersion += 1
      searchIndexCache.removeAll(keepingCapacity: true)
      return
    }

    // A delayed metadata preflight carries the same list input as the
    // immediate edit. Advance the semantic task token but avoid a second full
    // list invalidation; standalone invalidations still notify task badges.
    taskQueueStateVersion += 1
    if !suppressDuplicatePresentation {
      objectWillChange.send()
    }
  }

  private struct SearchIndexCacheKey: Hashable {
    let revision: UInt64
    let corpus: DraftSearchCorpus
    let masksPrivateContent: Bool
  }

  private struct PresentationInput: Equatable {
    let drafts: [ArticleDraftListMetadataProjection]
    let activeProfileID: UUID
    let contentScope: DraftListContentScope
    let profiles: [ProfileProjection]
    let masksPrivateContent: Bool
  }

  private func currentPresentationInput() -> PresentationInput {
    PresentationInput(
      drafts: store.drafts.map(\.listMetadataProjection),
      activeProfileID: store.activeProfileID,
      contentScope: store.publishingStore.draftListContentScope,
      profiles: store.publishingStore.profiles.map(ProfileProjection.init).sorted {
        $0.id.uuidString < $1.id.uuidString
      },
      masksPrivateContent: store.privacyProtectionStore.privacySettings.masksPrivateContent
    )
  }

  @discardableResult
  private func recordCurrentPresentationInputIfChanged() -> Bool {
    let input = currentPresentationInput()
    guard input != lastPresentationInput else { return false }
    lastPresentationInput = input
    return true
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
