import CryptoKit
import Foundation

/// Pure work used by repository imports after the operation has captured its
/// profile and remote snapshots. Keeping this value-only helper outside the
/// main-actor store prevents Markdown/front-matter parsing from accidentally
/// inheriting the actor through a closure capture.
struct LocalRepositoryImportBackgroundWork: Sendable {
  static func repositoryPathsRequiringBaseline(
    from importedDrafts: [ArticleDraft]
  ) -> [String] {
    var seenPaths = Set<String>()
    return importedDrafts.compactMap { draft in
      guard draft.repositorySHA?.trimmedForPublishing.nilIfEmpty == nil,
        let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        seenPaths.insert(repositoryPath).inserted
      else {
        return nil
      }
      return repositoryPath
    }
  }

  static func hydrateLocalRepositoryBaselines(
    _ result: LocalContentImportResult,
    profile: SiteProfile,
    snapshots: [RepositoryFileSnapshot],
    importService: LocalContentImportService
  ) -> LocalContentImportResult {
    var hydrated = result
    let snapshotsByPath = Dictionary(
      snapshots.map { ($0.repositoryPath.normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    hydrated.importedDrafts = result.importedDrafts.map { draft in
      guard draft.repositorySHA?.trimmedForPublishing.nilIfEmpty == nil,
        let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
        let snapshot = snapshotsByPath[repositoryPath],
        let remoteSHA = snapshot.repositorySHA?.trimmedForPublishing.nilIfEmpty
      else {
        return draft
      }

      var updated = draft
      let renderedDigest = updated.renderedRepositoryContentDigest(profile: profile)
      let renderedDocument = FrontMatterRenderer().renderDocument(draft: updated, profile: profile)

      // LocalRepositoryService obtains this revision from Git's blob object.
      // Compare it with the blob identity of the exact bytes the draft will
      // publish. This remains exact even though the command runner trims text
      // output used for parsing `snapshot.content`.
      guard gitBlobSHA(for: renderedDocument) == remoteSHA.lowercased()
      else {
        return draft
      }

      let remoteImport = importService.importDraft(
        document: snapshot.content,
        repositoryPath: repositoryPath,
        profile: profile,
        repositorySHA: remoteSHA
      )
      guard remoteImport.issues.isEmpty,
        let remoteDraft = remoteImport.importedDrafts.first,
        remoteDraft.renderedRepositoryContentDigest(profile: profile) == renderedDigest
      else {
        return draft
      }

      updated.confirmRepositoryBinding(
        profile: profile,
        repositoryPath: repositoryPath,
        remoteRevision: remoteSHA,
        renderedContentDigest: renderedDigest
      )
      updated.repositoryImportFingerprint = remoteDraft.repositoryContentFingerprint
      return updated
    }
    return hydrated
  }

  private static func gitBlobSHA(for document: String) -> String {
    let data = Data(document.utf8)
    var blob = Data("blob \(data.count)\0".utf8)
    blob.append(data)
    return Insecure.SHA1.hash(data: blob)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func makeRemoteContentImportResult(
    paths: [String],
    snapshots: [RepositoryFileSnapshot],
    profile: SiteProfile,
    importService: LocalContentImportService
  ) -> LocalContentImportResult {
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    var issues: [LocalContentImportIssue] = []
    let snapshotsByPath = Dictionary(
      snapshots.map { ($0.repositoryPath.normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    for path in paths {
      let normalizedPath = path.normalizedRelativePath()
      guard let snapshot = snapshotsByPath[normalizedPath] else {
        skippedPaths.append(normalizedPath)
        continue
      }
      let imported = importService.importDraft(
        document: snapshot.content,
        repositoryPath: normalizedPath,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      importedDrafts.append(contentsOf: imported.importedDrafts)
      skippedPaths.append(contentsOf: imported.skippedPaths)
      issues.append(contentsOf: imported.issues)
    }
    return LocalContentImportResult(
      importedDrafts: importedDrafts,
      skippedPaths: skippedPaths,
      issues: issues
    )
  }
}

extension PublishingStore {
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

  /// Local files are the working tree, so their first import does not carry
  /// the upstream version that the publish preflight needs for a safe update.
  /// Hydrate that baseline only when the upstream snapshot exists; new local
  /// files remain untracked and continue to require the normal create path.
  func hydrateLocalRepositoryBaselines(
    _ result: LocalContentImportResult,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> LocalContentImportResult {
    let paths = LocalRepositoryImportBackgroundWork.repositoryPathsRequiringBaseline(
      from: result.importedDrafts
    )
    let snapshots = paths.compactMap { repositoryPath in
      store.repositoryStore.remoteFileSnapshot(
        profile: profile,
        repositoryPath: repositoryPath
      )
    }
    return LocalRepositoryImportBackgroundWork.hydrateLocalRepositoryBaselines(
      result,
      profile: profile,
      snapshots: snapshots,
      importService: localContentImportService
    )
  }

  /// Fetches all upstream baselines with one detached batch operation and
  /// performs the remote Markdown parse/render work in a second detached
  /// operation. Only the guarded result crosses back to the main actor.
  func hydrateLocalRepositoryBaselinesAsync(
    _ result: LocalContentImportResult,
    profile: SiteProfile,
    store: WorkbenchStore
  ) async -> LocalContentImportResult? {
    guard !Task.isCancelled else { return nil }
    let paths = LocalRepositoryImportBackgroundWork.repositoryPathsRequiringBaseline(
      from: result.importedDrafts
    )
    guard !paths.isEmpty else { return result }
    let snapshots = await store.repositoryStore.remoteFileSnapshotsAsync(
      profile: profile,
      repositoryPaths: paths
    )
    guard !Task.isCancelled else { return nil }
    let importService = localContentImportService
    let work = Task.detached(priority: .utility) {
      LocalRepositoryImportBackgroundWork.hydrateLocalRepositoryBaselines(
        result,
        profile: profile,
        snapshots: snapshots,
        importService: importService
      )
    }
    let hydrated = await withTaskCancellationHandler(operation: {
      await work.value
    }, onCancel: {
      work.cancel()
    })
    guard !Task.isCancelled else { return nil }
    return hydrated
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

  func mergeImportedDrafts(
    _ result: LocalContentImportResult,
    expectedBaselinesByRepositoryPath: [String: DraftOperationBaseline]? = nil,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    mergeImportedDraftsOperation(
      result,
      expectedBaselinesByRepositoryPath: expectedBaselinesByRepositoryPath,
      store: store
    ).summary
  }

  func mergeImportedDraftsOperation(
    _ result: LocalContentImportResult,
    expectedBaselinesByRepositoryPath: [String: DraftOperationBaseline]? = nil,
    store: WorkbenchStore
  ) -> LocalContentImportOperationResult {
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
    let outcome: WorkbenchOperationLogOutcome
    if let issue = result.issues.first {
      let changedCount = plan.summary.insertedCount + plan.summary.updatedCount
      outcome = changedCount == 0 ? .failed : .partial
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
      outcome = .partial
      setPublishActionMessage(
        "导入完成：新增 \(plan.summary.insertedCount) 篇、更新 \(plan.summary.updatedCount) 篇；\(plan.conflictCount) 篇在导入期间被本地修改，已保留本地版本。",
        status: .warning
      )
    } else {
      outcome = plan.summary.changedCount > 0 ? .succeeded : .recorded
      setPublishActionMessage(
        "导入完成：新增 \(plan.summary.insertedCount) 篇、更新 \(plan.summary.updatedCount) 篇、跳过 \(result.skippedPaths.count) 个文件。",
        status: .success
      )
    }
    store.save()
    return LocalContentImportOperationResult(summary: plan.summary, outcome: outcome)
  }
}
