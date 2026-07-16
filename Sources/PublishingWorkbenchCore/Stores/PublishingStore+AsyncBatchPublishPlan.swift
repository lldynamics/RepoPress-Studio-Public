import Foundation

extension PublishingStore {
  func scheduleBatchPublishPlanRefresh(store: WorkbenchStore) {
    batchPublishPlanRefreshTask?.cancel()
    batchPublishPlanRefreshGeneration &+= 1
    let generation = batchPublishPlanRefreshGeneration
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let repositoryReport = store.repositoryReport
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
            store.repositoryReport == repositoryReport else {
        return
      }

      self.batchPublishPlan = plan
      self.batchRemotePublishPreviewSnapshot = self.remoteRepositoryPublishPreview(
        for: plan,
        store: store
      )
      self.batchRemoteReviewDraft = self.remoteReviewDraftBuilder.buildBatch(
        plan: plan,
        profile: profile
      )
    }
  }

  func cancelBatchPublishPlanRefresh() {
    batchPublishPlanRefreshGeneration &+= 1
    batchPublishPlanRefreshTask?.cancel()
    batchPublishPlanRefreshTask = nil
    isBatchPublishPlanRefreshing = false
  }

  func waitForBatchPublishPlanRefresh() async {
    let task = batchPublishPlanRefreshTask
    await task?.value
  }
}
