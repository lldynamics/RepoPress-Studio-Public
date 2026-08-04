import Foundation

extension PublishingStore {
  func siteMaintenanceReportInput(store: WorkbenchStore, now: Date = Date()) -> SiteMaintenanceReportInput {
    SiteMaintenanceReportInput(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      releaseRecords: store.activeProfileReleaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      now: now
    )
  }

  @discardableResult
  public func recordMaintenanceOperation(
    for item: MaintenanceActionItem,
    summary: String? = nil,
    store: WorkbenchStore
  ) -> MaintenanceOperationRecord {
    let record = MaintenanceOperationRecord(
      profileID: activeProfileID,
      actionKind: item.kind,
      actionTitle: item.title,
      summary: summary?.nilIfEmpty ?? item.summary,
      draftID: item.draftID,
      targetPath: item.targetPath
    )
    maintenanceOperationRecords.insert(record, at: 0)
    setPublishActionMessage("已记录维护操作。", status: .success)
    store.save()
    return record
  }

  @discardableResult
  public func applySuggestedMaintenanceSchedule(
    report: SiteMaintenanceReport,
    store: WorkbenchStore
  ) -> Int {
    let suggestedDates = Dictionary(
      uniqueKeysWithValues: report.calendarScheduleItems.map { ($0.draftID, $0.scheduledDate) }
    )
    var appliedCount = 0
    for index in drafts.indices {
      guard let suggestedDate = suggestedDates[drafts[index].id],
            drafts[index].date != suggestedDate else {
        continue
      }
      drafts[index].date = suggestedDate
      appliedCount += 1
    }
    setPublishActionMessage(
      appliedCount == 0
        ? "没有需要应用的维护排期。"
        : "已应用 \(appliedCount) 篇待发布文章的建议排期。",
      status: appliedCount == 0 ? .warning : .success
    )
    if appliedCount > 0 {
      store.save()
    }
    return appliedCount
  }

  public func localCommitCommandForSelectedDraft(store: WorkbenchStore) -> String? {
    guard let package = publishPackageForSelectedDraft(store: store) else {
      return nil
    }

    let profile = store.profile(for: package)
    guard refreshCommitReadiness(package: package, profile: profile, store: store).canCommit else {
      return nil
    }

    return localPublishPreviewService.commitCommand(package: package, profile: profile)
  }

  public func reviewBranchCommandsForSelectedDraft(store: WorkbenchStore) -> [String] {
    guard let package = publishPackageForSelectedDraft(store: store) else {
      return []
    }

    let profile = store.profile(for: package)
    guard refreshCommitReadiness(package: package, profile: profile, store: store).canCommit else {
      return []
    }

    return remoteReviewDraftBuilder.branchCommands(package: package, profile: profile)
  }

  public func batchLocalCommitCommandForWritableDrafts(store: WorkbenchStore) -> String? {
    store.refreshBatchPublishPlan()
    guard let batchPublishPlan else {
      return nil
    }
    return batchPublishCommandBuilder.directCommitCommand(plan: batchPublishPlan, profile: store.activeProfile)
  }

  public func batchReviewBranchCommandsForWritableDrafts(store: WorkbenchStore) -> [String] {
    store.refreshBatchPublishPlan()
    guard let batchPublishPlan else {
      return []
    }
    return batchPublishCommandBuilder.reviewBranchCommands(
      plan: batchPublishPlan,
      profile: store.activeProfile,
      now: batchPublishPlan.generatedAt
    )
  }

  public func commitSelectedDraftDirectly(store: WorkbenchStore) async {
    await publishSelectedDraft(mode: .directCommit, store: store)
  }

  public func commitSelectedDraftToReviewBranch(store: WorkbenchStore) async {
    await publishSelectedDraft(mode: .reviewBranch, store: store)
  }

  public func commitSelectedDraftUsingPreferredStrategy(store: WorkbenchStore) async {
    guard let package = publishPackageForSelectedDraft(store: store) else {
      setPublishActionMessage("没有可提交的发布包。", status: .warning)
      return
    }

    await publishSelectedDraft(
      mode: preferredLocalGitPublishMode(for: store.profile(for: package)),
      store: store
    )
  }

}
