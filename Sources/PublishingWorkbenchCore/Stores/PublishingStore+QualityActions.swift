import Foundation

extension PublishingStore {
  func siteMaintenanceReportInput(store: WorkbenchStore, now: Date = Date())
    -> SiteMaintenanceReportInput
  {
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
    store: WorkbenchStore,
    selectedDraftIDs: Set<UUID>? = nil,
    expectedOriginalDates: [UUID: Date]? = nil
  ) -> Int {
    let proposedDates = Dictionary(
      uniqueKeysWithValues: report.calendarScheduleItems.map { ($0.draftID, $0.scheduledDate) }
    )
    let approvedSuggestedDates = proposedDates.filter { draftID, _ in
      selectedDraftIDs?.contains(draftID) != false
    }
    return applySuggestedMaintenanceSchedule(
      approvedSuggestedDates: approvedSuggestedDates,
      store: store,
      expectedOriginalDates: expectedOriginalDates
    )
  }

  @discardableResult
  public func applySuggestedMaintenanceSchedule(
    approvedSuggestedDates: [UUID: Date],
    store: WorkbenchStore,
    expectedOriginalDates: [UUID: Date]? = nil
  ) -> Int {
    var appliedCount = 0
    var conflictCount = 0
    for index in drafts.indices {
      let draftID = drafts[index].id
      guard let suggestedDate = approvedSuggestedDates[draftID],
        !Calendar.autoupdatingCurrent.isDate(
          drafts[index].date,
          inSameDayAs: suggestedDate
        )
      else {
        continue
      }
      if let expectedOriginalDate = expectedOriginalDates?[draftID],
        drafts[index].date != expectedOriginalDate
      {
        conflictCount += 1
        continue
      }
      let previous = drafts[index]
      var updated = previous
      updated.date = suggestedDate
      updated.markUpdated(replacing: previous)
      drafts[index] = updated
      appliedCount += 1
    }
    let message: String
    let status: PublishActionMessageStatus
    if conflictCount > 0 {
      message =
        appliedCount == 0
        ? CoreL10n.format("未应用排期：%d 篇文章的日期已变化，请重新生成预览。", conflictCount)
        : CoreL10n.format(
          "已应用 %d 篇排期；另有 %d 篇日期已变化，未覆盖。", appliedCount, conflictCount)
      status = .warning
    } else if appliedCount == 0 {
      message = CoreL10n.text("没有需要应用的维护排期。")
      status = .warning
    } else {
      message = CoreL10n.format("已应用 %d 篇待发布文章的建议排期。", appliedCount)
      status = .success
    }
    setPublishActionMessage(message, status: status)
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
    return batchPublishCommandBuilder.directCommitCommand(
      plan: batchPublishPlan, profile: store.activeProfile)
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
