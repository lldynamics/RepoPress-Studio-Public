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
}
