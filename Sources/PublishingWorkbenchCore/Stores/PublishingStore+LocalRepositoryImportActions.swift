import Foundation

extension PublishingStore {

  func importDraftsFromLocalRepositoryAsyncOperation(
    store: WorkbenchStore
  ) async -> LocalContentImportOperationResult {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      setPublishActionMessage("选择本地仓库后才能导入文章。", status: .warning)
      return .empty(outcome: .recorded)
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
      return .empty(outcome: .cancelled)
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        setPublishActionMessage(
          "导入本地文章失败：\(error.localizedDescription)",
          status: .failure
        )
      }
      return .empty(outcome: .failed)
    }
    guard localImportOperationContext == operation else {
      return .empty(outcome: .cancelled)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return .empty(outcome: .cancelled)
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
      return .empty(outcome: .cancelled)
    }
    guard localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile)
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return .empty(outcome: .cancelled)
    }
    localImportOperationContext = nil
    return mergeImportedDraftsOperation(
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
    await importMissingDraftsFromLocalRepositoryOperation(store: store).summary.insertedCount
  }

  func importMissingDraftsFromLocalRepositoryOperation(
    store: WorkbenchStore,
    focusImportedDraft: Bool = true,
    expectedProfile: SiteProfile? = nil
  ) async -> LocalContentImportOperationResult {
    await discoverMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: false,
      announcesInsertions: true,
      repositoryPaths: nil,
      focusImportedDraft: focusImportedDraft,
      expectedProfile: expectedProfile
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
    await discoverMissingDraftsFromLocalRepository(
      store: store,
      privateDraftsOnly: false,
      announcesInsertions: false,
      repositoryPaths: repositoryPaths
    ).summary.insertedCount
  }

  private func discoverMissingDraftsFromLocalRepository(
    store: WorkbenchStore,
    privateDraftsOnly: Bool,
    announcesInsertions: Bool,
    repositoryPaths: [String]?,
    focusImportedDraft: Bool = true,
    expectedProfile: SiteProfile? = nil
  ) async -> LocalContentImportOperationResult {
    let profile = store.activeProfile
    guard !Task.isCancelled, expectedProfile == nil || expectedProfile == profile else {
      return .empty(outcome: .cancelled)
    }
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      return .empty(outcome: .failed)
    }

    guard localImportOperationContext == nil else {
      return .empty(outcome: .cancelled)
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
          return .empty(outcome: .succeeded)
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
      return .empty(outcome: .cancelled)
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      if announcesInsertions {
        setPublishActionMessage(error.localizedDescription, status: .failure)
      }
      return .empty(outcome: .failed)
    }
    guard !Task.isCancelled, localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile),
      expectedProfile == nil || expectedProfile == store.activeProfile
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return .empty(outcome: .cancelled)
    }
    guard
      let hydratedResult = await hydrateLocalRepositoryBaselinesAsync(
        result,
        profile: profile,
        store: store
      )
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return .empty(outcome: .cancelled)
    }
    guard !Task.isCancelled, localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile),
      expectedProfile == nil || expectedProfile == store.activeProfile
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return .empty(outcome: .cancelled)
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
      return .empty(outcome: hydratedResult.issues.isEmpty ? .succeeded : .failed)
    }

    drafts.append(contentsOf: missingDrafts)
    if focusImportedDraft, let firstImportedDraft = missingDrafts.first {
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
    return LocalContentImportOperationResult(
      summary: LocalContentImportMergeSummary(
        insertedCount: missingDrafts.count,
        updatedCount: 0,
        skippedCount: hydratedResult.skippedPaths.count
      ),
      outcome: hydratedResult.issues.isEmpty ? .succeeded : .partial
    )
  }

  func importChangedArticleDraftsFromLocalRepositoryOperation(
    store: WorkbenchStore
  ) async -> LocalContentImportOperationResult {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      setPublishActionMessage("选择本地仓库后才能导入文章。", status: .warning)
      return .empty(outcome: .recorded)
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
      return .empty(outcome: error is CancellationError ? .cancelled : .failed)
    }
    guard localImportOperationContext == operation else {
      return .empty(outcome: .cancelled)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return .empty(outcome: .cancelled)
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
      return .empty(outcome: .cancelled)
    }
    guard localImportOperationContext == operation,
      operation.stillMatches(store.activeProfile)
    else {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
      }
      return .empty(outcome: .cancelled)
    }
    localImportOperationContext = nil
    let operationResult = mergeImportedDraftsOperation(
      hydratedResult,
      expectedBaselinesByRepositoryPath: baselines,
      store: store
    )
    let summary = operationResult.summary
    selectedSection = .writing
    if hydratedResult.issues.isEmpty {
      setPublishActionMessage(
        "已从文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。",
        status: .success
      )
    }
    store.save()
    return operationResult
  }
}
