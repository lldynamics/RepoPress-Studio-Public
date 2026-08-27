import Foundation

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

  private func contentMigrationReviewItem(
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

  public func refreshContentMigrationPlanReview(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) -> ContentMigrationPlan {
    var refreshed = plan
    let pathCounts = Dictionary(
      grouping: plan.reviewItems,
      by: { $0.repositoryPath }
    ).mapValues(\.count)

    refreshed.reviewItems = plan.reviewItems.map { item in
      guard !item.repositoryPath.isEmpty,
        pathCounts[item.repositoryPath] == 1
      else {
        return contentMigrationReviewItem(item, disposition: .conflict)
      }

      let currentDraft = drafts.first {
        $0.belongs(toSiteProfileID: plan.profileID)
          && $0.repositoryPath?.normalizedRelativePath() == item.repositoryPath
      }

      guard let baseline = item.baseline else {
        return currentDraft == nil
          ? contentMigrationReviewItem(item, disposition: .insert)
          : contentMigrationReviewItem(item, disposition: .conflict)
      }

      guard let currentDraft,
        currentDraft.id == baseline.draft.id,
        store.draftStillMatchesOperationBaseline(
          DraftOperationBaseline(
            draft: baseline.draft,
            bodyRevision: baseline.bodyRevision
          )
        )
      else {
        return contentMigrationReviewItem(item, disposition: .conflict)
      }

      let comparison = DraftVersionComparisonService().compare(
        previous: currentDraft,
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
    return try applyContentMigration(
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
    let selectedItems = refreshed.reviewItems.filter { selectedDraftIDs.contains($0.id) }
    let conflicts =
      selectedItems
      .filter { $0.disposition == .conflict }
      .map { $0.repositoryPath.nilIfEmpty ?? $0.importedDraft.title }
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
