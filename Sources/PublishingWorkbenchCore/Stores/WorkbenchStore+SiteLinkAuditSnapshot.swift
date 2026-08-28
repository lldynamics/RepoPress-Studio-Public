import Foundation

extension WorkbenchStore {
  func siteLinkAuditKey(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SiteLinkAuditSnapshotKey {
    SiteLinkAuditSnapshotKey(
      profile: profile,
      draftMutationRevision: draftMutationRevision,
      drafts: drafts,
      bodyRevisions: drafts.map { draft in
        DraftExecutionContext(
          draftID: draft.id,
          profileID: profile.id,
          bodyRevision: publishingStore.draftBodyEditorBuffers[draft.id]?.revision ?? 0
        )
      }
    )
  }

  func cachedSiteLinkAuditReport(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SiteLinkAuditReport? {
    siteLinkAuditSnapshotStore.report(
      for: siteLinkAuditKey(drafts: drafts, profile: profile)
    )
  }

  /// Synchronous compatibility boundary for callers that must return a value
  /// immediately. A cache miss performs exactly one site scan, after which all
  /// per-draft projections reuse the same report.
  func localSiteLinkAuditReport(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SiteLinkAuditReport {
    let key = siteLinkAuditKey(drafts: drafts, profile: profile)
    if let cached = siteLinkAuditSnapshotStore.report(for: key) {
      return cached
    }

    siteLinkAuditRefreshTask?.cancel()
    siteLinkAuditRefreshTask = nil
    siteLinkAuditRefreshKey = nil
    let report = SiteLinkAuditService().report(drafts: drafts, profile: profile)
    siteLinkAuditSnapshotStore.replace(report, for: key)
    return report
  }

  /// Preferred path for report-producing UI. Concurrent consumers of the same
  /// revision share one detached calculation, and stale work cannot populate
  /// the current cache.
  func localSiteLinkAuditReportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) async throws -> SiteLinkAuditReport {
    let key = siteLinkAuditKey(drafts: drafts, profile: profile)
    if let cached = siteLinkAuditSnapshotStore.report(for: key) {
      return cached
    }

    let task: Task<SiteLinkAuditReport, Never>
    if siteLinkAuditRefreshKey == key, let existing = siteLinkAuditRefreshTask {
      task = existing
    } else {
      siteLinkAuditRefreshTask?.cancel()
      task = Task.detached(priority: .utility) {
        SiteLinkAuditService().report(drafts: drafts, profile: profile)
      }
      siteLinkAuditRefreshTask = task
      siteLinkAuditRefreshKey = key
    }

    // A caller cancellation must not cancel shared work that another report
    // consumer is still awaiting.
    let report = await task.value
    if siteLinkAuditRefreshKey == key {
      siteLinkAuditRefreshTask = nil
      siteLinkAuditRefreshKey = nil
    }
    try Task.checkCancellation()
    if let cached = siteLinkAuditSnapshotStore.report(for: key) {
      return cached
    }
    if siteLinkAuditKey(drafts: drafts, profile: profile) == key {
      siteLinkAuditSnapshotStore.replace(report, for: key)
    }
    return report
  }

  func replaceSiteLinkAuditSnapshotIfCurrent(
    _ report: SiteLinkAuditReport,
    key: SiteLinkAuditSnapshotKey,
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) {
    guard siteLinkAuditKey(drafts: drafts, profile: profile) == key else { return }
    siteLinkAuditSnapshotStore.replace(report, for: key)
  }

  func invalidateSiteLinkAuditSnapshot() {
    siteLinkAuditRefreshTask?.cancel()
    siteLinkAuditRefreshTask = nil
    siteLinkAuditRefreshKey = nil
    siteLinkAuditSnapshotStore.invalidate()
  }
}
