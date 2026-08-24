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
    localPublishPreview = preview
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      preview: preview,
      includeRepositoryReadiness: false,
      store: store
    )
    localPublishReadiness = makeLocalPublishReadiness(
      package: package, profile: profile, preview: preview, store: store)
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
      guard recordLocalRepositoryWriteBinding(
        package: package,
        profile: profile,
        store: store
      ) else {
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
        guard recordLocalRepositoryWriteBinding(
          package: item.package,
          profile: profile,
          store: store
        ) else {
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
    authorization: AIPublishAuthorizationSnapshot? = nil
  ) async -> RemoteRepositoryPublishResult? {
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

    guard let batchPlan = batchPublishPlan else {
      setPublishActionMessage("没有可线上发布的批量队列。", status: .warning)
      return nil
    }

    // Keep the reviewed candidate set as the authority for what may enter the
    // online queue. Site drafts remain excluded by remotePublishableItems.
    let initialPublishableItems = batchPlan.remotePublishableItems
    let publishableItems = initialPublishableItems
    let cleanupRequests = pendingRemoteRepositoryCleanupRequests(
      profileID: batchPlan.profileID
    )
    guard !publishableItems.isEmpty || !cleanupRequests.isEmpty else {
      setPublishActionMessage(
        "当前没有可批量处理的文章发布或下线请求。",
        status: .warning
      )
      return nil
    }

    let profile = store.activeProfile
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    guard let package = remotePublishPackage(
      for: batchPlan,
      cleanupRequests: cleanupRequests
    ) else {
      setPublishActionMessage("批量队列没有可上传的文件。", status: .warning)
      return nil
    }

    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: batchPlan),
      forcedChangedPaths: Set(cleanupRequests.map { $0.repositoryPath.normalizedRelativePath() }),
      store: store
    )
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
    if let expectedChangedPaths,
      Set(preview.changedPaths) != expectedChangedPaths
    {
      setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return nil
    }
    if let tokenAccessFailureMessage = preview.tokenAccessFailureMessage {
      setPublishActionMessage(
        CoreL10n.format(
          "仓库 Token 状态读取失败：%@",
          tokenAccessFailureMessage
        ),
        status: .failure
      )
      return nil
    }
    guard preview.hasToken else {
      setPublishActionMessage(
        "仓库访问 Token 未保存，无法批量线上发布。",
        status: .warning
      )
      return nil
    }
    guard preview.blockingIssues.isEmpty else {
      setPublishActionMessage(
        blockedLocalPublishMessage(action: "批量线上发布", issues: preview.blockingIssues),
        status: .warning
      )
      return nil
    }
    guard preview.accessCheck != nil else {
      setPublishActionMessage(
        "请先检查 \(profile.repositoryProvider.displayName) Token 权限，确认具备写入权限后再批量线上发布。",
        status: .warning
      )
      return nil
    }
    guard preview.canPublish else {
      setPublishActionMessage(
        "Token 权限未通过，无法批量线上发布。",
        status: .failure
      )
      return nil
    }

    for item in publishableItems {
      guard await ensureDraftMaterializedForRemotePublish(
        package: item.package,
        profile: profile,
        store: store
      ) else {
        // No remote transport begins until every reviewed formal candidate has
        // a current binding and a real Markdown file in the checkout.
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
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
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
          "正在通过 %@ 批量核对远端版本并执行%@...", profile.repositoryProvider.displayName, mode.displayName)
        : CoreL10n.format(
          "正在通过 %@ 批量执行%@...", profile.repositoryProvider.displayName, mode.displayName),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

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
      let result = try await remoteRepositoryPublishService.publish(
        package: package,
        profile: profile,
        mode: mode,
        token: token,
        onProgress: progressHandler
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryPublishResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let releaseRecord = ReleaseRecord.batchRemotePublish(
        profile: profile,
        items: publishableItems,
        cleanupCount: cleanupRequests.count,
        result: result
      )
      prependReleaseRecord(releaseRecord)
      markDraftsAsPublishedIfDirectRemoteCommit(
        mode: mode,
        draftIDs: publishableItems.map(\.draftID)
      )
      confirmDirectRemotePublishLifecycle(
        packages: publishableItems.map(\.package),
        result: result
      )
      if mode == .reviewRequest {
        markRemotePublishReviewSuccess(packages: publishableItems.map(\.package))
      }
      let cleanupRequestIDs = Set(cleanupRequests.map(\.id))
      _ = recordRemoteRepositoryCleanupResult(
        requestIDs: cleanupRequestIDs,
        result: result
      )
      let locallyCleanedCount = cleanupRequests.reduce(into: 0) { count, request in
        if draftRepositoryCleanupRequests.first(where: { $0.id == request.id })?.needsLocalCleanup == true,
           performLocalRepositoryCleanup(request.id, store: store) {
          count += 1
        }
      }
      store.recordRemoteRepositoryPublishInAutoSync(result, profileID: profile.id)
      let adoptedCount = result.automaticallyAdoptedPaths.count
      let adoptedSummary = adoptedCount > 0
        ? "；自动认领 \(adoptedCount) 个已存在且内容一致的文件"
        : ""
      let cleanupSummary = cleanupRequests.isEmpty
        ? ""
        : "；处理下线 \(cleanupRequests.count) 篇，本地清理 \(locallyCleanedCount) 篇"
      setPublishActionMessage(
        "批量\(mode.displayName)完成：发布 \(publishableItems.count) 篇、\(result.changedPaths.count) 个文件\(cleanupSummary)\(adoptedSummary)。",
        status: .success
      )
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      if store.remoteRepositoryPublishProgress?.stage != .completed {
        store.setRemoteRepositoryPublishProgress(
          .init(
            stage: .completed,
            progress: 1,
            message: "批量发布完成",
            detail: "发布流程已结束"
          ))
      }
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let message = "批量\(mode.displayName)失败：\(error.localizedDescription)"
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      _ = recordRemoteRepositoryCleanupFailure(
        requestIDs: Set(cleanupRequests.map(\.id)),
        message: error.localizedDescription
      )
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
        cleanupCount: cleanupRequests.count,
        mode: mode,
        errorMessage: message,
        changedPaths: partialFailure?.changedPaths,
        commitSHA: partialFailure?.commitSHA
      )
      prependReleaseRecord(releaseRecord)
      markRemotePublishFailure(
        packages: publishableItems.map(\.package),
        error: error
      )
      setPublishActionMessage(message, status: .failure)
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }
}
