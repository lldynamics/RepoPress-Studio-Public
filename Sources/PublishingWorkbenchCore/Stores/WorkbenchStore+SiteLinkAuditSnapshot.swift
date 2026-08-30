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

  /// Synchronous compatibility boundary for explicitly blocking workflows.
  /// List and preflight refresh paths use the revision-keyed async snapshot
  /// below, so ordinary MainActor rendering never reaches this fallback.
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

  /// Starts (or joins) the detached local-link calculation for one immutable
  /// site revision. Completing the work invalidates only task-state consumers;
  /// older reports cannot replace a newer profile/draft context.
  func scheduleSiteLinkAuditSnapshotRefresh(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    key: SiteLinkAuditSnapshotKey? = nil
  ) {
    let key = key ?? siteLinkAuditKey(drafts: drafts, profile: profile)
    guard siteLinkAuditSnapshotStore.report(for: key) == nil else { return }
    guard siteLinkAuditRefreshKey != key || siteLinkAuditRefreshTask == nil else { return }

    siteLinkAuditRefreshTask?.cancel()
    siteLinkAuditRefreshKey = key
    let reportTask = Task.detached(priority: .utility) {
      SiteLinkAuditService().report(drafts: drafts, profile: profile)
    }
    siteLinkAuditRefreshTask = Task { [weak self] in
      let report = await reportTask.value
      guard let self,
        !Task.isCancelled,
        self.siteLinkAuditRefreshKey == key,
        self.siteLinkAuditKey(drafts: drafts, profile: profile) == key
      else {
        return report
      }
      self.siteLinkAuditSnapshotStore.replace(report, for: key)
      self.siteLinkAuditRefreshTask = nil
      self.siteLinkAuditRefreshKey = nil
      self.invalidateDraftTaskQueueStateCache()
      return report
    }
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
      scheduleSiteLinkAuditSnapshotRefresh(drafts: drafts, profile: profile, key: key)
      guard let scheduledTask = siteLinkAuditRefreshTask else {
        return SiteLinkAuditReport(references: [], items: [])
      }
      task = scheduledTask
    }

    // A caller cancellation must not cancel shared work that another report
    // consumer is still awaiting.
    let report = await task.value
    try Task.checkCancellation()
    if let cached = siteLinkAuditSnapshotStore.report(for: key) {
      return cached
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
