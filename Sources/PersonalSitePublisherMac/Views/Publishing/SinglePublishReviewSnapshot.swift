import Foundation
import PublishingWorkbenchCore

struct SinglePublishReviewSnapshot: Identifiable {
  let id = UUID()
  let draft: ArticleDraft
  let preview: RemoteRepositoryPublishPreview
  let reviewDraft: RemoteReviewDraft
  let expectation: SinglePublishReviewExpectation

  init(draft: ArticleDraft, profile: SiteProfile, snapshot: DraftPublishPreviewSnapshot) throws {
    self.draft = draft
    preview = snapshot.remotePublishPreview
    reviewDraft = snapshot.remoteReviewDraft
    expectation = try SinglePublishReviewExpectation(
      package: snapshot.publishPackage, profile: profile, preview: snapshot.remotePublishPreview
    )
  }
}
