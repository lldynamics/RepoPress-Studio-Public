import Foundation

extension PublishingStore {
  func scheduleBatchPublishPlanRefresh(store: WorkbenchStore) {
    batchPublishPlanRefreshTask?.cancel()
    batchPublishPlanRefreshGeneration &+= 1
    let generation = batchPublishPlanRefreshGeneration
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let repositoryReport = store.repositoryReport
    let cleanupRequests = pendingRemoteRepositoryCleanupRequests(profileID: profile.id)
    let service = batchPublishPlanService

    isBatchPublishPlanRefreshing = true
    batchPublishPlanRefreshTask = Task { [weak self, weak store] in
      let plan = await service.planAsync(
        drafts: drafts,
        profile: profile,
        repositoryReport: repositoryReport
      )
      guard let self, let store,
            generation == self.batchPublishPlanRefreshGeneration else {
        return
      }

      defer {
        if generation == self.batchPublishPlanRefreshGeneration {
          self.batchPublishPlanRefreshTask = nil
          self.isBatchPublishPlanRefreshing = false
        }
      }

      guard !Task.isCancelled,
            store.activeProfile == profile,
            store.visibleDrafts == drafts,
            store.repositoryReport == repositoryReport,
            self.pendingRemoteRepositoryCleanupRequests(profileID: profile.id) == cleanupRequests else {
        return
      }

      self.batchPublishPlan = plan
      self.batchRemotePublishPreviewSnapshot = self.remoteRepositoryPublishPreview(
        for: plan,
        cleanupRequests: cleanupRequests,
        store: store
      )
      self.batchRemoteReviewDraft = self.remotePublishPackage(
        for: plan,
        cleanupRequests: cleanupRequests
      ).map { self.remoteReviewDraftBuilder.build(package: $0, profile: profile) }
    }
  }

  func cancelBatchPublishPlanRefresh() {
    batchPublishPlanRefreshGeneration &+= 1
    batchPublishPlanRefreshTask?.cancel()
    batchPublishPlanRefreshTask = nil
    isBatchPublishPlanRefreshing = false
  }

  /// Removes remote-derived batch state while a repository access proof is
  /// being replaced. The local batch plan remains available for the next
  /// refresh, but the UI cannot retain a stale ready/conflict presentation.
  func removeBatchRemotePublishPreviewSnapshot() {
    cancelBatchPublishPlanRefresh()
    batchRemotePublishPreviewSnapshot = nil
    batchRemoteReviewDraft = nil
  }

  func waitForBatchPublishPlanRefresh() async {
    let task = batchPublishPlanRefreshTask
    await task?.value
  }
}
