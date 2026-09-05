import Foundation
import PublishingGitCore

private struct RemoteRepositoryConflictPackageContext {
  var package: PublishPackage
  var sourcePackages: [PublishPackage]
}

private struct RemoteRepositoryConflictDraftMutationPlan {
  var mergePlan: LocalContentImportMergePlan
  var updatedDraftIDs: [UUID]

  var hasChanges: Bool { !updatedDraftIDs.isEmpty }
}

private struct RemoteRepositoryConflictPayloadSnapshot: Sendable {
  var package: PublishPackage
  var temporaryDirectoryURL: URL?

  func removeTemporaryFiles() {
    guard let temporaryDirectoryURL else { return }
    try? FileManager.default.removeItem(at: temporaryDirectoryURL)
  }
}

extension PublishingStore {
  @discardableResult
  public func resolveRemoteRepositoryConflict(
    repositoryPath: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    mergedDocument: String? = nil,
    store: WorkbenchStore
  ) async -> RemoteRepositoryConflictResolutionOutcome {
    guard let session = remoteRepositoryConflictSession,
      session.conflicts.count == 1
    else {
      let message = CoreL10n.text("必须先协调全部冲突文件，再统一应用；未执行任何写入。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message: message)
    }
    return await resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          RemoteRepositoryConflictResolutionDecision(
            repositoryPath: repositoryPath,
            choice: choice,
            mergedDocument: mergedDocument
          )
        ]
      ),
      store: store
    )
  }

  @discardableResult
  public func resolveRemoteRepositoryConflicts(
    plan: RemoteRepositoryConflictResolutionPlan,
    store: WorkbenchStore
  ) async -> RemoteRepositoryConflictResolutionOutcome {
    guard let reviewedSession = remoteRepositoryConflictSession,
      reviewedSession.profileID == store.activeProfileID,
      reviewedSession.repositoryIdentity == DraftRepositoryIdentity(profile: store.activeProfile)
    else {
      let message = CoreL10n.text("远端冲突快照已失效，请重新发布以刷新冲突。")
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }
    guard reviewedSession.hasCompleteConflictSnapshot else {
      remoteRepositoryConflictSession = nil
      let message = CoreL10n.format(
        "检测到 %lld 个冲突，超过单次安全协调上限；请缩小发布批次后重试。",
        reviewedSession.totalConflictCount
      )
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }
    guard let decisionsByPath = plan.validatedDecisions(for: reviewedSession) else {
      let message = CoreL10n.text("必须为全部冲突文件提供唯一且有效的处理方式；未执行任何写入。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message: message)
    }
    guard remoteConflictResolutionOperationID == nil,
      remoteRepositoryMutationContext == nil,
      localRepositoryMutationContext == nil,
      !store.isLocalRepositoryBranchOperationRunning,
      !store.isRemoteRepositoryChecking
    else {
      let message = CoreL10n.text("已有仓库操作正在运行，请等待完成后再统一应用冲突协调。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message: message)
    }

    store.flushDraftBodyEditorBuffers()
    guard
      let frozenDraftBaselines = remoteConflictDraftBaselines(
        for: reviewedSession.publishScope,
        store: store
      )
    else {
      let message = CoreL10n.text("发布包已变化，已停止冲突处理；请重新审阅发布清单。")
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }

    let resolutionOperationID = UUID()
    remoteConflictResolutionOperationID = resolutionOperationID
    defer {
      if remoteConflictResolutionOperationID == resolutionOperationID {
        remoteConflictResolutionOperationID = nil
      }
    }
    // A foreground auto-sync can already be suspended in detached Git or
    // snapshot work when the resolver starts.  Invalidate and await those
    // readers while the resolution lock is held so a late import cannot race
    // the frozen draft baselines below.
    await store.repositoryStore.cancelAndAwaitRepositoryBackgroundWorkForSafeSync(store: store)
    guard
      remoteConflictResolutionOperationID == resolutionOperationID,
      let context = await currentRemoteConflictPackageContext(
        for: reviewedSession,
        store: store
      ),
      remoteConflictDraftBaselinesStillMatch(frozenDraftBaselines, store: store)
    else {
      remoteRepositoryConflictSession = nil
      let message = CoreL10n.text("发布包已变化，已停止冲突处理；请重新审阅发布清单。")
      setPublishActionMessage(message, status: .warning)
      return .sessionInvalidated(message: message)
    }

    let profile = store.activeProfile
    let package = context.package
    do {
      let token = try repositoryAccessToken(for: profile)
      let inspection = try await remoteRepositoryPublishService.preflightInspection(
        package: package,
        profile: profile,
        token: token
      )
      var currentSession = try await remoteRepositoryPublishService.conflictResolutionSession(
        inspection: inspection,
        profile: profile,
        token: token
      )
      currentSession.publishScope = reviewedSession.publishScope
      let reviewedPackageStillMatches =
        await remoteConflictPackageFingerprint(
          context.package,
          profile: profile
        ) == reviewedSession.packageFingerprint
      guard
        remoteConflictResolutionOperationID == resolutionOperationID,
        reviewedSession.profileID == store.activeProfileID,
        reviewedSession.repositoryIdentity == DraftRepositoryIdentity(profile: store.activeProfile),
        remoteConflictDraftBaselinesStillMatch(frozenDraftBaselines, store: store),
        reviewedPackageStillMatches
      else {
        remoteRepositoryConflictSession = nil
        let message = CoreL10n.text("本地草稿在协调期间已变化，未覆盖新编辑；请重新发布。")
        setPublishActionMessage(message, status: .warning)
        return .sessionInvalidated(message: message)
      }
      guard remoteConflictSnapshotsMatch(
        reviewed: reviewedSession,
        current: currentSession,
        inspection: inspection
      ) else {
        remoteRepositoryConflictSession = currentSession.isEmpty ? nil : currentSession
        let message =
          currentSession.isEmpty
          ? CoreL10n.text("远端内容已变化且当前冲突不再存在，请重新审阅发布清单。")
          : CoreL10n.text("远端内容在冲突处理期间发生变化，已刷新三方对比；未执行写入。")
        setPublishActionMessage(message, status: .warning)
        return currentSession.isEmpty
          ? .sessionInvalidated(message: message)
          : .sessionRefreshed(message: message)
      }

      guard
        let mutationPlan = makeRemoteConflictDraftMutationPlan(
          session: currentSession,
          decisionsByPath: decisionsByPath,
          packages: context.sourcePackages,
          profile: profile,
          frozenDraftBaselines: frozenDraftBaselines,
          store: store
        )
      else {
        let message = CoreL10n.text("至少一个协调结果无法安全转换为草稿；整批未修改，也未写入远端。")
        setPublishActionMessage(message, status: .warning)
        return .failed(message: message)
      }

      guard
        let resolvedPackage = resolvedRemoteConflictPublishPackage(
          frozenPackage: context.package,
          session: currentSession,
          decisionsByPath: decisionsByPath
        )
      else {
        let message = CoreL10n.text("协调结果改变了未审阅的文件范围；整批未修改，也未写入远端。")
        setPublishActionMessage(message, status: .warning)
        return .failed(message: message)
      }

      let requiresReviewRequest = decisionsByPath.values.contains { decision in
        decision.choice == .keepLocal || decision.choice == .merge
      }
      guard requiresReviewRequest else {
        let packageStillMatches =
          await remoteConflictPackageFingerprint(
            context.package,
            profile: profile
          ) == reviewedSession.packageFingerprint
        guard
          reviewedSession.profileID == store.activeProfileID,
          reviewedSession.repositoryIdentity
            == DraftRepositoryIdentity(profile: store.activeProfile),
          remoteConflictDraftBaselinesStillMatch(frozenDraftBaselines, store: store),
          packageStillMatches
        else {
          remoteRepositoryConflictSession = nil
          let message = CoreL10n.text("本地草稿在协调期间已变化，未覆盖新编辑；请重新发布。")
          setPublishActionMessage(message, status: .warning)
          return .sessionInvalidated(message: message)
        }
        applyRemoteConflictDraftMutationPlan(mutationPlan, store: store)
        remoteRepositoryConflictSession = nil
        await refreshRemoteConflictScope(
          reviewedSession.publishScope,
          store: store
        )
        let message = CoreL10n.format(
          "已统一采用 %lld 个远端版本；没有写入远端。",
          mutationPlan.updatedDraftIDs.count
        )
        setPublishActionMessage(message, status: .success)
        return .completed(message: message)
      }

      let payloadSnapshot: RemoteRepositoryConflictPayloadSnapshot
      let resolvedPayloadFingerprint = await remoteConflictPackageFingerprint(
        resolvedPackage,
        profile: profile
      )
      do {
        payloadSnapshot = try await freezeRemoteConflictPayloads(in: resolvedPackage)
      } catch {
        let message = CoreL10n.format("无法冻结已审阅的媒体文件：%@", error.localizedDescription)
        setPublishActionMessage(message, status: .warning)
        return .failed(message: message)
      }
      defer { payloadSnapshot.removeTemporaryFiles() }
      let frozenPayloadMatches =
        await remoteConflictPackageFingerprint(
          payloadSnapshot.package,
          profile: profile
        ) == resolvedPayloadFingerprint
      guard
        frozenPayloadMatches
      else {
        let message = CoreL10n.text("媒体文件在冻结期间发生变化，未写入远端。")
        setPublishActionMessage(message, status: .warning)
        return .failed(message: message)
      }

      let publishResult = await publishConflictScopeThroughReviewRequest(
        reviewedSession.publishScope,
        package: payloadSnapshot.package,
        conflictResolutionOperationID: resolutionOperationID,
        validationBeforeRemoteMutation: {
          guard self.remoteConflictResolutionOperationID == resolutionOperationID,
            reviewedSession.profileID == store.activeProfileID,
            reviewedSession.repositoryIdentity
              == DraftRepositoryIdentity(profile: store.activeProfile),
            self.remoteConflictDraftBaselinesStillMatch(
              frozenDraftBaselines,
              store: store
            )
          else { return false }
          let packageStillMatches =
            await self.remoteConflictPackageFingerprint(
              context.package,
              profile: profile
            ) == reviewedSession.packageFingerprint
          return packageStillMatches
            && self.remoteConflictResolutionOperationID == resolutionOperationID
            && reviewedSession.profileID == store.activeProfileID
            && reviewedSession.repositoryIdentity
              == DraftRepositoryIdentity(profile: store.activeProfile)
            && self.remoteConflictDraftBaselinesStillMatch(
              frozenDraftBaselines,
              store: store
            )
        },
        store: store
      )
      guard let publishResult else {
        let stillTargetsReviewedRepository =
          reviewedSession.profileID == store.activeProfileID
          && reviewedSession.repositoryIdentity
            == DraftRepositoryIdentity(profile: store.activeProfile)
        remoteRepositoryConflictSession = stillTargetsReviewedRepository ? reviewedSession : nil
        let message =
          publishActionFeedback?.message
          ?? CoreL10n.text("发布检查或 PR/MR 创建失败。")
        return stillTargetsReviewedRepository
          ? .failed(message: message)
          : .sessionInvalidated(message: message)
      }

      remoteRepositoryConflictSession = nil
      guard reviewedSession.profileID == store.activeProfileID,
        reviewedSession.repositoryIdentity == DraftRepositoryIdentity(profile: store.activeProfile),
        remoteConflictDraftBaselinesStillMatch(frozenDraftBaselines, store: store)
      else {
        let message = CoreL10n.text(
          "PR/MR 已创建，但本地草稿在执行期间已变化；已保留新编辑，请重新同步。"
        )
        setPublishActionMessage(message, status: .warning)
        return .completed(message: message)
      }

      applyRemoteConflictDraftMutationPlan(mutationPlan, store: store)
      if publishResult.reviewURL != nil {
        markRemotePublishReviewSuccess(packages: context.sourcePackages)
      }
      store.save()
      let message =
        publishResult.reviewURL == nil
        ? CoreL10n.text("全部冲突已统一应用；远端已是目标内容，无需新建 PR/MR。")
        : CoreL10n.text("全部冲突已统一应用，PR/MR 已准备，等待合并后进入部署。")
      setPublishActionMessage(message, status: .success)
      return .completed(message: message)
    } catch {
      let message = CoreL10n.format("刷新远端冲突失败：%@", error.localizedDescription)
      setPublishActionMessage(message, status: .failure)
      return .failed(message: message)
    }
  }

  private func remoteConflictSnapshotsMatch(
    reviewed: RemoteRepositoryConflictSession,
    current: RemoteRepositoryConflictSession,
    inspection: RemoteRepositoryPreflightInspection
  ) -> Bool {
    let fullConflictPaths = inspection.result.conflicts.map {
      $0.repositoryPath.normalizedRelativePath()
    }
    guard fullConflictPaths.count == reviewed.totalConflictCount,
      Set(fullConflictPaths).count == fullConflictPaths.count,
      current.totalConflictCount == fullConflictPaths.count,
      current.hasCompleteConflictSnapshot
    else { return false }

    let reviewedByPath = Dictionary(
      reviewed.conflicts.map { ($0.repositoryPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let currentByPath = Dictionary(
      current.conflicts.map { ($0.repositoryPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard reviewedByPath.count == reviewed.conflicts.count,
      currentByPath.count == current.conflicts.count,
      Set(fullConflictPaths) == Set(reviewedByPath.keys),
      Set(fullConflictPaths) == Set(currentByPath.keys)
    else { return false }
    return reviewedByPath.allSatisfy { path, reviewedItem in
      currentByPath[path] == reviewedItem
    }
  }

  private func makeRemoteConflictDraftMutationPlan(
    session: RemoteRepositoryConflictSession,
    decisionsByPath: [String: RemoteRepositoryConflictResolutionDecision],
    packages: [PublishPackage],
    profile: SiteProfile,
    frozenDraftBaselines: [UUID: DraftOperationBaseline],
    store: WorkbenchStore
  ) -> RemoteRepositoryConflictDraftMutationPlan? {
    let itemsByPath = Dictionary(
      session.conflicts.map { ($0.repositoryPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var importedDrafts: [ArticleDraft] = []
    var baselinesByPath: [String: DraftOperationBaseline] = [:]
    var updatedDraftIDs: [UUID] = []
    var seenDraftIDs = Set<UUID>()

    for item in session.conflicts {
      guard let decision = decisionsByPath[item.repositoryPath],
        decision.isValid(for: item)
      else { return nil }
      guard decision.choice != .keepLocal else { continue }
      guard let remoteDocument = item.remote.text,
        let actualSHA = item.actualSHA,
        let package = packages.first(where: {
          $0.markdownPath.normalizedRelativePath() == item.repositoryPath
        }),
        seenDraftIDs.insert(package.draftID).inserted,
        let baseline = frozenDraftBaselines[package.draftID],
        store.draftStillMatchesOperationBaseline(baseline)
      else { return nil }

      let finalDocument: String
      switch decision.choice {
      case .useRemote:
        finalDocument = remoteDocument
      case .merge:
        guard let mergedDocument = decision.mergedDocument else { return nil }
        finalDocument = mergedDocument
      case .keepLocal:
        return nil
      }
      let imported = localContentImportService.importDraft(
        document: finalDocument,
        repositoryPath: item.repositoryPath,
        profile: profile,
        repositorySHA: actualSHA
      )
      guard imported.importedDrafts.count == 1,
        imported.skippedPaths.isEmpty,
        imported.issues.isEmpty,
        var resolvedDraft = imported.importedDrafts.first
      else { return nil }
      let keepLocalAttachmentPaths = Set(
        decisionsByPath.values.compactMap { decision in
          decision.choice == .keepLocal ? decision.repositoryPath : nil
        }
      )
      for attachment in baseline.draft.attachments where
        keepLocalAttachmentPaths.contains(attachment.repositoryPath.normalizedRelativePath())
      {
        if let index = resolvedDraft.attachments.firstIndex(where: {
          $0.repositoryPath.normalizedRelativePath()
            == attachment.repositoryPath.normalizedRelativePath()
        }) {
          resolvedDraft.attachments[index] = attachment
        } else {
          resolvedDraft.attachments.append(attachment)
        }
      }
      if let coverID = baseline.draft.coverAttachmentID,
        let cover = baseline.draft.attachments.first(where: { $0.id == coverID }),
        keepLocalAttachmentPaths.contains(cover.repositoryPath.normalizedRelativePath())
      {
        resolvedDraft.coverAttachmentID = coverID
      }
      let localDocument =
        publishPackageBuilder.build(draft: resolvedDraft, profile: profile)
        .markdownFile?.content ?? finalDocument
      resolvedDraft.adoptReviewedRemoteBaseline(
        profile: profile,
        repositoryPath: item.repositoryPath,
        remoteRevision: actualSHA,
        remoteDocument: remoteDocument,
        localDocument: localDocument
      )
      importedDrafts.append(resolvedDraft)
      baselinesByPath[item.repositoryPath] = baseline
      updatedDraftIDs.append(package.draftID)
    }

    guard itemsByPath.count == session.conflicts.count else { return nil }
    let mergePlan = LocalContentImportMergeService().makePlan(
      existingDrafts: drafts,
      result: LocalContentImportResult(
        importedDrafts: importedDrafts,
        skippedPaths: []
      ),
      canReplace: { draft, repositoryPath in
        guard let baseline = baselinesByPath[repositoryPath] else { return false }
        return baseline.draft.id == draft.id
          && store.draftStillMatchesOperationBaseline(baseline)
      },
      canInsert: { _ in false }
    )
    guard mergePlan.summary.insertedCount == 0,
      mergePlan.summary.updatedCount == importedDrafts.count,
      mergePlan.summary.skippedCount == 0,
      mergePlan.conflictCount == 0,
      mergePlan.replacedDrafts.count == importedDrafts.count
    else { return nil }
    return RemoteRepositoryConflictDraftMutationPlan(
      mergePlan: mergePlan,
      updatedDraftIDs: updatedDraftIDs
    )
  }

  func resolvedRemoteConflictPublishPackage(
    frozenPackage: PublishPackage,
    session: RemoteRepositoryConflictSession,
    decisionsByPath: [String: RemoteRepositoryConflictResolutionDecision]
  ) -> PublishPackage? {
    struct FileKey: Hashable {
      var path: String
      var kind: PublishFileKind
      var operation: PublishFileOperation
    }

    let originalKeys = frozenPackage.files.map {
      FileKey(
        path: $0.repositoryPath.normalizedRelativePath(),
        kind: $0.kind,
        operation: $0.operation
      )
    }
    guard Set(originalKeys).count == originalKeys.count else { return nil }
    let itemsByPath = Dictionary(
      session.conflicts.map { ($0.repositoryPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard itemsByPath.count == session.conflicts.count,
      Set(decisionsByPath.keys) == Set(itemsByPath.keys)
    else { return nil }

    var resolved = frozenPackage
    for index in resolved.files.indices {
      let path = resolved.files[index].repositoryPath.normalizedRelativePath()
      guard let item = itemsByPath[path] else { continue }
      guard let decision = decisionsByPath[path], decision.isValid(for: item) else {
        return nil
      }
      guard resolved.files[index].kind == item.fileKind,
        resolved.files[index].operation == item.operation
      else { return nil }

      switch decision.choice {
      case .keepLocal:
        break
      case .useRemote:
        guard item.fileKind == .markdown,
          item.operation == .upsert,
          let document = item.remote.text
        else { return nil }
        resolved.files[index].content = document
        resolved.files[index].sourceFilePath = nil
        resolved.files[index].byteSize = Int64(document.utf8.count)
        resolved.files[index].expectedRemoteSHA = item.actualSHA
        resolved.files[index].expectedContentSHA256 = nil
        resolved.files[index].expectedGitBlobSHA = nil
      case .merge:
        guard item.fileKind == .markdown,
          item.operation == .upsert,
          let document = decision.mergedDocument
        else { return nil }
        resolved.files[index].content = document
        resolved.files[index].sourceFilePath = nil
        resolved.files[index].byteSize = Int64(document.utf8.count)
        resolved.files[index].expectedRemoteSHA = item.actualSHA
        resolved.files[index].expectedContentSHA256 = nil
        resolved.files[index].expectedGitBlobSHA = nil
      }
    }

    let resolvedKeys = resolved.files.map {
      FileKey(
        path: $0.repositoryPath.normalizedRelativePath(),
        kind: $0.kind,
        operation: $0.operation
      )
    }
    guard resolvedKeys == originalKeys,
      Set(itemsByPath.keys).isSubset(of: Set(resolvedKeys.map(\.path)))
    else { return nil }
    return resolved
  }

  private func applyRemoteConflictDraftMutationPlan(
    _ plan: RemoteRepositoryConflictDraftMutationPlan,
    store: WorkbenchStore
  ) {
    guard plan.hasChanges else { return }
    plan.mergePlan.replacedDrafts.forEach(recordAutomaticVersionIfNeeded)
    drafts = plan.mergePlan.drafts
    for draftID in plan.updatedDraftIDs {
      guard let updated = drafts.first(where: { $0.id == draftID }) else { continue }
      store.synchronizeDraftBodyEditorBuffer(with: updated)
    }
    if let firstUpdatedDraftID = plan.updatedDraftIDs.first {
      selectedDraftID = firstUpdatedDraftID
      selectedSection = .writing
    }
    if automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh()
    }
    store.save()
  }

  private func currentRemoteConflictPackageContext(
    for session: RemoteRepositoryConflictSession,
    store: WorkbenchStore
  ) async -> RemoteRepositoryConflictPackageContext? {
    switch session.publishScope {
    case .selectedDraft(let draftID):
      _ = await store.refreshPublishPreview(for: draftID)
      guard let draft = drafts.first(where: { $0.id == draftID }),
        draft.belongs(toSiteProfileID: store.activeProfileID)
      else { return nil }
      let package = publishingPackage(for: draft, store: store)
      let fingerprint = await remoteConflictPackageFingerprint(
        package,
        profile: store.activeProfile
      )
      guard fingerprint == session.packageFingerprint else {
        return nil
      }
      return RemoteRepositoryConflictPackageContext(
        package: package,
        sourcePackages: [package]
      )

    case .batch(let reviewedDraftIDs):
      await store.refreshBatchPublishPlanAsync()
      guard let plan = batchPublishPlan,
        plan.remotePublishableItems.map(\.draftID) == reviewedDraftIDs,
        let package = remotePublishPackage(for: plan)
      else { return nil }
      let fingerprint = await remoteConflictPackageFingerprint(
        package,
        profile: store.activeProfile
      )
      guard fingerprint == session.packageFingerprint else { return nil }
      return RemoteRepositoryConflictPackageContext(
        package: package,
        sourcePackages: plan.remotePublishableItems.map(\.package)
      )
    }
  }

  private func refreshRemoteConflictScope(
    _ scope: RemoteRepositoryConflictPublishScope,
    store: WorkbenchStore
  ) async {
    switch scope {
    case .selectedDraft(let draftID):
      _ = await store.refreshPublishPreview(for: draftID)
    case .batch:
      await store.refreshBatchPublishPlanAsync()
    }
  }

  private func publishConflictScopeThroughReviewRequest(
    _ scope: RemoteRepositoryConflictPublishScope,
    package: PublishPackage,
    conflictResolutionOperationID: UUID,
    validationBeforeRemoteMutation: @escaping @MainActor () async -> Bool,
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    switch scope {
    case .selectedDraft(let draftID):
      guard package.draftID == draftID,
        drafts.contains(where: {
          $0.id == draftID && $0.belongs(toSiteProfileID: store.activeProfileID)
        })
      else {
        setPublishActionMessage(
          CoreL10n.text("没有可创建 PR/MR 的单篇发布包。"),
          status: .warning
        )
        return nil
      }
      let profile = store.activeProfile
      return await publishSelectedDraftOnline(
        package: package,
        profile: profile,
        mode: .reviewRequest,
        conflictResolutionOperationID: conflictResolutionOperationID,
        skipDraftMaterialization: true,
        deferDraftLifecycleMutation: true,
        validationBeforeRemoteMutation: validationBeforeRemoteMutation,
        store: store
      )

    case .batch(let reviewedDraftIDs):
      await store.refreshBatchPublishPlanAsync()
      guard let plan = batchPublishPlan,
        plan.remotePublishableItems.map(\.draftID) == reviewedDraftIDs
      else {
        setPublishActionMessage(CoreL10n.text("没有可创建 PR/MR 的发布包。"), status: .warning)
        return nil
      }
      let profile = store.activeProfile
      let preview = remoteRepositoryPublishPreview(
        package: package,
        profile: profile,
        mode: .reviewRequest,
        extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
        store: store
      )
      return await performBatchReadyDraftsOnlineUsingPreferredStrategy(
        store: store,
        expectedChangedPaths: Set(preview.changedPaths),
        expectedTarget: RemoteRepositoryPublishTargetSnapshot(
          profile: profile,
          preview: preview
        ),
        expectedReview: BatchPublishReviewExpectation(plan: plan, package: package),
        modeOverride: .reviewRequest,
        conflictResolutionOperationID: conflictResolutionOperationID,
        exactPackageOverride: package,
        skipDraftMaterialization: true,
        deferDraftLifecycleMutation: true,
        validationBeforeRemoteMutation: validationBeforeRemoteMutation
      )
    }
  }

  private func remoteConflictDraftBaselines(
    for scope: RemoteRepositoryConflictPublishScope,
    store: WorkbenchStore
  ) -> [UUID: DraftOperationBaseline]? {
    let draftIDs = scope.draftIDs
    guard !draftIDs.isEmpty, Set(draftIDs).count == draftIDs.count else { return nil }
    var baselines: [UUID: DraftOperationBaseline] = [:]
    for draftID in draftIDs {
      guard let baseline = store.draftOperationBaseline(for: draftID) else { return nil }
      baselines[draftID] = baseline
    }
    return baselines
  }

  private func remoteConflictDraftBaselinesStillMatch(
    _ baselines: [UUID: DraftOperationBaseline],
    store: WorkbenchStore
  ) -> Bool {
    !baselines.isEmpty && baselines.values.allSatisfy(store.draftStillMatchesOperationBaseline)
  }

  private func freezeRemoteConflictPayloads(
    in package: PublishPackage
  ) async throws -> RemoteRepositoryConflictPayloadSnapshot {
    try await Task.detached(priority: .userInitiated) {
      var frozen = package
      let mediaIndexes = frozen.files.indices.filter {
        frozen.files[$0].operation == .upsert && frozen.files[$0].kind != .markdown
      }
      guard !mediaIndexes.isEmpty else {
        return RemoteRepositoryConflictPayloadSnapshot(
          package: frozen,
          temporaryDirectoryURL: nil
        )
      }

      let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RepoPress-RemoteConflict-\(UUID().uuidString)",
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        for index in mediaIndexes {
          guard let sourcePath = frozen.files[index].sourceFilePath else {
            throw RemoteRepositoryPublishError.missingSourceFile(
              frozen.files[index].repositoryPath
            )
          }
          let data = try BoundedFileReader.data(
            at: URL(fileURLWithPath: sourcePath),
            maximumByteCount: WorkbenchFileReadLimits.maximumRemoteMediaUploadByteCount
          )
          let snapshotURL = directoryURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: false
          )
          try data.write(to: snapshotURL, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
          )
          frozen.files[index].sourceFilePath = snapshotURL.path
          frozen.files[index].byteSize = Int64(data.count)
        }
        return RemoteRepositoryConflictPayloadSnapshot(
          package: frozen,
          temporaryDirectoryURL: directoryURL
        )
      } catch {
        try? FileManager.default.removeItem(at: directoryURL)
        throw error
      }
    }.value
  }

  private func remoteConflictPackageFingerprint(
    _ package: PublishPackage,
    profile: SiteProfile
  ) async -> String {
    let service = remoteRepositoryPublishService
    return await Task.detached(priority: .userInitiated) {
      service.conflictPackageFingerprint(package: package, profile: profile)
    }.value
  }
}
