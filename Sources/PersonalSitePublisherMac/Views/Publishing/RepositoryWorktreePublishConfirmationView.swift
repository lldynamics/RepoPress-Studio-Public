import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Final user-visible boundary for the default repository-wide publish.
/// Nothing is staged until the user confirms this exact frozen snapshot.
struct RepositoryWorktreePublishConfirmationView: View {
  let confirmation: RepositoryWorktreePublishConfirmation
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void
  var feedback: PublishActionFeedback? = nil
  var reviewAgainAction: () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          targetCard
          preflightCard
          safetyReportCard
          fileList
          safetyNote
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
      footer
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 650)
    .accessibilityIdentifier("publish-worktree-confirmation")
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "shippingbox.and.arrow.backward.fill")
        .font(.title2)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 3) {
        Text("确认发布仓库全部文件")
          .font(.headline)
        Text("确认前会重新扫描冻结快照；确认后仅创建一次提交并以非强制方式推送。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var targetCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("发布目标", systemImage: "arrow.triangle.branch")
        .font(.headline)
      LabeledContent("分支", value: "origin/\(confirmation.snapshot.branch)")
      LabeledContent("HEAD", value: RepositoryWorktreePublishPresentation.shortSHA(confirmation.snapshot.headSHA))
      LabeledContent(
        "远端 SHA",
        value: RepositoryWorktreePublishPresentation.shortSHA(confirmation.snapshot.remoteBranchSHA)
      )
      LabeledContent("origin", value: confirmation.snapshot.pushOriginURL)
        .textSelection(.enabled)
      LabeledContent("提交说明", value: confirmation.commitMessage)
      LabeledContent(
        "完整清单",
        value: String(
          format: String(localized: "%d 个文件路径"),
          confirmation.snapshot.paths.count
        )
      )
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var preflightCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("站点发布前检查", systemImage: preflightIcon)
        .font(.headline)
        .foregroundStyle(preflightColor)
      Text(confirmation.sitePreflightResult?.message ?? "尚未生成站点检查证据。")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(confirmation.sitePreflightResult?.diagnostics ?? [], id: \.self) { diagnostic in
        Text(diagnostic)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-worktree-preflight")
  }

  private var safetyReportCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        confirmation.safetyReport.warnings.isEmpty ? "安全检查" : "需要重点复核",
        systemImage: confirmation.safetyReport.warnings.isEmpty
          ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
      )
        .font(.headline)
        .foregroundStyle(
          confirmation.safetyReport.warnings.isEmpty ? WorkbenchTheme.success : WorkbenchTheme.warning
        )
      if confirmation.safetyReport.warnings.isEmpty {
        Text("未检测到需要额外复核的发布风险。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(confirmation.safetyReport.warnings) { warning in
          VStack(alignment: .leading, spacing: 3) {
            Text(warning.title)
              .font(.callout.weight(.semibold))
            Text(warning.message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
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

  private var safetyNote: some View {
    Label(
      "确认前会重新运行站点检查，并逐项核对完整变更清单、HEAD、远端 SHA、文件 blob 与权限。不会强制推送；远端变化或快照变化会停止本次发布。",
      systemImage: "lock.shield"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("取消", action: cancelAction)
        .keyboardShortcut(.cancelAction)
        .disabled(isPublishing)

      Spacer()

      if isPublishing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在提交并推送全部文件")
      }

      Button("确认并发布全部文件", action: confirmAction)
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(
          isPublishing
            || !isReviewComplete
            || RepositoryPublishConfirmationFeedback.needsReview(feedback)
        )
        .accessibilityIdentifier("publish-worktree-confirm")
        .accessibilityHint("重新检查冻结快照，创建一次提交并以非强制方式推送全部路径")
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var preflightIcon: String {
    switch confirmation.sitePreflightResult?.outcome {
    case .passed:
      "checkmark.shield.fill"
    case .skipped:
      "minus.circle"
    case .failed, nil:
      "xmark.shield.fill"
    }
  }

  private var preflightColor: Color {
    switch confirmation.sitePreflightResult?.outcome {
    case .passed:
      WorkbenchTheme.success
    case .skipped:
      .secondary
    case .failed, nil:
      WorkbenchTheme.risk
    }
  }

  private var isReviewComplete: Bool {
    RepositoryWorktreeFileReview.isComplete(
      entries: confirmation.snapshot.entries,
      reviews: confirmation.fileReviews
    )
  }

}

enum RepositoryWorktreePublishPresentation {
  static func shortSHA(_ sha: String) -> String {
    String(sha.prefix(12))
  }

  static func pathDescription(for entry: RepositoryWorktreePublishEntry) -> String {
    guard let sourcePath = entry.sourcePath, sourcePath != entry.path else {
      return entry.path
    }
    return "\(sourcePath) → \(entry.path)"
  }

  static func metadataDescription(for entry: RepositoryWorktreePublishEntry) -> String {
    let mode = entry.mode.map { "mode \($0)" } ?? String(localized: "已从索引删除")
    return "\(entry.status) · \(mode)"
  }

  static func accessibilityLabel(for entry: RepositoryWorktreePublishEntry) -> String {
    "\(entry.kind.localizedName)，\(pathDescription(for: entry))，\(metadataDescription(for: entry))"
  }
}
