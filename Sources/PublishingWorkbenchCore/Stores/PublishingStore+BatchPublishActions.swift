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
  public func writeSelectedDraftToLocalRepository(
    store: WorkbenchStore
  ) async -> LocalRepositoryWriteResult {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else {
      return .failed(message: publishActionMessage ?? "通用草稿不能直接写入站点仓库。")
    }
    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishActionMessage("没有可写入的发布包。", status: .warning)
      return .failed(message: publishActionMessage ?? "没有可写入的发布包。")
    }

    let profile = store.profile(for: package)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      preview: preview,
      includeRepositoryReadiness: false,
      store: store
    )
    guard blockingIssues.isEmpty else {
      setPublishActionMessage(
        blockedLocalPublishMessage(action: "写入", issues: blockingIssues),
        status: .warning
      )
      return .failed(message: publishActionMessage ?? "本地仓库写入被发布检查阻止。")
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        "已有本地仓库写入或提交任务正在运行，请等待完成。",
        status: .warning
      )
      return .failed(message: publishActionMessage ?? "本地仓库写入任务正在运行。")
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage("正在后台写入本地仓库…", status: .inProgress)

    do {
      let writtenPaths = try await localPublishPreviewService.writeAsync(
        preview: preview,
        profile: profile
      )
      guard
        recordLocalRepositoryWriteBinding(
          package: package,
          profile: profile,
          store: store
        )
      else {
        let message = "文件已写入本地仓库，但无法记录文章的项目绑定。"
        setPublishActionMessage(message, status: .failure)
        return .writtenButRecordSaveFailed(
          writtenPaths: writtenPaths,
          message: message
        )
      }
      prependReleaseRecord(
        .localWrite(package: package, profile: profile, writtenPaths: writtenPaths)
      )
      let stillCurrent =
        localRepositoryMutationContext == operation
        && store.profiles.first(where: { $0.id == profile.id }).map(operation.stillMatches) == true
        && store.activeProfileID == profile.id
      if stillCurrent {
        setPublishActionMessage(
          "已写入 \(writtenPaths.count) 个文件到本地仓库。",
          status: .success
        )
        store.requestRepositoryScan()
      } else {
        setPublishActionMessage(
          "原站点已写入 \(writtenPaths.count) 个文件；当前站点已变化，未刷新当前仓库状态。",
          status: .warning
        )
      }
      guard store.flushPendingChanges() else {
        setPublishActionMessage(
          "文件已写入本地仓库，但工作台发布记录保存失败，请先处理保存问题。",
          status: .failure
        )
        return .writtenButRecordSaveFailed(
          writtenPaths: writtenPaths,
          message: publishActionMessage ?? "文件已写入，但工作台发布记录保存失败。"
        )
      }
      return .succeeded(
        writtenPaths: writtenPaths,
        message: publishActionMessage ?? "本地仓库写入完成。"
      )
    } catch {
      let prefix = store.activeProfileID == profile.id ? "写入失败" : "原站点写入失败"
      setPublishActionMessage(
        "\(prefix)：\(error.localizedDescription)",
        status: .failure
      )
      return .failed(message: publishActionMessage ?? error.localizedDescription)
    }
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository(store: WorkbenchStore) async
    -> BatchLocalWriteResult
  {
    await store.refreshBatchPublishPlanAsync()

    guard let batchPublishPlan else {
      setPublishActionMessage("没有可写入的批量发布计划。", status: .warning)
      return BatchLocalWriteResult(writtenDraftCount: 0, writtenPaths: [], skippedCount: 0)
    }

    let writableItems = batchPublishPlan.writableItems
    guard !writableItems.isEmpty else {
      setPublishActionMessage(
        "当前没有可批量写入的文章；请先处理阻塞问题、需确认项或确认文件变化。",
        status: .warning
      )
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }

    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        "已有本地仓库写入或提交任务正在运行，请等待完成。",
        status: .warning
      )
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage("正在后台批量写入本地仓库…", status: .inProgress)

    var writtenItems: [BatchPublishPlanItem] = []
    var writtenPaths: [String] = []
    var failedTitles: [String] = []

    for item in writableItems {
      do {
        let paths = try await localPublishPreviewService.writeAsync(
          preview: item.preview,
          profile: profile
        )
        guard
          recordLocalRepositoryWriteBinding(
            package: item.package,
            profile: profile,
            store: store
          )
        else {
          failedTitles.append("\(item.draftTitle)：无法记录文章的项目绑定")
          continue
        }
        writtenItems.append(item)
        writtenPaths.append(contentsOf: paths)
      } catch {
        failedTitles.append("\(item.draftTitle)：\(error.localizedDescription)")
      }
    }

    if !writtenItems.isEmpty {
      prependReleaseRecord(
        .batchLocalWrite(profile: profile, items: writtenItems, writtenPaths: writtenPaths)
      )
      store.save()
    }
    let stillCurrent =
      localRepositoryMutationContext == operation
      && store.profiles.first(where: { $0.id == profile.id }).map(operation.stillMatches) == true
      && store.activeProfileID == profile.id
    if stillCurrent {
      store.requestRepositoryScan()
    }

    let result = BatchLocalWriteResult(
      writtenDraftCount: writtenItems.count,
      writtenPaths: writtenPaths,
      failedTitles: failedTitles,
      skippedCount: batchPublishPlan.items.count - writableItems.count
    )

    if !stillCurrent {
      setPublishActionMessage(
        "原站点批量写入完成：成功 \(result.writtenDraftCount) 篇、失败 \(failedTitles.count) 篇；当前站点已变化。",
        status: .warning
      )
    } else if failedTitles.isEmpty {
      setPublishActionMessage(
        "已批量写入 \(result.writtenDraftCount) 篇、\(result.writtenPaths.count) 个文件。",
        status: .success
      )
    } else {
      setPublishActionMessage(
        "已写入 \(result.writtenDraftCount) 篇，\(failedTitles.count) 篇失败：\(failedTitles.joined(separator: "；"))",
        status: .warning
      )
    }

    return result
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
    guard self.remoteConflictResolutionOperationID == nil
      || self.remoteConflictResolutionOperationID == conflictResolutionOperationID
    else {
      setPublishActionMessage(
        CoreL10n.text("远端冲突协调正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }

    if let authorization {
      do {
        try AIPublishAuthorizationService.validateTarget(
          authorization,
          profile: store.activeProfile
        )
      } catch {
        setPublishActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }

    await store.refreshBatchPublishPlanAsync()

    guard var batchPlan = batchPublishPlan else {
      setPublishActionMessage("没有可线上发布的批量队列。", status: .warning)
      return nil
    }

    // Keep the reviewed candidate set as the authority for what may enter the
    // online queue. Site drafts remain excluded by remotePublishableItems.
    var publishableItems = batchPlan.remotePublishableItems
    guard !publishableItems.isEmpty else {
      setPublishActionMessage(
        "当前没有可批量发布的文章。待下线请求请在回收站单独处理。",
        status: .warning
      )
      return nil
    }

    var profile = store.activeProfile
    var mode = modeOverride ?? preferredRemoteRepositoryPublishMode(for: profile)
    guard var package = exactPackageOverride ?? remotePublishPackage(for: batchPlan) else {
      setPublishActionMessage("批量队列没有可上传的文件。", status: .warning)
      return nil
    }
    let reviewedFiles = package.files
    let reviewedDraftIDs = publishableItems.map(\.draftID)

    if let expectedReview, !expectedReview.matches(plan: batchPlan, package: package) {
      setPublishActionMessage(
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
      setPublishActionMessage(
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
        setPublishActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }
    if let expectedChangedPaths,
      Set(initialPreview.changedPaths) != expectedChangedPaths
    {
      setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }
    if let tokenAccessFailureMessage = initialPreview.tokenAccessFailureMessage {
      setPublishActionMessage(
        CoreL10n.format(
          "仓库 Token 状态读取失败：%@",
          tokenAccessFailureMessage
        ),
        status: .failure
      )
      return nil
    }
    guard initialPreview.hasToken else {
      setPublishActionMessage(
        "仓库访问 Token 未保存，无法批量线上发布。",
        status: .warning
      )
      return nil
    }
    let initialBlockingIssues = blockingIssuesBeforeAuthoritativeRemotePreflight(initialPreview)
    guard initialBlockingIssues.isEmpty else {
      setPublishActionMessage(
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
      setPublishActionMessage("没有可线上发布的批量队列。", status: .warning)
      return nil
    }
    batchPlan = refreshedBatchPlan
    publishableItems = batchPlan.remotePublishableItems
    guard publishableItems.map(\.draftID) == reviewedDraftIDs else {
      setPublishActionMessage(
        "待发布文章已变化，请重新打开确认页审阅完整清单。",
        status: .warning
      )
      return nil
    }
    if exactPackageOverride == nil {
      guard let refreshedPackage = remotePublishPackage(for: batchPlan) else {
        setPublishActionMessage("批量队列没有可上传的文件。", status: .warning)
        return nil
      }
      if refreshedPackage.files != reviewedFiles {
        setPublishActionMessage(
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
      setPublishActionMessage(
        CoreL10n.text("发布目标已变化，请重新打开确认页核对仓库、分支和发布方式。"),
        status: .warning
      )
      return nil
    }
    if let expectedChangedPaths,
      Set(preview.changedPaths) != expectedChangedPaths
    {
      setPublishActionMessage(
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
        setPublishActionMessage(error.localizedDescription, status: .warning)
        return nil
      }
    }
    let refreshedBlockingIssues = blockingIssuesBeforeAuthoritativeRemotePreflight(preview)
    guard refreshedBlockingIssues.isEmpty else {
      setPublishActionMessage(
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
      setPublishActionMessage(
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
        setPublishActionMessage(
          CoreL10n.text("已审阅的发布包在等待期间发生变化，未写入远端。"),
          status: .warning
        )
        return nil
      }
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishActionMessage(
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
      setPublishActionMessage(
        "已有远端仓库操作正在运行，请等待完成。",
        status: .warning
      )
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    setPublishActionMessage(
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
          setPublishActionMessage(message, status: .warning)
          store.save()
          return nil
        }
        if adoptedCount > 0 {
          store.save()
        }
      }
      let result = try await remoteRepositoryPublishService.publish(
        package: packageForRemoteAttempt,
        profile: profile,
        mode: mode,
        token: token,
        onProgress: progressHandler
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      remoteRepositoryConflictSession = nil
      store.setRemoteRepositoryPublishResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let releaseRecord = ReleaseRecord.batchRemotePublish(
        profile: profile,
        items: publishableItems,
        cleanupCount: 0,
        result: result
      )
      prependReleaseRecord(releaseRecord)
      if !deferDraftLifecycleMutation {
        confirmDirectRemotePublishLifecycle(
          packages: publishableItems.map(\.package),
          result: result
        )
        if mode == .reviewRequest {
          markRemotePublishReviewSuccess(packages: publishableItems.map(\.package))
        }
      }
      if mode != .previewBranch {
        store.recordRemoteRepositoryPublishInAutoSync(result, profileID: profile.id)
      }
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
      if mode == .directCommit,
        result.commitSHA?.trimmedForPublishing.nilIfEmpty != nil,
        deploymentStatus?.level == .success,
        deploymentStatus?.attributionVerified == true,
        markDraftsAsPublishedIfDirectRemoteCommit(
          mode: mode,
          draftIDs: publishableItems.map(\.draftID)
        )
      {
        store.invalidateDraftDerivedCaches()
      }
      let completionFeedback = remotePublishCompletionFeedback(
        mode: mode,
        operationSummary: operationSummary,
        deploymentStatus: deploymentStatus
      )
      setPublishActionMessage(
        completionFeedback.message,
        status: completionFeedback.status
      )
      store.save()
      store.setRemoteRepositoryPublishProgress(
        .init(
          stage: .completed,
          progress: 1,
          message: remotePublishCompletedProgressMessage(
            mode: mode,
            deploymentStatus: deploymentStatus
          ),
          detail: completionFeedback.message
        ))
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
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
        setPublishActionMessage(message, status: .warning)
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
        setPublishActionMessage(message, status: .warning)
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
      if !deferDraftLifecycleMutation {
        markRemotePublishFailure(
          packages: publishableItems.map(\.package),
          error: error
        )
      }
      setPublishActionMessage(message, status: .failure)
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }

  func packageApplyingRemotePublishPreflight(
    _ preflight: RemoteRepositoryPublishPreflightResult,
    to package: PublishPackage
  ) -> PublishPackage {
    var reconciled = package
    for index in reconciled.files.indices {
      let path = reconciled.files[index].repositoryPath.normalizedRelativePath()
      if let remoteVersion = preflight.remoteVersionsByPath[path]?.trimmedForPublishing.nilIfEmpty {
        reconciled.files[index].expectedRemoteSHA = remoteVersion
      }
    }
    return reconciled
  }

  @discardableResult
  func confirmDirectRemotePublishPreflightAdoptions(
    packages: [PublishPackage],
    preflight: RemoteRepositoryPublishPreflightResult,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> Int {
    let adoptedPaths = Set(preflight.automaticallyAdoptedPaths.map { $0.normalizedRelativePath() })
    guard !adoptedPaths.isEmpty else { return 0 }
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    var changedDraftIDs = Set<UUID>()

    drafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id] else { return draft }
      var updated = draft

      updated.attachments = updated.attachments.map { attachment in
        let path = attachment.repositoryPath.normalizedRelativePath()
        guard adoptedPaths.contains(path),
          let remoteVersion = preflight.remoteVersionsByPath[path]?.trimmedForPublishing.nilIfEmpty,
          attachment.repositorySHA?.trimmedForPublishing != remoteVersion
        else {
          return attachment
        }
        var confirmed = attachment
        confirmed.repositorySHA = remoteVersion
        changedDraftIDs.insert(draft.id)
        return confirmed
      }

      let markdownPath = package.markdownPath.normalizedRelativePath()
      if adoptedPaths.contains(markdownPath),
        let remoteVersion = preflight.remoteVersionsByPath[markdownPath]?.trimmedForPublishing
          .nilIfEmpty,
        let publishedContent = package.markdownFile?.content,
        let currentContent = publishPackageBuilder.build(draft: draft, profile: profile)
          .markdownFile?.content,
        currentContent == publishedContent
      {
        updated.confirmRepositoryBinding(
          profile: profile,
          repositoryPath: markdownPath,
          remoteRevision: remoteVersion,
          renderedContentDigest: ArticleDraft.repositoryDocumentDigest(publishedContent)
        )
        changedDraftIDs.insert(draft.id)
      }
      if updated != draft {
        updated.markUpdated(at: draft.updatedAt, replacing: draft)
      }
      return updated
    }

    for draftID in changedDraftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
    return adoptedPaths.count
  }

}
