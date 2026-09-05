import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorktreePushRetryConfirmationView: View {
  let confirmation: RepositoryWorktreePushRetryConfirmation
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void
  var feedback: PublishActionFeedback? = nil
  var reviewAgainAction: () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text("重试推送本地提交")
            .font(.headline)
          Text("不会再次提交文件；只会将下列已有提交以非强制方式推送到原分支。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(WorkbenchSpacing.spacious)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          targetCard
          safetyCard
          fileList
          Label(
            "确认时会重新验证工作区为空、远端仍是已审阅基线，且远端是本地 HEAD 的祖先。远端分叉时会停止，绝不强制推送。",
            systemImage: "lock.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WorkbenchSpacing.spacious)
      }

      Divider()

      RepositoryPublishConfirmationFeedback(
        feedback: feedback,
        isPublishing: isPublishing,
        isReviewComplete: isReviewComplete,
        reviewAgainAction: reviewAgainAction
      )
      HStack(spacing: 12) {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
          .disabled(isPublishing)
        Spacer()
        if isPublishing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在重试推送本地提交")
        }
        Button("确认并重试推送", action: confirmAction)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(
            isPublishing
              || !isReviewComplete
              || RepositoryPublishConfirmationFeedback.needsReview(feedback)
          )
          .accessibilityIdentifier("publish-worktree-retry-confirm")
      }
      .padding(WorkbenchSpacing.spacious)
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 500, idealHeight: 620)
    .accessibilityIdentifier("publish-worktree-retry-confirmation")
  }

  private var targetCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("待推送提交", systemImage: "arrow.triangle.branch")
        .font(.headline)
      LabeledContent("分支", value: "origin/\(confirmation.snapshot.branch)")
      LabeledContent(
        "本地 HEAD",
        value: RepositoryWorktreePublishPresentation.shortSHA(
          confirmation.snapshot.localHeadSHA
        )
      )
      LabeledContent(
        "远端基线",
        value: RepositoryWorktreePublishPresentation.shortSHA(
          confirmation.snapshot.remoteBranchSHA
        )
      )
      LabeledContent(
        "提交数",
        value: String(confirmation.snapshot.commitCount)
      )
      LabeledContent("目标 origin", value: confirmation.snapshot.pushOriginURL)
        .textSelection(.enabled)
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var safetyCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        confirmation.safetyReport.warnings.isEmpty ? "安全检查已通过" : "需要重点复核",
        systemImage: confirmation.safetyReport.warnings.isEmpty
          ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
      )
      .font(.headline)
      ForEach(confirmation.safetyReport.warnings) { warning in
        VStack(alignment: .leading, spacing: 2) {
          Text(warning.title).font(.callout.weight(.semibold))
          Text(warning.message).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(confirmation.sitePreflightResult?.message ?? "尚未生成站点检查证据。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchTheme.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var fileList: some View {
    RepositoryWorktreeReviewFileList(
      entries: confirmation.snapshot.entries,
      reviews: confirmation.fileReviews
    )
    .accessibilityIdentifier("publish-worktree-file-list")
  }

  private var isReviewComplete: Bool {
    RepositoryWorktreeFileReview.isComplete(
      entries: confirmation.snapshot.entries,
      reviews: confirmation.fileReviews
    )
  }


}
