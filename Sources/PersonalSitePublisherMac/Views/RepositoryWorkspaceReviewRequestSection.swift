import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var reviewRequestSection: some View {
    if let review = store.remoteReviewDraft {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("\(review.provider.displayName) Review")
              .font(.headline)
            Text("\(review.branchName) -> \(review.targetBranch)")
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button {
            openReviewURL(review)
          } label: {
            Label("打开 PR/MR", systemImage: "arrow.up.right.square")
          }
          .disabled(review.webURL == nil)

          Button {
            store.commitSelectedDraftToReviewBranch()
          } label: {
            Label("创建分支提交", systemImage: "arrow.triangle.branch")
          }
          .disabled(store.localPublishReadiness?.canCommit != true)

          Button {
            copyReviewCommands()
          } label: {
            Label("复制分支命令", systemImage: "terminal")
          }
          .disabled(store.localPublishReadiness?.canCommit != true)
        }

        Text(review.title)
          .font(.callout.weight(.medium))
          .textSelection(.enabled)

        Text(review.body)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(16)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }
}
