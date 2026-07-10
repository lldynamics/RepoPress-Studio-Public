import Foundation

extension WorkbenchStore {
  public var isSiteMaintenanceSnapshotStale: Bool {
    isSiteMaintenanceSnapshotStaleState()
  }

  public func refreshSiteMaintenanceSnapshot() {
    let report = publishingStore.makeSiteMaintenanceSnapshotReport(store: self)
    replaceSiteMaintenanceSnapshot(report: report)
  }

  @discardableResult
  public func recordMaintenanceOperation(
    for item: MaintenanceActionItem,
    summary: String? = nil
  ) -> MaintenanceOperationRecord {
    let record = publishingStore.recordMaintenanceOperation(for: item, summary: summary, store: self)
    invalidateSiteMaintenanceSnapshot()
    return record
  }

  @discardableResult
  public func recordContentPerformanceSnapshot(
    for draft: ArticleDraft,
    pageViews: Int,
    visitors: Int,
    sourceName: String = "手动记录"
  ) -> ContentPerformanceSnapshot {
    let snapshot = publishingStore.recordContentPerformanceSnapshot(
      for: draft,
      pageViews: pageViews,
      visitors: visitors,
      sourceName: sourceName,
      store: self
    )
    invalidateSiteMaintenanceSnapshot()
    return snapshot
  }

  @discardableResult
  public func applySuggestedMaintenanceSchedule() -> Int {
    let appliedCount = publishingStore.applySuggestedMaintenanceSchedule(store: self)
    invalidateSiteMaintenanceSnapshot()
    return appliedCount
  }

  public func relatedArticleSuggestions(for draft: ArticleDraft, limit: Int = 5) -> [SiteRelationSuggestion] {
    publishingStore.relatedArticleSuggestions(for: draft, limit: limit)
  }
}
