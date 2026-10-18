import Foundation

extension PublishingStore {
  @discardableResult
  public func writeSelectedDraftToLocalRepository(
    store: WorkbenchStore
  ) async -> LocalRepositoryWriteResult {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else {
      return .failed(message: publishActionMessage ?? "仅本地草稿不能直接写入站点仓库。")
    }
    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishingActionMessage("没有可写入的发布包。", status: .warning)
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
      setPublishingActionMessage(
        blockedLocalPublishMessage(action: "写入", issues: blockingIssues),
        status: .warning
      )
      return .failed(message: publishActionMessage ?? "本地仓库写入被发布检查阻止。")
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishingActionMessage(
        "已有本地仓库写入或提交任务正在运行，请等待完成。",
        status: .warning
      )
      return .failed(message: publishActionMessage ?? "本地仓库写入任务正在运行。")
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishingActionMessage("正在后台写入本地仓库…", status: .inProgress)

    do {
      try store.siteDraftFileStore.recordPendingMoves(package: package, profile: profile)
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
        setPublishingActionMessage(message, status: .failure)
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
        setPublishingActionMessage(
          "已写入 \(writtenPaths.count) 个文件到本地仓库。",
          status: .success
        )
        store.requestRepositoryScan()
      } else {
        setPublishingActionMessage(
          "原站点已写入 \(writtenPaths.count) 个文件；当前站点已变化，未刷新当前仓库状态。",
          status: .warning
        )
      }
      guard store.flushPendingChanges() else {
        setPublishingActionMessage(
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
      setPublishingActionMessage(
        "\(prefix)：\(error.localizedDescription)",
        status: .failure
      )
      return .failed(message: publishActionMessage ?? error.localizedDescription)
    }
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository(
    store: WorkbenchStore, includesSiteDrafts: Bool = true
  ) async -> BatchLocalWriteResult {
    await store.refreshBatchPublishPlanAsync()

    guard let batchPublishPlan else {
      setPublishingActionMessage("没有可写入的批量发布计划。", status: .warning)
      return BatchLocalWriteResult(writtenDraftCount: 0, writtenPaths: [], skippedCount: 0)
    }

    let writableItems = batchPublishPlan.writableItems(includingSiteDrafts: includesSiteDrafts)
    guard !writableItems.isEmpty else {
      setPublishingActionMessage(
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
      setPublishingActionMessage(
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
    setPublishingActionMessage("正在后台批量写入本地仓库…", status: .inProgress)

    var writtenItems: [BatchPublishPlanItem] = []
    var writtenPaths: [String] = []
    var failedTitles: [String] = []

    for item in writableItems {
      do {
        try store.siteDraftFileStore.recordPendingMoves(package: item.package, profile: profile)
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
      setPublishingActionMessage(
        "原站点批量写入完成：成功 \(result.writtenDraftCount) 篇、失败 \(failedTitles.count) 篇；当前站点已变化。",
        status: .warning
      )
    } else if failedTitles.isEmpty {
      setPublishingActionMessage(
        "已批量写入 \(result.writtenDraftCount) 篇、\(result.writtenPaths.count) 个文件。",
        status: .success
      )
    } else {
      setPublishingActionMessage(
        "已写入 \(result.writtenDraftCount) 篇，\(failedTitles.count) 篇失败：\(failedTitles.joined(separator: "；"))",
        status: .warning
      )
    }

    return result
  }
}
