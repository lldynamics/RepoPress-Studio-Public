import Foundation

extension WorkbenchStore {
  public func prepareProjectFileConflictReview(draftID: UUID) async throws -> ProjectFileConflictReview {
    flushDraftBodyEditorBuffers()
    await waitForPendingSiteDraftFileWrites()
    guard let draft = drafts.first(where: { $0.id == draftID }) else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("草稿已不存在，请重新检查。"))
    }
    let profile = profile(for: draft)
    let review = try await Task.detached(priority: .userInitiated) {
      try ProjectFileConflictService().review(draft: draft, profile: profile)
    }.value
    try validateCurrentProjectFileReview(review)
    return review
  }

  public func resolveProjectFileConflict(
    _ review: ProjectFileConflictReview, resolution: ProjectFileConflictResolution
  ) async throws {
    guard !isRetryingProjectFileWrites, !isPreparingSafeTermination else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("正在处理项目文件，请稍候再试。"))
    }
    isRetryingProjectFileWrites = true
    defer { isRetryingProjectFileWrites = false }
    flushDraftBodyEditorBuffers()
    await waitForPendingSiteDraftFileWrites()
    try validateCurrentProjectFileReview(review)
    let currentReview = try await Task.detached(priority: .userInitiated) {
      try ProjectFileConflictService().review(draft: review.draft, profile: review.profile)
    }.value
    try validateCurrentProjectFileReview(review)
    guard currentReview.rootIdentity == review.rootIdentity,
      currentReview.diskContentDigest == review.diskContentDigest else {
      throw SiteDraftFileStoreError.projectFileChangedExternally(review.repositoryPath)
    }
    // Even an explicit choice must be reversible before replacing the model.
    try persistLocalRecoverySnapshot()
    try ProjectFileConflictService().validateRoot(review)
    try ProjectFileConflictService().archive(
      review, under: persistenceStore.persistence.fileURL.deletingLastPathComponent())

    var replacement = review.diskDraft
    if case .mergedDocument(let document) = resolution {
      guard let root = review.profile.localRepositoryRootURL else {
        throw LocalPublishPreviewError.missingRepositoryRoot
      }
      replacement = try LocalContentImportService().parseProjectDocument(
        document, repositoryPath: review.repositoryPath, rootURL: root, profile: review.profile)
      let preview = try ProjectFileConflictService().mergePreview(document: document, review: review)
      _ = try await LocalPublishPreviewService().writeAsync(preview: preview, profile: review.profile)
      try validateCurrentProjectFileReview(review)
    }

    var retained = review.draft
    retained.id = UUID()
    retained.assignToGeneralDraft(editingProfileID: review.profile.id)
    retained.title += CoreL10n.text("（冲突恢复副本）")
    retained.softwareGuideID = nil
    retained.softwareGuideTemplateVersion = nil
    replacement.id = review.draft.id
    replacement.createdAt = review.draft.createdAt
    guard let index = publishingStore.drafts.firstIndex(where: { $0.id == review.draft.id }) else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("草稿已不存在，请重新检查。"))
    }
    let previousFailure = siteDraftFileSaveFailures[review.draft.id]
    let previousSaveState = siteDraftFileSaveStates[review.draft.id]
    let previousRecoveryRecord = draftRecoveryRecords[review.draft.id]
    publishingStore.drafts[index] = replacement
    publishingStore.drafts.append(retained)
    synchronizeDraftBodyEditorBuffer(with: replacement)
    // The retained full draft and exact archive now cover this editor journal
    // record. A genuinely different unresolved recovery remains available.
    if previousRecoveryRecord?.recoveredBodyMarkdown == review.draft.bodyMarkdown {
      draftRecoveryRecords[review.draft.id] = nil
      refreshPendingDraftRecoveries()
    }
    siteDraftFileSaveFailures[replacement.id] = nil
    siteDraftFileSaveStates[replacement.id] = .saved(repositoryPath: review.repositoryPath, savedAt: Date())
    siteDraftFileFlushFailureIDs.remove(replacement.id)
    invalidateDraftDerivedCaches()
    do {
      try persistLocalRecoverySnapshot()
    } catch {
      // A merge may already have reached the checkout. Keep the original local
      // model and exact archive; its old CAS baseline will continue protecting
      // the disk until the user reviews again.
      publishingStore.drafts.removeAll { $0.id == retained.id }
      if let oldIndex = publishingStore.drafts.firstIndex(where: { $0.id == review.draft.id }) {
        publishingStore.drafts[oldIndex] = review.draft
        synchronizeDraftBodyEditorBuffer(with: review.draft)
      }
      draftRecoveryRecords[review.draft.id] = previousRecoveryRecord
      refreshPendingDraftRecoveries()
      siteDraftFileSaveFailures[review.draft.id] = previousFailure
      siteDraftFileSaveStates[review.draft.id] = previousSaveState
      invalidateDraftDerivedCaches()
      throw error
    }
    if case .keepBoth = resolution {
      _ = publishingStore.focusDraft(retained.id, section: .writing, store: self)
    }
  }

  private func validateCurrentProjectFileReview(_ review: ProjectFileConflictReview) throws {
    guard !persistenceStore.isRecoveryWriteProtected,
      let current = drafts.first(where: { $0.id == review.draft.id }), current == review.draft,
      profile(for: current) == review.profile,
      !draftBodyEditorBuffer(for: current.id).isDirty
    else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("草稿或站点在审阅期间发生变化，请重新载入差异。"))
    }
  }
}
