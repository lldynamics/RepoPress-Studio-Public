import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  func copyReviewCommands() {
    let commands = store.reviewBranchCommandsForSelectedDraft()
    guard !commands.isEmpty else {
      store.setPublishActionMessage("选择本地仓库后才能生成分支发布命令。")
      return
    }
    copy(commands.joined(separator: "\n"), message: "已复制分支发布命令。")
  }

  func copyBatchCommitCommand() {
    guard let command = store.batchLocalCommitCommandForWritableDrafts() else {
      store.setPublishActionMessage("待发布队列没有可提交的文件。")
      return
    }
    copy(command, message: "已复制批量 git 提交命令。")
  }

  func copyBatchReviewBranchCommands() {
    let commands = store.batchReviewBranchCommandsForWritableDrafts()
    guard !commands.isEmpty else {
      store.setPublishActionMessage("待发布队列没有可创建分支的文件。")
      return
    }
    copy(commands.joined(separator: "\n"), message: "已复制批量分支发布命令。")
  }

  func copyBatchReviewDescription() {
    Task {
      await store.refreshBatchPublishPlanAsync()
      guard let review = store.batchRemoteReviewDraft else {
        store.setPublishActionMessage("待发布队列没有可生成 PR/MR 描述的文章。")
        return
      }
      copy(review.body, message: "已复制批量 PR/MR 描述。")
    }
  }

  func openReviewURL(_ review: RemoteReviewDraft) {
    guard let url = review.webURL else {
      store.setPublishActionMessage("填写仓库 owner/name 后才能打开 PR/MR 创建页。")
      return
    }
    ExternalURLOpener.open(url)
  }

  func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }

  func ledgerStatusForeground(_ status: ReleaseLedgerStatus) -> AnyShapeStyle {
    switch status {
    case .succeeded:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .deploying, .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .pendingReview:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .localOnly, .unknown:
      return AnyShapeStyle(.secondary)
    }
  }
}
