import Foundation

private struct SiteStarterOperationBaseline: Equatable {
  let profiles: [SiteProfile]
  let activeProfileID: UUID
  let drafts: [ArticleDraft]
  let selectedDraftID: UUID?
  let siteStarterResult: SiteStarterResult?
  let siteStarterImportResult: SiteStarterImportResult?
  let siteStarterPushResult: SiteStarterPushResult?

  @MainActor
  init(store: PublishingStore) {
    profiles = store.profiles
    activeProfileID = store.activeProfileID
    drafts = store.drafts
    selectedDraftID = store.selectedDraftID
    siteStarterResult = store.siteStarterResult
    siteStarterImportResult = store.siteStarterImportResult
    siteStarterPushResult = store.siteStarterPushResult
  }

  @MainActor
  func stillMatches(_ store: PublishingStore) -> Bool {
    self == SiteStarterOperationBaseline(store: store)
  }
}

extension PublishingStore {
  @discardableResult
  public func importDraftsFromLocalRepository(store: WorkbenchStore)
    -> LocalContentImportMergeSummary
  {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      setPublishActionMessage("选择本地仓库后才能导入文章。", status: .warning)
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    store.flushDraftBodyEditorBuffers()
    let imported = hydrateLocalRepositoryBaselines(
      localContentImportService.importDrafts(profile: store.activeProfile),
      profile: store.activeProfile,
      store: store
    )
    return mergeImportedDrafts(
      imported,
      store: store
    )
  }

  @discardableResult
  public func importDraftsFromLocalRepositoryAsync(store: WorkbenchStore) async
    -> LocalContentImportMergeSummary
  {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      setPublishActionMessage("选择本地仓库后才能导入文章。", status: .warning)
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }

