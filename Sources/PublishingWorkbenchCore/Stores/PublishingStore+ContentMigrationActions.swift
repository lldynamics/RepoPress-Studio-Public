import Foundation

private struct ContentMigrationCurrentDraftSnapshot: Sendable {
  let draft: ArticleDraft
  let bodyRevision: UInt64
  let isBodyDirty: Bool

  func matches(_ baseline: ContentMigrationDraftBaseline) -> Bool {
    !isBodyDirty && draft == baseline.draft && bodyRevision == baseline.bodyRevision
  }
}

private struct ContentMigrationPlanReviewService: Sendable {
  func refresh(
    _ plan: ContentMigrationPlan,
    currentDrafts: [ContentMigrationCurrentDraftSnapshot]
  ) -> ContentMigrationPlan {
    do {
      return try refresh(
        plan,
        currentDrafts: currentDrafts,
        cancellationCheck: {}
      )
    } catch {
      // The compatibility path supplies an empty cancellation check, so the
      // throwing implementation has no reachable error source. Preserve the
      // reviewed plan instead of turning a violated invariant into a crash.
      assertionFailure("Unexpected content migration review failure: \(error)")
      return plan
    }
  }

  func refresh(
    _ plan: ContentMigrationPlan,
    currentDrafts: [ContentMigrationCurrentDraftSnapshot],
    cancellationCheck: () throws -> Void
  ) throws -> ContentMigrationPlan {
    try cancellationCheck()
    var refreshed = plan
    let pathCounts = Dictionary(
      grouping: plan.reviewItems,
      by: { $0.repositoryPath }
    ).mapValues(\.count)
    let currentDraftByPath = currentDrafts.reduce(
      into: [String: ContentMigrationCurrentDraftSnapshot]()
    ) { result, snapshot in
      guard snapshot.draft.belongs(toSiteProfileID: plan.profileID),
        let path = snapshot.draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        result[path] == nil
      else { return }
      result[path] = snapshot
    }

    refreshed.reviewItems = try plan.reviewItems.map { item in
      try cancellationCheck()
      guard !item.repositoryPath.isEmpty,
        pathCounts[item.repositoryPath] == 1
      else {
        return reviewItem(item, disposition: .conflict)
      }

      let current = currentDraftByPath[item.repositoryPath]
      guard let baseline = item.baseline else {
        return current == nil
          ? reviewItem(item, disposition: .insert)
          : reviewItem(item, disposition: .conflict)
      }
      guard let current,
        current.draft.id == baseline.draft.id,
        current.matches(baseline)
      else {
        return reviewItem(item, disposition: .conflict)
      }

      let comparison = DraftVersionComparisonService().compare(
        previous: current.draft,
        current: item.importedDraft
      )
      return ContentMigrationDraftReviewItem(
        importedDraft: item.importedDraft,
        baseline: baseline,
        disposition: comparison.hasChanges ? .update : .unchanged,
        comparison: comparison
      )
    }
    refreshed.drafts = refreshed.reviewItems.map(\.importedDraft)
    return refreshed
  }

  private func reviewItem(
    _ item: ContentMigrationDraftReviewItem,
    disposition: ContentMigrationDraftDisposition
  ) -> ContentMigrationDraftReviewItem {
    ContentMigrationDraftReviewItem(
      importedDraft: item.importedDraft,
      baseline: item.baseline,
      disposition: disposition,
      comparison: disposition == .update || disposition == .unchanged ? item.comparison : nil
    )
  }
}

extension PublishingStore {
  public func makeContentMigrationPlan(sourceURL: URL, store: WorkbenchStore) async throws
    -> ContentMigrationPlan
  {
    let profile = store.activeProfile
    let plan = try await contentMigrationService.makePlanAsync(
      sourceURL: sourceURL, profile: profile)
    guard plan.profileID == store.activeProfileID,
      plan.profileConfiguration
        == ContentMigrationProfileConfiguration(profile: store.activeProfile)
    else {
      throw ContentMigrationError.profileChanged
    }
    store.flushDraftBodyEditorBuffers()
    return captureContentMigrationBaselines(in: plan, store: store)
  }

  private func captureContentMigrationBaselines(
    in plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) -> ContentMigrationPlan {
    var prepared = plan
    let pathCounts = Dictionary(
      grouping: plan.drafts,
      by: { $0.repositoryPath?.normalizedRelativePath() ?? "" }
    ).mapValues(\.count)
    let comparisonService = DraftVersionComparisonService()

    prepared.reviewItems = plan.drafts.map { importedDraft in
      let repositoryPath = importedDraft.repositoryPath?.normalizedRelativePath() ?? ""
      guard !repositoryPath.isEmpty,
        pathCounts[repositoryPath] == 1
      else {
        return ContentMigrationDraftReviewItem(
          importedDraft: importedDraft,
          disposition: .conflict
        )
      }

      guard
        let existingDraft = drafts.first(where: {
          $0.belongs(toSiteProfileID: plan.profileID)
            && $0.repositoryPath?.normalizedRelativePath() == repositoryPath
        }), let operationBaseline = store.draftOperationBaseline(for: existingDraft.id)
      else {
        return ContentMigrationDraftReviewItem(
          importedDraft: importedDraft,
          disposition: .insert
        )
      }

      let comparison = comparisonService.compare(
        previous: existingDraft,
        current: importedDraft
      )
      return ContentMigrationDraftReviewItem(
        importedDraft: importedDraft,
        baseline: ContentMigrationDraftBaseline(
          draft: operationBaseline.draft,
          bodyRevision: operationBaseline.bodyRevision
        ),
        disposition: comparison.hasChanges ? .update : .unchanged,
        comparison: comparison
      )
    }
    prepared.drafts = prepared.reviewItems.map(\.importedDraft)
    return prepared
  }

