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

    observe(store.publishingStore.$drafts.map(\.count).removeDuplicates())
    observe(store.publishingStore.$recycledDrafts.map(\.count).removeDuplicates())
    observe(
      store.publishingStore.$draftRepositoryCleanupRequests
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

  public func createWorkspaceBackup(at destinationURL: URL) async -> WorkspaceBackupPreview? {
    await store.createWorkspaceBackup(at: destinationURL)
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
