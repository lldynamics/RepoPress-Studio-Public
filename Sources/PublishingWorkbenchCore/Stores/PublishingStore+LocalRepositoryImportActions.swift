import Foundation

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
    guard let hydratedResult = await hydrateLocalRepositoryBaselinesAsync(
      result,
      profile: profile,
      store: store
    ) else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        setPublishActionMessage("已取消从本地仓库导入文章。", status: .warning)
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile)
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
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
      announcesInsertions: true,
      repositoryPaths: nil
    )
  }

  /// Imports only the Markdown paths reported by a repository content watcher.
  /// Known draft/recycle-bin paths are filtered before parsing, so an editor's
  /// own autosave event does not trigger a full content-tree traversal.
  @discardableResult
  public func importMissingDraftsFromLocalRepository(
    repositoryPaths: [String],
    store: WorkbenchStore
  ) async -> Int {
    await importMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: false,
      announcesInsertions: false,
      repositoryPaths: repositoryPaths
    )
  }

  /// Keeps the narrower private-only migration available for older callers.
  @discardableResult
  public func importMissingPrivateDraftsFromLocalRepository(store: WorkbenchStore) async -> Int {
    await importMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: true,
      announcesInsertions: false,
      repositoryPaths: nil
    )
  }

  private func importMissingDraftsFromLocalRepository(
    store: WorkbenchStore,
    privateDraftsOnly: Bool,
    announcesInsertions: Bool,
    repositoryPaths: [String]?
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
      if let repositoryPaths {
        let candidatePaths = repositoryPaths
          .map { $0.normalizedRelativePath() }
          .filter { path in
            !existingRepositoryPaths.contains(path)
              && localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
          }
        guard !candidatePaths.isEmpty else {
          localImportOperationContext = nil
          return 0
        }
        result = try await localContentImportService.importDraftsAsync(
          profile: profile,
          repositoryPaths: Array(Set(candidatePaths)).sorted()
        )
      } else {
        result = try await localContentImportService.importMissingDraftsAsync(
          profile: profile,
          excludingRepositoryPaths: existingRepositoryPaths
        )
      }
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
    guard let hydratedResult = await hydrateLocalRepositoryBaselinesAsync(
      result,
      profile: profile,
      store: store
    ) else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
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
    guard let hydratedResult = await hydrateLocalRepositoryBaselinesAsync(
      result,
      profile: profile,
      store: store
    ) else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        setPublishActionMessage("已取消导入本地文章变更。", status: .warning)
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile)
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
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
}