  public func refreshContentMigrationPlanReview(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) -> ContentMigrationPlan {
    ContentMigrationPlanReviewService().refresh(
      plan,
      currentDrafts: contentMigrationCurrentDraftSnapshots(store: store)
    )
  }

  public func refreshContentMigrationPlanReviewAsync(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) async throws -> ContentMigrationPlan {
    store.flushDraftBodyEditorBuffers()
    let currentDrafts = contentMigrationCurrentDraftSnapshots(store: store)
    let worker = Task.detached(priority: .userInitiated) {
      try ContentMigrationPlanReviewService().refresh(
        plan,
        currentDrafts: currentDrafts,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private func contentMigrationCurrentDraftSnapshots(
    store: WorkbenchStore
  ) -> [ContentMigrationCurrentDraftSnapshot] {
    drafts.map { draft in
      let buffer = store.draftBodyEditorBuffer(for: draft.id)
      return ContentMigrationCurrentDraftSnapshot(
        draft: draft,
        bodyRevision: buffer.revision,
        isBodyDirty: buffer.isDirty
      )
    }
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    let refreshed = refreshContentMigrationPlanReview(plan, store: store)
    let selectedDraftIDs = Set(
      refreshed.reviewItems
        .filter { $0.disposition.isSelectable }
        .map(\.id)
    )
    return try applyReviewedContentMigration(
      refreshed,
      selectedDraftIDs: selectedDraftIDs,
      store: store
    )
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    guard plan.profileID == store.activeProfileID,
      plan.profileConfiguration
        == ContentMigrationProfileConfiguration(profile: store.activeProfile)
    else {
      throw ContentMigrationError.profileChanged
    }
    store.flushDraftBodyEditorBuffers()
    let refreshed = refreshContentMigrationPlanReview(plan, store: store)
    return try applyReviewedContentMigration(
      refreshed,
      selectedDraftIDs: selectedDraftIDs,
      store: store
    )
  }

  @discardableResult
  public func applyContentMigrationAsync(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>,
    store: WorkbenchStore
  ) async throws -> LocalContentImportMergeSummary {
    guard plan.profileID == store.activeProfileID,
      plan.profileConfiguration
        == ContentMigrationProfileConfiguration(profile: store.activeProfile)
    else {
      throw ContentMigrationError.profileChanged
    }
    let refreshed = try await refreshContentMigrationPlanReviewAsync(plan, store: store)
    // Cancellation is the user's promise that dismissing the assistant will
    // not begin the final mutation after background review has finished.
    try Task.checkCancellation()
    return try applyReviewedContentMigration(
      refreshed,
      selectedDraftIDs: selectedDraftIDs,
      store: store
    )
  }

  private func applyReviewedContentMigration(
    _ refreshed: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    guard refreshed.profileID == store.activeProfileID,
      refreshed.profileConfiguration
        == ContentMigrationProfileConfiguration(profile: store.activeProfile)
    else {
      throw ContentMigrationError.profileChanged
    }
    store.flushDraftBodyEditorBuffers()
    let selectedItems = refreshed.reviewItems.filter { selectedDraftIDs.contains($0.id) }
    let currentDraftByPath = drafts.reduce(into: [String: ArticleDraft]()) { result, draft in
      guard draft.belongs(toSiteProfileID: refreshed.profileID),
        let path = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        result[path] == nil
      else { return }
      result[path] = draft
    }
    let conflicts = selectedItems.compactMap { item -> String? in
      let identity = item.repositoryPath.nilIfEmpty ?? item.importedDraft.title
      switch item.disposition {
      case .conflict:
        return identity
      case .insert:
        let nowExists = currentDraftByPath[item.repositoryPath] != nil
        return nowExists ? identity : nil
      case .update, .unchanged:
        guard let baseline = item.baseline,
          let currentDraft = currentDraftByPath[item.repositoryPath],
          currentDraft.id == baseline.draft.id,
          store.draftStillMatchesOperationBaseline(
            DraftOperationBaseline(
              draft: baseline.draft,
              bodyRevision: baseline.bodyRevision
            )
          )
        else { return identity }
        return nil
      }
    }
    guard conflicts.isEmpty else {
      throw ContentMigrationError.draftsChanged(conflicts)
    }

    let importItems = selectedItems.filter { $0.disposition.isSelectable }
    guard !importItems.isEmpty else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }

    let expectedBaselines = Dictionary(
      uniqueKeysWithValues: importItems.compactMap { item -> (String, DraftOperationBaseline)? in
        guard let baseline = item.baseline else { return nil }
        return (
          item.repositoryPath,
          DraftOperationBaseline(draft: baseline.draft, bodyRevision: baseline.bodyRevision)
        )
      }
    )
    let selectedIDs = Set(importItems.map(\.id))
    let skippedPaths = refreshed.reviewItems
      .filter { !selectedIDs.contains($0.id) }
      .map(\.repositoryPath)
      .filter { !$0.isEmpty }
    let summary = mergeImportedDrafts(
      LocalContentImportResult(
        importedDrafts: importItems.map(\.importedDraft),
        skippedPaths: skippedPaths
      ),
      expectedBaselinesByRepositoryPath: expectedBaselines,
      store: store
    )
    if let firstImported = importItems.first?.importedDraft,
      let imported = drafts.first(where: {
        $0.siteProfileID == firstImported.siteProfileID
          && $0.repositoryPath == firstImported.repositoryPath
      })
    {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    setPublishActionMessage(
      "已导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇；已生成 \(refreshed.imageMappings.count) 条图片路径映射和 \(refreshed.redirects.count) 条重定向候选。",
      status: .success
    )
    store.save()
    return summary
  }
}
