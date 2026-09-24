import Combine
import Foundation

/// Narrow observation and command boundary for data-management surfaces.
///
/// Backup, migration, and storage views retain the root store only through this
/// facade. Unrelated editor, AI, repository, and publishing progress therefore
/// cannot invalidate those comparatively expensive settings trees.
@MainActor
public final class WorkbenchDataManagementFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store

    observe(store.publishingStore.documents.$drafts.map(\.count).removeDuplicates())
    observe(store.publishingStore.documents.$recycledDrafts.map(\.count).removeDuplicates())
    observe(
      store.publishingStore.documents.$draftRepositoryCleanupRequests
        .map { requests in
          requests.lazy.filter {
            $0.status == .pending || $0.remoteStatus == .pending
              || $0.remoteStatus == .reviewRequested
          }.count
        }
        .removeDuplicates()
    )
    observe(
      store.publishingStore.$profiles
        .map { profiles in profiles.map { ProfileNameSignature(id: $0.id, name: $0.name) } }
        .removeDuplicates()
    )
    observe(store.publishingStore.$activeProfileID.removeDuplicates())

    observe(store.knowledge.$documents.map(\.count).removeDuplicates())
    observe(store.knowledge.$recycledDocuments.map(\.count).removeDuplicates())
    observe(store.knowledge.$isBusy.removeDuplicates())
    observe(store.privacyProtectionStore.$isQuickHideActive.removeDuplicates())
    observe(store.persistenceStore.$isRecoveryWriteProtected.removeDuplicates())
  }

  public var draftCount: Int { store.drafts.count }

  public var recycledDraftCount: Int { store.recycledDrafts.count }

  public var pendingRepositoryCleanupCount: Int {
    store.pendingRepositoryCleanupRequests.count
  }

  public var activeProfileName: String { store.activeProfile.name }

  public var knowledgeDocumentCount: Int { store.knowledge.documents.count }

  public var knowledgeRecycledDocumentCount: Int {
    store.knowledge.recycledDocuments.count
  }

  public var isKnowledgeBusy: Bool { store.knowledge.isBusy }

  public var knowledge: KnowledgeStore { store.knowledge }

  public var lastSaveStatus: String { store.lastSaveStatus }

  public var canRestoreBackupArticles: Bool { store.canRestoreBackupArticles }

  public func workspaceBackupArticleSelectionPreview(from backupURL: URL) async throws
    -> WorkspaceBackupArticleSelectionPreview
  {
    try await store.workspaceBackupArticleSelectionPreview(from: backupURL)
  }

  @discardableResult
  public func restoreWorkspaceBackupArticles(
    preview: WorkspaceBackupArticleSelectionPreview,
    selectedDraftIDs: Set<UUID>
  ) async throws -> Int {
    try await store.restoreWorkspaceBackupArticles(
      preview: preview, selectedDraftIDs: selectedDraftIDs)
  }

  public func makeContentMigrationPlan(sourceURL: URL) async throws -> ContentMigrationPlan {
    try await store.makeContentMigrationPlan(sourceURL: sourceURL)
  }

  public func refreshContentMigrationPlanReviewAsync(
    _ plan: ContentMigrationPlan
  ) async throws -> ContentMigrationPlan {
    try await store.refreshContentMigrationPlanReviewAsync(plan)
  }

  @discardableResult
  public func applyContentMigrationAsync(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>
  ) async throws -> LocalContentImportMergeSummary {
    try await store.applyContentMigrationAsync(plan, selectedDraftIDs: selectedDraftIDs)
  }

  public func createWorkspaceBackup(
    at destinationURL: URL,
    selectedCategories: Set<WorkspaceBackupCategory>? = nil
  ) async -> WorkspaceBackupPreview? {
    await store.createWorkspaceBackup(at: destinationURL, selectedCategories: selectedCategories)
  }

  public func workspaceBackupSelectiveRestorePreview(
    from backupURL: URL
  ) async throws -> WorkspaceBackupSelectiveRestorePreview {
    try await store.workspaceBackupSelectiveRestorePreview(from: backupURL)
  }

  public func stageSelectiveWorkspaceBackupRestore(
    from backupURL: URL,
    categories: Set<WorkspaceBackupCategory>,
    to stagingURL: URL
  ) async throws -> WorkspaceBackupSelectiveRestoreStaging {
    try await store.stageSelectiveWorkspaceBackupRestore(
      from: backupURL, categories: categories, to: stagingURL
    )
  }

  public func prepareSelectiveWorkspaceBackupRestore(
    from backupURL: URL,
    categories: Set<WorkspaceBackupCategory>
  ) async throws -> WorkspaceBackupSelectiveRestorePreview {
    try await store.prepareSelectiveWorkspaceBackupRestore(
      from: backupURL, categories: categories
    )
  }

  public func workspaceBackupPreview(from backupURL: URL) async -> WorkspaceBackupPreview? {
    await store.workspaceBackupPreview(from: backupURL)
  }

  public func stageWorkspaceBackupRestore(from backupURL: URL) async -> Bool {
    await store.stageWorkspaceBackupRestore(from: backupURL)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  private struct ProfileNameSignature: Equatable {
    let id: UUID
    let name: String
  }
}
