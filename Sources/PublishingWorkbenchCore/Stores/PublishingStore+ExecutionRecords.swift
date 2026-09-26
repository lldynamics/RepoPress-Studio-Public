import Foundation

extension PublishingStore {
  func beginPublishExecution(
    id: UUID, package: PublishPackage, batchItems: [BatchPublishPlanItem] = [],
    profile: SiteProfile, mode: RemoteRepositoryPublishMode, store: WorkbenchStore
  ) throws -> PublishPackage {
    let paths = Set(package.files.map(\.repositoryPath))
    guard
      !publishSession.executionRecords.contains(where: {
        $0.state.needsVerification && $0.plan.target.profileID == profile.id
          && !paths.isDisjoint(with: $0.plan.package.files.map(\.repositoryPath))
      })
    else {
      throw WorkbenchRecordStorageError.invalidData(
        CoreL10n.text("上次发布的结果尚未确认，请先在发布记录中核对远端结果。"))
    }
    let preview = remoteRepositoryPublishPreview(
      package: package, profile: profile, mode: mode, store: store)
    let plan = try remoteRepositoryPublishService.freezeExecutionPlan(
      package: package, batchItems: batchItems, profile: profile, preview: preview)
    publishSession.executionRecords.insert(PublishExecutionRecord(id: id, plan: plan), at: 0)
    publishSession.executionRecords = PublishExecutionRecord.retained(
      publishSession.executionRecords)
    guard store.flushPendingChanges() else {
      // No remote request has been made. Keep this fact in memory for a later
      // successful save, and never cross the write boundary on a save failure.
      updatePublishExecution(
        id, state: .verifiedUnchanged, message: CoreL10n.text("发布计划保存失败，未请求远端写入。"))
      throw WorkbenchRecordStorageError.invalidData(CoreL10n.text("发布计划保存失败，未请求远端写入。"))
    }
    return plan.package
  }

  func observePublishExecution(
    _ id: UUID, progress: RemoteRepositoryPublishProgress, store: WorkbenchStore
  ) {
    guard let index = publishSession.executionRecords.firstIndex(where: { $0.id == id }),
      publishSession.executionRecords[index].state == .awaitingRemoteResult,
      publishSession.executionRecords[index].events.last?.stage != progress.stage
    else { return }
    publishSession.executionRecords[index].observe(progress)
    store.save()
  }

  func updatePublishExecution(
    _ id: UUID, state: PublishExecutionState, message: String? = nil, releaseRecordID: UUID? = nil
  ) {
    guard let index = publishSession.executionRecords.firstIndex(where: { $0.id == id }) else {
      return
    }
    publishSession.executionRecords[index].state = state
    publishSession.executionRecords[index].message = message
    let stage: RemoteRepositoryPublishProgressStage = state.needsVerification ? .failed : .completed
    if publishSession.executionRecords[index].events.last?.stage != stage {
      publishSession.executionRecords[index].events.append(
        .init(
          stage: stage, date: Date(), message: message ?? state.displayName))
    }
    if let releaseRecordID {
      publishSession.executionRecords[index].releaseRecordID = releaseRecordID
    }
  }

  func finishPublishExecution(_ id: UUID, record: ReleaseRecord, store: WorkbenchStore) {
    updatePublishExecution(
      id, state: .remoteAccepted, message: CoreL10n.text("远端已返回成功结果。"), releaseRecordID: record.id)
    if !store.flushPendingChanges() {
      updatePublishExecution(
        id, state: .needsVerification,
        message: CoreL10n.text("远端已返回结果，本地记录保存失败。重新打开后请核对远端。"), releaseRecordID: record.id)
      setPublishingActionMessage(CoreL10n.text("远端已返回结果，本地记录保存失败。请保留当前窗口并重试保存。"), status: .warning)
    }
  }

  func failPublishExecution(_ id: UUID, error: Error, store: WorkbenchStore) {
    guard
      publishSession.executionRecords.contains(where: {
        $0.id == id && $0.state == .awaitingRemoteResult
      })
    else { return }
    updatePublishExecution(id, state: .needsVerification, message: error.localizedDescription)
    _ = store.flushPendingChanges()
  }

  /// Explicit user action from the history view; verification issues GETs only.
  public func verifyPublishExecution(_ id: UUID, store: WorkbenchStore) async {
    guard store.canUseProtectedWorkbench,
      let record = publishSession.executionRecords.first(where: { $0.id == id }),
      record.state.needsVerification,
      let profile = profiles.first(where: { $0.id == record.plan.target.profileID })
    else { return }
    let preview = remoteRepositoryPublishPreview(
      package: record.plan.package, profile: profile, mode: record.plan.target.mode, store: store)
    guard
      RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
        == record.plan.target
    else {
      setPublishingActionMessage(CoreL10n.text("站点目标已变化，请恢复原仓库配置后核对该发布计划。"), status: .warning)
      return
    }
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      return
    }
    defer { finishRemoteRepositoryMutation(operation, store: store) }
    do {
      let verification = try await remoteRepositoryPublishService.verifyExecution(
        record.plan, profile: profile, token: repositoryAccessToken(for: profile))
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return }
      switch verification {
      case .unchanged:
        let message = CoreL10n.text("已核实远端仍为原版本，可以重新审阅并发布。")
        updatePublishExecution(id, state: .verifiedUnchanged, message: message)
        setPublishingActionMessage(message, status: .success)
      case .unresolved(let message):
        updatePublishExecution(id, state: .needsVerification, message: message)
        setPublishingActionMessage(message, status: .warning)
      case .accepted(let result):
        let pendingReview = result.mode == .reviewRequest && result.reviewURL == nil
        let message =
          pendingReview
          ? CoreL10n.text("文件与发布计划一致；评审尚未确认，可从发布记录继续创建或获取评审。")
          : CoreL10n.text("已核实远端文件与发布计划一致。")
        let release: ReleaseRecord
        if pendingReview {
          release =
            record.plan.batchItems.isEmpty
            ? .remotePublishFailure(
              package: record.plan.package, profile: profile, mode: result.mode,
              errorMessage: message, changedPaths: result.changedPaths, commitSHA: result.commitSHA)
            : .batchRemotePublishFailure(
              package: record.plan.package, profile: profile, items: record.plan.batchItems,
              mode: result.mode, errorMessage: message, changedPaths: result.changedPaths,
              commitSHA: result.commitSHA)
        } else {
          release =
            record.plan.batchItems.isEmpty
            ? .remotePublish(package: record.plan.package, profile: profile, result: result)
            : .batchRemotePublish(profile: profile, items: record.plan.batchItems, result: result)
        }
        prependReleaseRecord(release)
        updatePublishExecution(
          id, state: .remoteAccepted, message: message, releaseRecordID: release.id)
        // The editor may have newer content. Verification records evidence;
        // it does not rewrite the live document or mark it published.
        setPublishingActionMessage(message, status: pendingReview ? .warning : .success)
      }
      _ = store.flushPendingChanges()
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return }
      updatePublishExecution(id, state: .needsVerification, message: error.localizedDescription)
      setPublishingActionMessage(error.localizedDescription, status: .warning)
      _ = store.flushPendingChanges()
    }
  }
}
