import Foundation

struct BatchPublishPlanRefreshInput: Equatable, Sendable {
  let drafts: [ArticleDraft]
  let profile: SiteProfile
  let repositoryReport: RepositoryScanReport?
}

extension PublishingStore {
  func scheduleBatchPublishPlanRefresh(store: WorkbenchStore) {
    let input = BatchPublishPlanRefreshInput(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      repositoryReport: store.repositoryReport
    )
    // Share only work in progress. Completed plans are not a cache of disk
    // state: explicit review must still read current files and permissions.
    if batchPublishPlanRefreshTask != nil,
      publishSession.batchPublishPlanRefreshInput == input
    {
      return
    }
    cancelBatchPublishPlanRefresh()
    let generation = batchPublishPlanRefreshGeneration
    publishSession.batchPublishPlanRefreshInput = input
    let service = batchPublishPlanService

    isBatchPublishPlanRefreshing = true
    batchPublishPlanRefreshTask = Task { [weak self, weak store] in
      defer {
        if let self, generation == self.batchPublishPlanRefreshGeneration {
          self.batchPublishPlanRefreshTask = nil
          self.publishSession.batchPublishPlanRefreshInput = nil
          self.isBatchPublishPlanRefreshing = false
        }
      }
      do {
        let plan = try await service.planCancellableAsync(
          drafts: input.drafts,
          profile: input.profile,
          repositoryReport: input.repositoryReport
        )
        guard let self, let store,
          generation == self.batchPublishPlanRefreshGeneration,
          !Task.isCancelled,
          store.activeProfile == input.profile,
          store.visibleDrafts == input.drafts,
          store.repositoryReport == input.repositoryReport
        else { return }

        self.batchPublishPlan = plan
        self.batchRemotePublishPreviewSnapshot = self.remoteRepositoryPublishPreview(
          for: plan, store: store
        )
        self.batchRemoteReviewDraft = self.remotePublishPackage(for: plan)
          .map { self.remoteReviewDraftBuilder.build(package: $0, profile: input.profile) }
      } catch {
        // The worker only throws cancellation. Never publish a partial plan.
      }
    }
  }

  func cancelBatchPublishPlanRefresh() {
    batchPublishPlanRefreshGeneration &+= 1
    batchPublishPlanRefreshTask?.cancel()
    batchPublishPlanRefreshTask = nil
    publishSession.batchPublishPlanRefreshInput = nil
    isBatchPublishPlanRefreshing = false
  }

  func invalidateBatchPublishPlan() {
    cancelBatchPublishPlanRefresh()
    batchPublishPlan = nil
    batchRemotePublishPreviewSnapshot = nil
    batchRemoteReviewDraft = nil
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
