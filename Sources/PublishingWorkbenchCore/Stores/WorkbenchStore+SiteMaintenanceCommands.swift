import Foundation

extension WorkbenchStore {
  public var isSiteMaintenanceSnapshotStale: Bool {
    isSiteMaintenanceSnapshotStaleState()
  }

  public var isSiteMaintenanceSnapshotRefreshing: Bool {
    siteMaintenanceStore.isRefreshing
  }

  public var siteMaintenanceSnapshotErrorMessage: String? {
    siteMaintenanceStore.refreshErrorMessage
  }

  public func refreshSiteMaintenanceSnapshot(force: Bool = false) async {
    siteMaintenanceRefreshScheduleTask?.cancel()
    siteMaintenanceRefreshScheduleTask = nil

    // A startup word-count migration changes the maintenance input only after
    // its async calculation completes. Establish that derived-state baseline
    // before capturing the report signature.
    await waitForPendingDraftWordCountRefreshes()

    let input = publishingStore.siteMaintenanceReportInput(store: self)
    let signature = input.signature
    if !force, siteMaintenanceStore.hasCurrentSnapshot(for: signature) {
      return
    }

    siteMaintenanceRefreshTask?.cancel()
    siteMaintenanceRefreshGeneration &+= 1
    let generation = siteMaintenanceRefreshGeneration
    siteMaintenanceStore.setRefreshing(true)
    siteMaintenanceStore.setRefreshErrorMessage(nil)

    let service = publishingStore.siteMaintenanceService
    let task = Task {
      try await service.reportAsync(
        drafts: input.drafts,
        profile: input.profile,
        releaseRecords: input.releaseRecords,
        maintenanceOperationRecords: input.maintenanceOperationRecords,
        now: input.now
      )
    }
    siteMaintenanceRefreshTask = task
    let result = await withTaskCancellationHandler {
      await task.result
    } onCancel: {
      task.cancel()
    }

    guard generation == siteMaintenanceRefreshGeneration else { return }
    siteMaintenanceRefreshTask = nil
    siteMaintenanceStore.setRefreshing(false)

    let currentInput = publishingStore.siteMaintenanceReportInput(store: self)
    guard currentInput.signature == signature else {
      scheduleSiteMaintenanceSnapshotRefresh()
      return
    }
    switch result {
    case .success(let report):
      replaceSiteMaintenanceSnapshot(report: report, inputSignature: signature)
    case .failure(let error):
      guard !(error is CancellationError) else { return }
      siteMaintenanceStore.setRefreshErrorMessage(error.localizedDescription)
    }
  }

  func scheduleSiteMaintenanceSnapshotRefresh() {
    siteMaintenanceRefreshScheduleTask?.cancel()
    siteMaintenanceRefreshScheduleTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      self.siteMaintenanceRefreshScheduleTask = nil
      await self.refreshSiteMaintenanceSnapshot()
    }
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
  public func applySuggestedMaintenanceSchedule() async -> Int {
    await refreshSiteMaintenanceSnapshot()
    guard let report = siteMaintenanceSnapshot?.report else { return 0 }
    let appliedCount = publishingStore.applySuggestedMaintenanceSchedule(
      report: report,
      store: self
    )
    if appliedCount > 0 {
      invalidateDraftDerivedCaches()
    } else {
      invalidateSiteMaintenanceSnapshot()
    }
    return appliedCount
  }

  @discardableResult
  public func applySuggestedMaintenanceSchedule(
    report: SiteMaintenanceReport,
    selectedDraftIDs: Set<UUID>,
    expectedOriginalDates: [UUID: Date]
  ) async -> Int {
    let appliedCount = publishingStore.applySuggestedMaintenanceSchedule(
      report: report,
      store: self,
      selectedDraftIDs: selectedDraftIDs,
      expectedOriginalDates: expectedOriginalDates
    )
    if appliedCount > 0 {
      invalidateDraftDerivedCaches()
    } else {
      invalidateSiteMaintenanceSnapshot()
    }
    return appliedCount
  }

  /// Applies exactly the target dates that the user reviewed. Callers should
  /// freeze this map together with `expectedOriginalDates` when opening a
  /// confirmation surface so a later report refresh cannot change the action.
  @discardableResult
  public func applySuggestedMaintenanceSchedule(
    approvedSuggestedDates: [UUID: Date],
    expectedOriginalDates: [UUID: Date]
  ) async -> Int {
    let appliedCount = publishingStore.applySuggestedMaintenanceSchedule(
      approvedSuggestedDates: approvedSuggestedDates,
      store: self,
      expectedOriginalDates: expectedOriginalDates
    )
    if appliedCount > 0 {
      invalidateDraftDerivedCaches()
    } else {
      invalidateSiteMaintenanceSnapshot()
    }
    return appliedCount
  }

  public func relatedArticleSuggestions(for draft: ArticleDraft, limit: Int = 5) -> [SiteRelationSuggestion] {
    siteMaintenanceStore.relatedArticleSuggestions(
      for: draft.id,
      profileID: profile(for: draft).id,
      limit: limit
    )
  }
}
