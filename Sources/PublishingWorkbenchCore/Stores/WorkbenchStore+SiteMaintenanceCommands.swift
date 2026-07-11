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
  public func importContentPerformanceCSV(
    _ data: Data,
    sourceName: String = "CSV 导入"
  ) throws -> ContentPerformanceCSVImportReport {
    let report = try publishingStore.importContentPerformanceCSV(data, sourceName: sourceName, store: self)
    invalidateSiteMaintenanceSnapshot()
    return report
  }

  @discardableResult
  public func importContentPerformanceCSV(
    from sourceURL: URL,
    sourceName: String = "CSV 导入"
  ) async throws -> ContentPerformanceCSVImportReport {
    let report = try await publishingStore.importContentPerformanceCSV(
      from: sourceURL,
      sourceName: sourceName,
      store: self
    )
    invalidateSiteMaintenanceSnapshot()
    return report
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
