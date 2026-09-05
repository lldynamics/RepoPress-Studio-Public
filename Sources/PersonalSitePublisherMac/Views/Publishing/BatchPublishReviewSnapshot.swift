import PublishingWorkbenchCore
import Foundation

/// A sheet must not silently change its contents as the workbench refreshes.
struct BatchPublishReviewSnapshot: Identifiable {
  let id = UUID()
  let items: [BatchPublishPlanItem]
  let preview: RemoteRepositoryPublishPreview
  let target: RemoteRepositoryPublishTargetSnapshot
  let expectation: BatchPublishReviewExpectation
  let reviewDraft: RemoteReviewDraft?
  let excludedCleanupCount: Int

  init(
    plan: BatchPublishPlan,
    package: PublishPackage,
    profile: SiteProfile,
    preview: RemoteRepositoryPublishPreview,
    reviewDraft: RemoteReviewDraft?,
    excludedCleanupCount: Int
  ) {
    items = plan.remotePublishableItems
    self.preview = preview
    target = RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
    expectation = BatchPublishReviewExpectation(plan: plan, package: package)
    self.reviewDraft = reviewDraft
    self.excludedCleanupCount = excludedCleanupCount
  }
}
