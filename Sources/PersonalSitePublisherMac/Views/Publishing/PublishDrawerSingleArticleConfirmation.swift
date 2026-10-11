import SwiftUI

struct PublishDrawerSingleArticleConfirmation: View {
  let review: SinglePublishReviewSnapshot
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  var body: some View {
    let draft = review.draft
    let presentation = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: draft.draft)
    RemotePublishConfirmationView(
      targetLabel: draft.draft ? String(localized: "网站草稿") : String(localized: "文章"),
      targetTitle: draft.title,
      purpose: presentation.confirmationPurpose,
      preview: review.preview,
      reviewDraft: review.reviewDraft,
      isPublishing: isPublishing,
      cancelAction: cancelAction,
      confirmAction: confirmAction
    )
  }
}
