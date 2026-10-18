import Foundation

extension PublishingStore {
  static func batchPublishDateToken() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  @discardableResult
  public func publishBatchReadyDraftsOnlineUsingPreferredStrategy(
    store: WorkbenchStore,
    expectedChangedPaths: Set<String>? = nil,
    expectedTarget: RemoteRepositoryPublishTargetSnapshot? = nil,
    expectedReview: BatchPublishReviewExpectation? = nil,
    authorization: AIPublishAuthorizationSnapshot? = nil,
    modeOverride: RemoteRepositoryPublishMode? = nil
  ) async -> RemoteRepositoryPublishResult? {
    await performBatchReadyDraftsOnlineUsingPreferredStrategy(
      store: store,
      expectedChangedPaths: expectedChangedPaths,
      expectedTarget: expectedTarget,
      expectedReview: expectedReview,
      authorization: authorization,
      modeOverride: modeOverride
    )
  }

  @discardableResult
  func performBatchReadyDraftsOnlineUsingPreferredStrategy(
    store: WorkbenchStore,
    expectedChangedPaths: Set<String>? = nil,
    expectedTarget: RemoteRepositoryPublishTargetSnapshot? = nil,
    expectedReview: BatchPublishReviewExpectation? = nil,
    authorization: AIPublishAuthorizationSnapshot? = nil,
    modeOverride: RemoteRepositoryPublishMode? = nil,
    conflictResolutionOperationID: UUID? = nil,
    exactPackageOverride: PublishPackage? = nil,
    skipDraftMaterialization: Bool = false,
    deferDraftLifecycleMutation: Bool = false,
    validationBeforeRemoteMutation: (@MainActor () async -> Bool)? = nil
  ) async -> RemoteRepositoryPublishResult? {
    guard
      self.remoteConflictResolutionOperationID == nil
        || self.remoteConflictResolutionOperationID == conflictResolutionOperationID
    else {
      setPublishingActionMessage(
        CoreL10n.text("远端冲突协调正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    if let authorization {
      do {
        try AIPublishAuthorizationService.validateTarget(
          authorization,
          profile: store.activeProfile
        )
      } catch {
        setPublishingActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }

    await store.refreshBatchPublishPlanAsync()

    guard var batchPlan = batchPublishPlan else {
      setPublishingActionMessage("没有可线上发布的批量队列。", status: .warning)
      return nil
    }

    // Keep the reviewed candidate set as the authority for what may enter the
    // online queue. Site drafts remain excluded by remotePublishableItems.
    var publishableItems = batchPlan.remotePublishableItems
    guard !publishableItems.isEmpty else {
      setPublishingActionMessage(
        "当前没有可批量发布的文章。待下线请求请在回收站单独处理。",
        status: .warning
      )
      return nil
    }

    var profile = store.activeProfile
    var mode = modeOverride ?? preferredRemoteRepositoryPublishMode(for: profile)
    guard var package = exactPackageOverride ?? remotePublishPackage(for: batchPlan) else {
      setPublishingActionMessage("批量队列没有可上传的文件。", status: .warning)
      return nil
    }
    let reviewedFiles = package.files
    let reviewedDraftIDs = publishableItems.map(\.draftID)

    if let expectedReview, !expectedReview.matches(plan: batchPlan, package: package) {
      setPublishingActionMessage(
        CoreL10n.text("待发布文章或内容已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }

    let initialPreview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: batchPlan),
      store: store
    )
    let reviewedTarget = RemoteRepositoryPublishTargetSnapshot(
      profile: profile,
      preview: initialPreview
    )
    if let expectedTarget,
      expectedTarget != reviewedTarget
    {
      setPublishingActionMessage(
        CoreL10n.text("发布目标已变化，请重新打开确认页核对仓库、分支和发布方式。"),
        status: .warning
      )
      return nil
    }
    if let authorization {
      do {
        try AIPublishAuthorizationService.validate(
          authorization,
          package: package,
          preview: initialPreview,
          profile: profile,
          repositoryReport: store.repositoryReport(for: profile)
        )
      } catch {
        setPublishingActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }
    if let expectedChangedPaths,
      Set(initialPreview.changedPaths) != expectedChangedPaths
    {
      setPublishingActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }
    if let tokenAccessFailureMessage = initialPreview.tokenAccessFailureMessage {
      setPublishingActionMessage(
        CoreL10n.format(
          "仓库 Token 状态读取失败：%@",
          tokenAccessFailureMessage
        ),
        status: .failure
      )
      return nil
    }
    guard initialPreview.hasToken else {
      setPublishingActionMessage(
        "仓库访问 Token 未保存，无法批量线上发布。",
        status: .warning
      )
      return nil
    }
    let initialBlockingIssues = blockingIssuesBeforeAuthoritativeRemotePreflight(initialPreview)
    guard initialBlockingIssues.isEmpty else {
      setPublishingActionMessage(
        blockedLocalPublishMessage(action: "批量线上发布", issues: initialBlockingIssues),
        status: .warning
      )
      return nil
    }

    guard await store.ensureRemoteRepositoryWriteAccess(for: profile) else {
      return nil
    }

    // The read-only check can fill a repository detected from origin and its
    // awaited refresh can observe edits made while the request was in flight.
    // Rebuild the reviewed package from the latest batch state before writing.
    guard let refreshedBatchPlan = self.batchPublishPlan,
      refreshedBatchPlan.profileID == store.activeProfileID
    else {
      setPublishingActionMessage("没有可线上发布的批量队列。", status: .warning)
      return nil
    }
    batchPlan = refreshedBatchPlan
    publishableItems = batchPlan.remotePublishableItems
    guard publishableItems.map(\.draftID) == reviewedDraftIDs else {
      setPublishingActionMessage(
        "待发布文章已变化，请重新打开确认页审阅完整清单。",
        status: .warning
      )
      return nil
    }
    if exactPackageOverride == nil {
      guard let refreshedPackage = remotePublishPackage(for: batchPlan) else {
        setPublishingActionMessage("批量队列没有可上传的文件。", status: .warning)
        return nil
      }
      if refreshedPackage.files != reviewedFiles {
        setPublishingActionMessage(
          CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
          status: .warning
        )
        return nil
      }
      package = refreshedPackage
    }
    profile = store.activeProfile
    mode = modeOverride ?? preferredRemoteRepositoryPublishMode(for: profile)
    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: batchPlan),
      store: store
    )
    if reviewedTarget
      != RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
    {
      setPublishingActionMessage(
        CoreL10n.text("发布目标已变化，请重新打开确认页核对仓库、分支和发布方式。"),
        status: .warning
      )
      return nil
    }
    if let expectedChangedPaths,
      Set(preview.changedPaths) != expectedChangedPaths
    {
      setPublishingActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }
    if let authorization {
      do {
        try AIPublishAuthorizationService.validate(
          authorization,
          package: package,
          preview: preview,
          profile: profile,
          repositoryReport: store.repositoryReport(for: profile)
        )
      } catch {
        setPublishingActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }
    let refreshedBlockingIssues = blockingIssuesBeforeAuthoritativeRemotePreflight(preview)
    guard refreshedBlockingIssues.isEmpty else {
      setPublishingActionMessage(
        blockedLocalPublishMessage(action: "批量线上发布", issues: refreshedBlockingIssues),
        status: .warning
      )
      return nil
    }
    guard preview.hasToken,
      preview.tokenAccessFailureMessage == nil,
      preview.accessCheck?.canWrite == true,
      blockingIssuesBeforeAuthoritativeRemotePreflight(preview).isEmpty
    else {
      setPublishingActionMessage(
        "Token 权限未通过，无法批量线上发布。",
        status: .failure
      )
      return nil
    }

    if !skipDraftMaterialization {
      for item in publishableItems {
        guard
          await ensureDraftMaterializedForRemotePublish(
            package: item.package,
            profile: profile,
            store: store
          )
        else {
          // No remote transport begins until every reviewed formal candidate has
          // a current binding and a real Markdown file in the checkout.
          return nil
        }
      }
    }

    if let validationBeforeRemoteMutation {
      let isStillValid = await validationBeforeRemoteMutation()
      guard isStillValid else {
        setPublishingActionMessage(
          CoreL10n.text("已审阅的发布包在等待期间发生变化，未写入远端。"),
          status: .warning
        )
        return nil
      }
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishingActionMessage(
        "已有远端仓库操作正在运行，请等待完成。",
        status: .warning
      )
      return nil
    }
    selectedSection = .sync
    guard
      let operation = beginRemoteRepositoryMutation(
        profile: profile,
        store: store,
        conflictResolutionOperationID: conflictResolutionOperationID
      )
    else {
      setPublishingActionMessage(
        "已有远端仓库操作正在运行，请等待完成。",
        status: .warning
      )
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    setPublishingActionMessage(
      mode == .directCommit
        ? CoreL10n.format(
          "正在通过 %@ 批量核对远端版本并执行 %@…", profile.repositoryProvider.displayName, mode.displayName)
        : CoreL10n.format(
          "正在通过 %@ 批量执行 %@…", profile.repositoryProvider.displayName, mode.displayName),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }
    var packageForRemoteAttempt = package

    do {
      let token = try repositoryAccessToken(for: profile)
      let progressHandler: @Sendable (RemoteRepositoryPublishProgress) -> Void = {
        [weak self, weak store] progress in
        Task { @MainActor in
          guard let self, let store,
            self.remoteRepositoryMutationIsCurrent(operation, store: store)
          else { return }
          store.setRemoteRepositoryPublishProgress(progress)
          self.observePublishExecution(operation.id, progress: progress, store: store)
        }
      }
      if mode == .directCommit {
        remoteRepositoryConflictSession = nil
        store.setRemoteRepositoryPublishProgress(
          .init(
            stage: .validatingTarget,
            progress: 0.08,
            message: CoreL10n.text("正在核对整批远端版本"),
            detail: CoreL10n.text("完成所有路径检查前不会写入远端")
          )
        )
        let inspection = try await remoteRepositoryPublishService.preflightInspection(
          package: package,
          profile: profile,
          token: token
        )
        let preflight = inspection.result
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }

        let adoptedCount = confirmDirectRemotePublishPreflightAdoptions(
          packages: publishableItems.map(\.package),
          preflight: preflight,
          profile: profile,
          store: store
        )
        packageForRemoteAttempt = packageApplyingRemotePublishPreflight(
          preflight,
          to: package
        )

        guard preflight.conflicts.isEmpty else {
          var conflictSession =
            try await remoteRepositoryPublishService.conflictResolutionSession(
              inspection: inspection,
              profile: profile,
              token: token
            )
          conflictSession.publishScope = .batch(publishableItems.map(\.draftID))
          conflictSession.packageFingerprint =
            remoteRepositoryPublishService.conflictPackageFingerprint(
              package: packageForRemoteAttempt,
              profile: profile
            )
          remoteRepositoryConflictSession = conflictSession
          let conflictPaths = preflight.conflicts.map(\.repositoryPath)
          markRemotePublishPreflightConflicts(
            paths: conflictPaths,
            packages: publishableItems.map(\.package)
          )
          let conflictDetails = preflight.conflicts
            .map { $0.error.localizedDescription }
            .joined(separator: "；")
          let adoptionSummary =
            adoptedCount > 0
            ? CoreL10n.format("；已安全补认 %lld 个内容一致的远端文件", adoptedCount)
            : ""
          let message = CoreL10n.format(
            "批量%@已在远端写入前阻止：%@%@",
            mode.displayName,
            conflictDetails,
            adoptionSummary
          )
          updateBatchRemotePublishPreviewAfterAuthoritativePreflight(
            conflictPaths: conflictPaths,
            conflictMessage: message
          )
          store.setRemoteRepositoryPublishProgress(
            .init(
              stage: .failed,
              progress: nil,
              message: CoreL10n.text("批量发布已阻止"),
              detail: message
            )
          )
          setPublishingActionMessage(message, status: .warning)
          store.save()
          return nil
        }
        if adoptedCount > 0 {
          store.save()
        }
      }
      packageForRemoteAttempt = try beginPublishExecution(
        id: operation.id, package: packageForRemoteAttempt, batchItems: publishableItems,
        profile: profile, mode: mode, store: store)
      var result = try await remoteRepositoryPublishService.publish(
        package: packageForRemoteAttempt,
        profile: profile,
        mode: mode,
        token: token,
        onProgress: progressHandler
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let verifiedItems = publishableItems.map { item in
        var updated = item
        updated.package = item.package.freezingArticleVerification(
          finalFiles: packageForRemoteAttempt.files, profile: profile)
        updated.draftTitle = updated.package.title
        return updated
      }
      let releaseRecord = ReleaseRecord.batchRemotePublish(
        profile: profile,
        items: verifiedItems,
        cleanupCount: 0,
        result: result
      )
      result.releaseRecordID = releaseRecord.id
      let persistence = recordAcceptedRemotePublish(
        result: result, releaseRecord: releaseRecord, executionID: operation.id,
        packages: publishableItems.map(\.package), profile: profile,
        deferDraftLifecycleMutation: deferDraftLifecycleMutation, store: store)
      let adoptedCount = result.automaticallyAdoptedPaths.count
      let adoptedSummary =
        adoptedCount > 0
        ? "；自动认领 \(adoptedCount) 个已存在且内容一致的文件"
        : ""
      let operationSummary =
        "批量\(mode.displayName)完成：发布 \(publishableItems.count) 篇、\(result.changedPaths.count) 个文件\(adoptedSummary)。"
      var deploymentStatus: DeploymentStatusSnapshot?
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        deploymentStatus = await store.refreshDeploymentStatus(
          for: releaseRecord,
          updatesMessage: false
        )
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      applyRemotePublishCompletion(
        mode: mode,
        operationSummary: operationSummary,
        deploymentStatus: deploymentStatus,
        persistence: persistence,
        store: store
      )
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      failPublishExecution(operation.id, error: error, store: store)
      if mode == .directCommit,
        isRemoteVersionConflictError(error),
        let refreshedSession = await refreshedRemoteConflictSessionAfterVersionRace(
          package: packageForRemoteAttempt,
          scope: .batch(publishableItems.map(\.draftID)),
          profile: profile
        )
      {
        remoteRepositoryConflictSession = refreshedSession
        let paths = refreshedSession.conflicts.map(\.repositoryPath)
        markRemotePublishPreflightConflicts(
          paths: paths,
          packages: publishableItems.map(\.package)
        )
        let message = CoreL10n.text(
          "确认批量发布后远端又发生了变化，已停止写入并刷新冲突内容；请协调后重试。"
        )
        updateBatchRemotePublishPreviewAfterAuthoritativePreflight(
          conflictPaths: paths,
          conflictMessage: message
        )
        store.setRemoteRepositoryPublishProgress(
          .init(
            stage: .failed,
            progress: nil,
            message: CoreL10n.text("远端版本再次变化"),
            detail: message
          )
        )
        setPublishingActionMessage(message, status: .warning)
        store.save()
        return nil
      }
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      if partialFailure == nil, remoteRepositoryOperationWasCancelled(error) {
        let message = CoreL10n.text("批量发布流程已中断；如果远端请求已经发出，请刷新仓库状态确认结果。")
        store.setRemoteRepositoryPublishProgress(
          .init(
            stage: .failed,
            progress: nil,
            message: CoreL10n.text("批量发布已中断"),
            detail: message
          ))
        setPublishingActionMessage(message, status: .warning)
        return nil
      }
      let message = "批量\(mode.displayName)失败：\(error.localizedDescription)"
      store.setRemoteRepositoryPublishProgress(
        .init(
          stage: .failed,
          progress: nil,
          message: "批量发布失败",
          detail: error.localizedDescription
        ))
      let releaseRecord = ReleaseRecord.batchRemotePublishFailure(
        package: package,
        profile: profile,
        items: publishableItems,
        cleanupCount: 0,
        mode: mode,
        errorMessage: message,
        changedPaths: partialFailure?.changedPaths,
        commitSHA: partialFailure?.commitSHA
      )
      prependReleaseRecord(releaseRecord)
      updatePublishExecution(
        operation.id, state: .needsVerification, message: message, releaseRecordID: releaseRecord.id
      )
      if !deferDraftLifecycleMutation {
        markRemotePublishFailure(
          packages: publishableItems.map(\.package),
          error: error
        )
      }
      setPublishingActionMessage(message, status: .failure)
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }

}
