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
      publishActionMessage = "没有可写入的发布包。"
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
    localPublishReadiness = makeLocalPublishReadiness(package: package, profile: profile, preview: preview, store: store)
    guard blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: "写入", issues: blockingIssues)
      return .failed(message: publishActionMessage ?? "本地仓库写入被发布检查阻止。")
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return .failed(message: publishActionMessage ?? "本地仓库写入任务正在运行。")
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在后台写入本地仓库…"

    do {
      let writtenPaths = try await localPublishPreviewService.writeAsync(
        preview: preview,
        profile: profile
      )
      prependReleaseRecord(
        .localWrite(package: package, profile: profile, writtenPaths: writtenPaths)
      )
      let stillCurrent = localRepositoryMutationContext == operation
        && store.profiles.first(where: { $0.id == profile.id }).map(operation.stillMatches) == true
        && store.activeProfileID == profile.id
      if stillCurrent {
        publishActionMessage = "已写入 \(writtenPaths.count) 个文件到本地仓库。"
        store.requestRepositoryScan()
      } else {
        publishActionMessage = "原站点已写入 \(writtenPaths.count) 个文件；当前站点已变化，未刷新当前仓库状态。"
      }
      guard store.flushPendingChanges() else {
        publishActionMessage = "文件已写入本地仓库，但工作台发布记录保存失败，请先处理保存问题。"
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
      publishActionMessage = "\(prefix)：\(error.localizedDescription)"
      return .failed(message: publishActionMessage ?? error.localizedDescription)
    }
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository(store: WorkbenchStore) async -> BatchLocalWriteResult {
    await store.refreshBatchPublishPlanAsync()

    guard let batchPublishPlan else {
      publishActionMessage = "没有可写入的批量发布计划。"
      return BatchLocalWriteResult(writtenDraftCount: 0, writtenPaths: [], skippedCount: 0)
    }

    let writableItems = batchPublishPlan.writableItems
    guard !writableItems.isEmpty else {
      publishActionMessage = "当前没有可批量写入的文章；请先处理阻塞问题、需确认项或确认文件变化。"
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }

    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在后台批量写入本地仓库…"

    var writtenItems: [BatchPublishPlanItem] = []
    var writtenPaths: [String] = []
    var failedTitles: [String] = []

    for item in writableItems {
      do {
        let paths = try await localPublishPreviewService.writeAsync(
          preview: item.preview,
          profile: profile
        )
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
    let stillCurrent = localRepositoryMutationContext == operation
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
      publishActionMessage = "原站点批量写入完成：成功 \(result.writtenDraftCount) 篇、失败 \(failedTitles.count) 篇；当前站点已变化。"
    } else if failedTitles.isEmpty {
      publishActionMessage = "已批量写入 \(result.writtenDraftCount) 篇、\(result.writtenPaths.count) 个文件。"
    } else {
      publishActionMessage = "已写入 \(result.writtenDraftCount) 篇，\(failedTitles.count) 篇失败：\(failedTitles.joined(separator: "；"))"
    }

    return result
  }

  @discardableResult
  public func publishBatchReadyDraftsOnlineUsingPreferredStrategy(
    store: WorkbenchStore,
    expectedChangedPaths: Set<String>? = nil
  ) async -> RemoteRepositoryPublishResult? {
    guard store.canUseProtectedWorkbench else {
      publishActionMessage = store.quickHideOperationMessage
      return nil
    }

    await store.refreshBatchPublishPlanAsync()

    guard let batchPublishPlan else {
      publishActionMessage = "没有可线上发布的批量队列。"
      return nil
    }

    let publishableItems = batchPublishPlan.remotePublishableItems
    guard !publishableItems.isEmpty else {
      publishActionMessage = "当前没有可批量线上发布的文章；请先处理阻塞问题、需确认项或确认文件变化。"
      return nil
    }

    let profile = store.activeProfile
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    guard let package = remotePublishPackage(for: batchPublishPlan) else {
      publishActionMessage = "批量队列没有可上传的文件。"
      return nil
    }

    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: batchPublishPlan),
      store: store
    )
    if let expectedChangedPaths,
       Set(preview.changedPaths) != expectedChangedPaths {
      publishActionMessage = CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。")
      return nil
    }
    if let tokenAccessFailureMessage = preview.tokenAccessFailureMessage {
      publishActionMessage = CoreL10n.format(
        "仓库 Token 状态读取失败：%@",
        tokenAccessFailureMessage
      )
      return nil
    }
    guard preview.hasToken else {
      publishActionMessage = "仓库访问 Token 未保存，无法批量线上发布。"
      return nil
    }
    guard preview.blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: "批量线上发布", issues: preview.blockingIssues)
      return nil
    }
    guard preview.accessCheck != nil else {
      publishActionMessage = "请先检查 \(profile.repositoryProvider.displayName) Token 权限，确认具备写入权限后再批量线上发布。"
      return nil
    }
    guard preview.canPublish else {
      publishActionMessage = "Token 权限未通过，无法批量线上发布。"
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    selectedSection = .sync
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    publishActionMessage = mode == .directCommit
      ? CoreL10n.format("正在通过 %@ 批量核对远端版本并执行%@...", profile.repositoryProvider.displayName, mode.displayName)
      : CoreL10n.format("正在通过 %@ 批量执行%@...", profile.repositoryProvider.displayName, mode.displayName)
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let progressHandler: @Sendable (RemoteRepositoryPublishProgress) -> Void = { [weak self, weak store] progress in
        Task { @MainActor in
          guard let self, let store,
                self.remoteRepositoryMutationIsCurrent(operation, store: store) else { return }
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
      store.recordRemoteRepositoryPublishInAutoSync(result)
      publishActionMessage = "批量\(mode.displayName)完成：\(publishableItems.count) 篇、\(result.changedPaths.count) 个文件。"
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      if store.remoteRepositoryPublishProgress?.stage != .completed {
        store.setRemoteRepositoryPublishProgress(.init(
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
      store.setRemoteRepositoryPublishProgress(.init(
        stage: .failed,
        progress: nil,
        message: "批量发布失败",
        detail: error.localizedDescription
      ))
      let releaseRecord = ReleaseRecord.batchRemotePublishFailure(
        package: package,
        profile: profile,
        items: publishableItems,
        mode: mode,
        errorMessage: message,
        changedPaths: partialFailure?.changedPaths,
        commitSHA: partialFailure?.commitSHA
      )
      prependReleaseRecord(releaseRecord)
      publishActionMessage = message
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }
}