    var draftBaselinesByRepositoryPath: [String: DraftOperationBaseline] = [:]
    for draft in drafts where draft.belongs(toSiteProfileID: profile.id) {
      guard let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        let baseline = store.draftOperationBaseline(for: draft.id)
      else { continue }
      draftBaselinesByRepositoryPath[repositoryPath] = baseline
    }

    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    setPublishActionMessage("正在从本地仓库导入文章…", status: .inProgress)
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importDraftsAsync(profile: profile)
    } catch is CancellationError {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        setPublishActionMessage("已取消从本地仓库导入文章。", status: .warning)
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        setPublishActionMessage(
          "导入本地文章失败：\(error.localizedDescription)",
          status: .failure
        )
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
    let hydratedResult = hydrateLocalRepositoryBaselines(
      result,
      profile: profile,
      store: store
    )
    return mergeImportedDrafts(
      hydratedResult,
      expectedBaselinesByRepositoryPath: draftBaselinesByRepositoryPath,
      store: store
    )
  }

  /// Discovers repository articles that have never been added to the writing
  /// library. Existing drafts are intentionally left untouched so an external
  /// editor cannot overwrite unsaved or newer work in this app.
  @discardableResult
  public func importMissingDraftsFromLocalRepository(store: WorkbenchStore) async -> Int {
    await importMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: false,
      announcesInsertions: true
    )
  }

  /// Keeps the narrower private-only migration available for older callers.
  @discardableResult
  public func importMissingPrivateDraftsFromLocalRepository(store: WorkbenchStore) async -> Int {
    await importMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: true,
      announcesInsertions: false
    )
  }

  private func importMissingDraftsFromLocalRepository(
    store: WorkbenchStore,
    privateDraftsOnly: Bool,
    announcesInsertions: Bool
  ) async -> Int {
    let profile = store.activeProfile
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      return 0
    }

    guard localImportOperationContext == nil else {
      return 0
    }
    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    let existingRepositoryPaths = automaticImportExcludedRepositoryPaths(profileID: profile.id)
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importMissingDraftsAsync(
        profile: profile,
        excludingRepositoryPaths: existingRepositoryPaths
      )
    } catch is CancellationError {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return 0
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      if announcesInsertions {
        setPublishActionMessage(error.localizedDescription, status: .failure)
      }
      return 0
    }
    guard localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile)
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return 0
    }
    localImportOperationContext = nil
    let hydratedResult = hydrateLocalRepositoryBaselines(
      result,
      profile: profile,
      store: store
    )

    var existingPaths = automaticImportExcludedRepositoryPaths(profileID: profile.id)
    let missingDrafts = hydratedResult.importedDrafts.filter { draft in
      guard draft.belongs(toSiteProfileID: profile.id),
        let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
      else {
        return false
      }
      guard !privateDraftsOnly || draft.isPrivate else { return false }
      return existingPaths.insert(repositoryPath).inserted
    }
    guard !missingDrafts.isEmpty else {
      if announcesInsertions, let issue = hydratedResult.issues.first {
        setPublishActionMessage(issue.message, status: .failure)
      }
      return 0
    }

    drafts.append(contentsOf: missingDrafts)
    if let firstImportedDraft = missingDrafts.first {
      _ = focusDraft(firstImportedDraft.id, store: store)
    }
    if automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh()
    }
    if announcesInsertions {
      if let issue = hydratedResult.issues.first {
        setPublishActionMessage(issue.message, status: .warning)
      } else {
        setPublishActionMessage(
          "已发现并加入本地列表 \(missingDrafts.count) 篇外部新文章。",
          status: .success
        )
      }
    }
    store.save()
    return missingDrafts.count
  }

  @discardableResult
  public func importDraftFromLocalRepository(
    repositoryPath: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let imported = hydrateLocalRepositoryBaselines(
      localContentImportService.importDraft(
        profile: store.activeProfile,
        repositoryPath: repositoryPath
      ),
      profile: store.activeProfile,
      store: store
    )
    let summary = mergeImportedDrafts(imported, store: store)
    let normalizedPath = repositoryPath.normalizedRelativePath()
    if let imported = drafts.first(where: {
      $0.belongs(toSiteProfileID: store.activeProfileID) && $0.repositoryPath == normalizedPath
    }) {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    store.save()
    return summary
  }

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

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository(store: WorkbenchStore) async
    -> LocalContentImportMergeSummary
  {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      setPublishActionMessage("选择本地仓库后才能导入文章。", status: .warning)
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    let paths = (store.repositoryReport?.changedFiles ?? [])
      .filter { $0.kind != .deleted }
      .map(\.displayPath)
      .filter { path in
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      }
    store.flushDraftBodyEditorBuffers()
    var baselines: [String: DraftOperationBaseline] = [:]
    for path in paths {
      let normalizedPath = path.normalizedRelativePath()
      guard
        let draft = drafts.first(where: {
          $0.belongs(toSiteProfileID: profile.id) && $0.repositoryPath == normalizedPath
        }),
        let baseline = store.draftOperationBaseline(for: draft.id)
      else { continue }
      baselines[normalizedPath] = baseline
    }
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importDraftsAsync(
        profile: profile,
        repositoryPaths: paths
      )
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        let wasCancelled = error is CancellationError
        setPublishActionMessage(
          wasCancelled
            ? "已取消导入本地文章变更。"
            : "导入本地文章变更失败：\(error.localizedDescription)",
          status: wasCancelled ? .warning : .failure
        )
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
    let hydratedResult = hydrateLocalRepositoryBaselines(
      result,
      profile: profile,
      store: store
    )
    let summary = mergeImportedDrafts(
      hydratedResult,
      expectedBaselinesByRepositoryPath: baselines,
      store: store
    )
    selectedSection = .writing
    if hydratedResult.issues.isEmpty {
      setPublishActionMessage(
        "已从文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。",
        status: .success
      )
    }
    store.save()
    return summary
  }

  @discardableResult
  public func importRemoteChangedArticleDraftsFromRepository(store: WorkbenchStore)
    -> LocalContentImportMergeSummary
  {
    let paths = (store.repositoryReport?.remoteChangedFiles ?? [])
      .map(\.displayPath)
    return importRemoteArticleDraftsFromRepository(repositoryPaths: paths, store: store)
  }

  @discardableResult
  public func importRemoteArticleDraftsFromRepository(
    repositoryPaths: [String],
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    var seenPaths = Set<String>()
    let paths =
      repositoryPaths
      .map { $0.normalizedRelativePath() }
      .filter { path in
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      }
      .filter { seenPaths.insert($0).inserted }
    let result = remoteContentImportResult(paths: paths, profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    selectedSection = .writing
    if let firstPath = paths.first,
      let imported = drafts.first(where: {
        $0.belongs(toSiteProfileID: profile.id)
          && $0.repositoryPath == firstPath.normalizedRelativePath()
      })
    {
      selectedDraftID = imported.id
    }
    setPublishActionMessage(
      "已从远端文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。",
      status: .success
    )
    store.save()
    return summary
  }

  @discardableResult
  public func importRemoteDraftFromRepository(
    repositoryPath: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let result = remoteContentImportResult(paths: [normalizedPath], profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    if let imported = drafts.first(where: {
      $0.belongs(toSiteProfileID: profile.id) && $0.repositoryPath == normalizedPath
    }) {
      selectedDraftID = imported.id
      selectedSection = .writing
    }
    if let snapshot = store.repositoryStore.remoteFileSnapshot(
      profile: profile, repositoryPath: normalizedPath),
      summary.changedCount > 0
    {
      setPublishActionMessage(
        "已从 \(snapshot.refName) 导入远端文章 \(normalizedPath)。",
        status: .success
      )
    } else {
      setPublishActionMessage("未能导入远端文章：\(normalizedPath)。", status: .failure)
    }
    store.save()
    return summary
  }

  /// Imports only remote article changes that can be proven safe. New paths are
  /// accepted, while an existing draft is replaced only when its repository
  /// content still matches the fingerprint recorded by the last import.
  @discardableResult
  public func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    store: WorkbenchStore
  ) -> RemoteArticleAutoImportSummary {
    let profile = store.activeProfile
    let snapshotsByPath = Dictionary(
      snapshots.map { ($0.repositoryPath.normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    var summary = RemoteArticleAutoImportSummary()
    var seenPaths = Set<String>()
    var didMutateDrafts = false

    for file in remoteFiles {
      let path = file.displayPath.normalizedRelativePath()
      guard seenPaths.insert(path).inserted,
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      else {
        continue
      }

      if file.kind == .deleted {
        if confirmExpectedRemoteRepositoryDeletion(
          profileID: profile.id,
          repositoryPath: path
        ) {
          summary.resolvedPaths.append(path)
          didMutateDrafts = true
        } else {
          summary.deletionPaths.append(path)
        }
        continue
      }
      guard file.kind == .added || file.kind == .modified else {
        summary.conflictPaths.append(path)
        continue
      }
      guard !locallyChangedPaths.contains(path) else {
        summary.conflictPaths.append(path)
        continue
      }
      guard let snapshot = snapshotsByPath[path] else {
        summary.failedPaths.append(path)
        continue
      }

      let importResult = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: path,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      guard var remoteDraft = importResult.importedDrafts.first else {
        summary.failedPaths.append(path)
        continue
      }
      let remoteFingerprint = remoteDraft.repositoryContentFingerprint
      let remoteRenderedDigest = remoteDraft.renderedRepositoryContentDigest(profile: profile)
      remoteDraft.repositoryImportFingerprint = remoteFingerprint

      guard
        let existingIndex = drafts.firstIndex(where: {
          $0.belongs(toSiteProfileID: profile.id)
            && $0.repositoryPath?.normalizedRelativePath() == path
        })
      else {
        drafts.append(remoteDraft)
        summary.insertedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = true
        continue
      }

      let existing = drafts[existingIndex]
      let editorBuffer = store.draftBodyEditorBuffer(for: existing.id)
      guard !editorBuffer.isDirty else {
        summary.conflictPaths.append(path)
        continue
      }

      // A site-draft autosave is the first durable signal that the app owns
      // this path locally. Until that write succeeds (or if it failed), the
      // repository scan cannot safely use Git's working-tree status or the
      // content fingerprint to prove that replacing the draft is harmless.
      // Fail closed and leave the path queued for manual review.
      if let saveState = store.siteDraftFileSaveStates[existing.id] {
        switch saveState {
        case .pending, .failed:
          summary.conflictPaths.append(path)
          continue
        case .saved:
          break
        }
      }

      let existingFingerprint = existing.repositoryContentFingerprint
      let existingRenderedDigest = existing.renderedRepositoryContentDigest(profile: profile)
      let normalizedRemoteSHA = snapshot.repositorySHA?.trimmedForPublishing.nilIfEmpty
      if let normalizedRemoteSHA,
        existing.repositorySHA?.trimmedForPublishing == normalizedRemoteSHA
      {
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        continue
      }

      if existingRenderedDigest == remoteRenderedDigest {
        var confirmed = existing
        if let normalizedRemoteSHA {
          confirmed.confirmRepositoryBinding(
            profile: profile,
            repositoryPath: path,
            remoteRevision: normalizedRemoteSHA,
            renderedContentDigest: confirmed.renderedRepositoryContentDigest(profile: profile)
          )
        } else {
          confirmed.repositoryImportFingerprint = remoteFingerprint
        }
        drafts[existingIndex] = confirmed
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = didMutateDrafts || confirmed != existing
        continue
      }

      let localStillMatchesBaseline =
        existing.repositoryBinding?.renderedContentDigest == existingRenderedDigest
        || existing.repositoryImportFingerprint == existingFingerprint
      guard localStillMatchesBaseline else {
        var diverged = existing
        diverged.markRepositorySyncState(.diverged)
        drafts[existingIndex] = diverged
        didMutateDrafts = didMutateDrafts || diverged != existing
        summary.conflictPaths.append(path)
        continue
      }

      remoteDraft.id = existing.id
      remoteDraft.createdAt = existing.createdAt
      recordAutomaticVersionIfNeeded(for: existing)
      remoteDraft.touch()
      drafts[existingIndex] = remoteDraft
      store.synchronizeDraftBodyEditorBuffer(with: remoteDraft)
      summary.updatedCount += 1
      summary.resolvedPaths.append(path)
      didMutateDrafts = true
    }

    if didMutateDrafts {
      if automaticallyRefreshPreflightOnEdit {
        store.schedulePreflightRefresh()
      }
      store.save()
    }
    return summary
  }

  /// Paths owned by active drafts, the recycle bin, or an unfinished cleanup
  /// request are tombstoned for automatic discovery. This prevents a Markdown
  /// file from being re-created as a new draft between recycling and cleanup.
  func automaticImportExcludedRepositoryPaths(profileID: UUID) -> Set<String> {
    let activePaths = drafts.compactMap { draft -> String? in
      guard draft.belongs(toSiteProfileID: profileID) else { return nil }
      return draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
    }
    let recycledPaths = recycledDrafts.compactMap { recycled -> String? in
      guard recycled.draft.belongs(toSiteProfileID: profileID) else { return nil }
      return recycled.draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
    }
    let cleanupPaths = draftRepositoryCleanupRequests.compactMap { request -> String? in
      guard request.siteProfileID == profileID, request.needsAttention else { return nil }
      return request.repositoryPath.normalizedRelativePath().nilIfEmpty
    }
    return Set(activePaths + recycledPaths + cleanupPaths)
  }

  /// Explicitly binds an automatic import to the frozen operation profile.
  /// The importer still requires that profile to be active because its draft
  /// mutation and editor-buffer safeguards are intentionally foreground-only.
  /// A background caller for another site therefore fails closed instead of
  /// importing into whichever site the user currently sees.
  @discardableResult
  public func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    profileID: UUID,
    store: WorkbenchStore
  ) -> RemoteArticleAutoImportSummary {
    guard profileID == store.activeProfileID else {
      return RemoteArticleAutoImportSummary()
    }
    return autoImportRemoteArticleDrafts(
      remoteFiles: remoteFiles,
      snapshots: snapshots,
      locallyChangedPaths: locallyChangedPaths,
      store: store
    )
  }

  private func remoteContentImportResult(
    paths: [String],
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> LocalContentImportResult {
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    for path in paths {
      let normalizedPath = path.normalizedRelativePath()
      guard
        let snapshot = store.repositoryStore.remoteFileSnapshot(
          profile: profile,
          repositoryPath: normalizedPath
        )
      else {
        skippedPaths.append(normalizedPath)
        continue
      }
      let imported = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: normalizedPath,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      importedDrafts.append(contentsOf: imported.importedDrafts)
      skippedPaths.append(contentsOf: imported.skippedPaths)
    }
    return LocalContentImportResult(importedDrafts: importedDrafts, skippedPaths: skippedPaths)
  }

  /// Local files are the working tree, so their first import does not carry
  /// the upstream version that the publish preflight needs for a safe update.
  /// Hydrate that baseline only when the upstream snapshot exists; new local
  /// files remain untracked and continue to require the normal create path.
  private func hydrateLocalRepositoryBaselines(
    _ result: LocalContentImportResult,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> LocalContentImportResult {
    var hydrated = result
    hydrated.importedDrafts = result.importedDrafts.map { draft in
      guard draft.repositorySHA?.trimmedForPublishing.nilIfEmpty == nil,
        let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        let snapshot = store.repositoryStore.remoteFileSnapshot(
          profile: profile,
          repositoryPath: repositoryPath
        ),
        let remoteSHA = snapshot.repositorySHA?.trimmedForPublishing.nilIfEmpty
      else {
        return draft
      }

      var updated = draft
      var renderedDigest = updated.renderedRepositoryContentDigest(profile: profile)
      var remoteImportFingerprint: String?
      if let remoteDraft = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: repositoryPath,
        profile: profile,
        repositorySHA: remoteSHA
      ).importedDrafts.first {
        remoteImportFingerprint = remoteDraft.repositoryContentFingerprint
        renderedDigest = remoteDraft.renderedRepositoryContentDigest(profile: profile)
      }
      updated.confirmRepositoryBinding(
        profile: profile,
        repositoryPath: repositoryPath,
        remoteRevision: remoteSHA,
        renderedContentDigest: renderedDigest
      )
      if let remoteImportFingerprint {
        updated.repositoryImportFingerprint = remoteImportFingerprint
      }
      return updated
    }
    return hydrated
  }

  @discardableResult
  public func createSiteFromStarter(
    _ request: SiteStarterRequest,
    store: WorkbenchStore
  ) async -> SiteStarterResult? {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    setPublishActionMessage(
      CoreL10n.text("正在后台创建 Starter 站点…"),
      status: .inProgress
    )
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      let result = try await siteStarterService.createSiteAsync(request: request)
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        setPublishActionMessage(
          CoreL10n.text(
            "Starter 文件已生成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
          ),
          status: .warning
        )
        return nil
      }
      siteStarterResult = result
      siteStarterImportResult = nil
      siteStarterPushResult = nil
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      drafts.append(result.initialDraft)
      selectedDraftID = result.initialDraft.id
      setPublishActionMessage(
        CoreL10n.format("已创建 Starter 站点：%@。", result.profile.name),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      setPublishActionMessage(
        CoreL10n.format(
          "创建 Starter 站点失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func importExistingSiteFromStarter(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) async -> SiteStarterImportResult? {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    setPublishActionMessage(
      CoreL10n.text("正在后台读取并导入已有站点…"),
      status: .inProgress
    )
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      var result = try await siteStarterService.importExistingSiteAsync(request: request)
      let importedDrafts = try await localContentImportService.importDraftsAsync(
        profile: result.profile)
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        setPublishActionMessage(
          CoreL10n.text(
            "站点读取完成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
          ),
          status: .warning
        )
        return nil
      }
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      let hydratedDrafts = hydrateLocalRepositoryBaselines(
        importedDrafts,
        profile: result.profile,
        store: store
      )
      let importSummary = mergeImportedDrafts(hydratedDrafts, store: store)
      result.importedDraftCount = importSummary.insertedCount
      result.updatedDraftCount = importSummary.updatedCount
      result.skippedPathCount = importSummary.skippedCount
      siteStarterImportResult = result
      siteStarterResult = nil
      siteStarterPushResult = nil
      selectedDraftID = store.visibleDrafts.first?.id
      if let issue = hydratedDrafts.issues.first {
        setPublishActionMessage(
          CoreL10n.format(
            "已添加站点“%@”，但文章读取未完成：%@",
            result.profile.name,
            issue.message
          ),
          status: .warning
        )
      } else {
        setPublishActionMessage(
          CoreL10n.format("已导入已有站点：%@。", result.profile.name),
          status: .success
        )
      }
      store.save()
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      setPublishActionMessage(
        CoreL10n.format(
          "导入已有站点失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func configureStarterSiteOrigin(store: WorkbenchStore) async -> Bool {
    guard var starterResult = siteStarterResult,
      starterResult.profile.id == store.activeProfileID
    else {
      setPublishActionMessage(
        CoreL10n.text(
          "没有可配置远端的 Starter 生成结果，请先创建站点。"
        ),
        status: .warning
      )
      return false
    }
    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return false
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(
      CoreL10n.text("正在配置 Starter 的 origin remote…"),
      status: .inProgress
    )

    do {
      let remoteURL = try await siteStarterService.configureGitHubOriginRemoteAsync(
        profile: profile)
      guard localRepositoryMutationContext == operation,
        operation.stillMatches(store.activeProfile)
      else {
        return false
      }
      starterResult.profile = profile
      starterResult.configuredRemoteURL = remoteURL
      siteStarterResult = starterResult
      setPublishActionMessage(
        CoreL10n.format(
          "已配置 Starter 远端：%@。",
          profile.repositoryDisplayName
        ),
        status: .success
      )
      store.save()
      return true
    } catch {
      guard localRepositoryMutationContext == operation,
        operation.stillMatches(store.activeProfile)
      else {
        return false
      }
      setPublishActionMessage(
        CoreL10n.format(
          "配置 Starter 远端失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return false
    }
  }

  @discardableResult
  public func commitAndPushStarterSite(store: WorkbenchStore) async -> SiteStarterPushResult? {
    guard let starterResult = siteStarterResult else {
      setPublishActionMessage(
        CoreL10n.text(
          "没有可提交的 Starter 生成结果，请先创建站点。"
        ),
        status: .warning
      )
      return nil
    }
    let profile = starterResult.profile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(
      CoreL10n.text("正在提交并推送 Starter…"),
      status: .inProgress
    )
    do {
      let result = try await siteStarterService.commitAndPushStarterSiteAsync(
        profile: profile,
        createdFilePaths: starterResult.createdFilePaths
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      siteStarterPushResult = result
      setPublishActionMessage(
        CoreL10n.format(
          "Starter 已提交并推送：%@。",
          String(result.commitSHA.prefix(8))
        ),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      setPublishActionMessage(
        CoreL10n.format(
          "Starter 提交推送失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func copyDraft(
    _ draftID: UUID,
    toProfileID targetProfileID: UUID,
    store: WorkbenchStore
  ) -> ArticleDraft? {
    let plan = draftOwnershipTransferPlan(
      draftIDs: [draftID],
      operation: .copyToSite,
      targetProfileID: targetProfileID
    )
    guard let result = applyDraftOwnershipTransfer(plan, store: store),
      let copiedID = result.affectedDraftIDs.first
    else {
      return nil
    }
    return drafts.first(where: { $0.id == copiedID })
  }

  private func mergeImportedDrafts(
    _ result: LocalContentImportResult,
    expectedBaselinesByRepositoryPath: [String: DraftOperationBaseline]? = nil,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    let plan = LocalContentImportMergeService().makePlan(
      existingDrafts: drafts,
      result: result,
      canReplace: { draft, repositoryPath in
        guard let expectedBaselinesByRepositoryPath else { return true }
        guard let baseline = expectedBaselinesByRepositoryPath[repositoryPath] else { return false }
        return baseline.draft.id == draft.id
          && store.draftStillMatchesOperationBaseline(baseline)
      },
      canInsert: { repositoryPath in
        expectedBaselinesByRepositoryPath?[repositoryPath] == nil
      }
    )
    plan.replacedDrafts.forEach(recordAutomaticVersionIfNeeded)
    drafts = plan.drafts

    if plan.summary.insertedCount + plan.summary.updatedCount > 0,
      automaticallyRefreshPreflightOnEdit
    {
      store.schedulePreflightRefresh()
    }
    if let issue = result.issues.first {
      let changedCount = plan.summary.insertedCount + plan.summary.updatedCount
      setPublishActionMessage(
        changedCount == 0
          ? CoreL10n.format("导入失败：%@", issue.message)
          : CoreL10n.format(
            "导入未全部完成：已新增 %lld 篇、更新 %lld 篇；%@",
            plan.summary.insertedCount,
            plan.summary.updatedCount,
            issue.message
          ),
        status: changedCount == 0 ? .failure : .warning
      )
    } else if plan.conflictCount > 0 {
      setPublishActionMessage(
        "导入完成：新增 \(plan.summary.insertedCount) 篇、更新 \(plan.summary.updatedCount) 篇；\(plan.conflictCount) 篇在导入期间被本地修改，已保留本地版本。",
        status: .warning
      )
    } else {
      setPublishActionMessage(
        "导入完成：新增 \(plan.summary.insertedCount) 篇、更新 \(plan.summary.updatedCount) 篇、跳过 \(result.skippedPaths.count) 个文件。",
        status: .success
      )
    }
    store.save()
    return plan.summary
  }
}
