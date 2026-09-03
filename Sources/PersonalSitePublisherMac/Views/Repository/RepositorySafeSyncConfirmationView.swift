import PublishingWorkbenchCore
import SwiftUI

/// Review boundary for an exact fast-forward of the current site branch.
/// The service revalidates this frozen snapshot before touching HEAD or the worktree.
struct RepositorySafeSyncConfirmationView: View {
  let confirmation: RepositorySafeSyncConfirmation
  let isApplying: Bool
  let feedback: PublishActionFeedback?
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var snapshot: RepositorySafeSyncSnapshot { confirmation.snapshot }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          targetCard
          remoteChangesCard
          localChangesCard
          if !snapshot.identicalUntrackedCollisions.isEmpty {
            identicalCollisionsCard
          }
          if let feedback, feedback.status == .failure || feedback.status == .warning {
            feedbackCard(feedback)
          }
          safetyNote
        }
        .padding(WorkbenchSpacing.spacious)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-safe-sync-impact-list")
      }
      Divider()
      footer
    }
    .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 700)
    .interactiveDismissDisabled(isApplying)
    .accessibilityIdentifier("repository-safe-sync-confirmation")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.primary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("确认安全同步远端")
          .font(.headline)
        Text("只把当前分支快进到已审阅的远端提交，并保留不相交的本地改动。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var targetCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("同步目标", systemImage: "arrow.triangle.branch")
        .font(.headline)
      LabeledContent("当前分支", value: snapshot.branch)
      LabeledContent("Upstream", value: snapshot.upstream)
      LabeledContent("本地 HEAD", value: String(snapshot.localHeadSHA.prefix(12)))
      LabeledContent("目标提交", value: String(snapshot.remoteHeadSHA.prefix(12)))
      LabeledContent(
        "快进距离",
        value: String(
          format: String(localized: "%d 个远端提交"),
          snapshot.behindCount
        )
      )
      RepositoryBranchGraphWidget(
        presentation: RepositoryBranchGraphPresentation(
          branchName: snapshot.branch,
          upstreamName: snapshot.upstream,
          aheadCount: 0,
          behindCount: snapshot.behindCount,
          localHeadSHA: snapshot.localHeadSHA,
          remoteHeadSHA: snapshot.remoteHeadSHA
        )
      )
      .padding(.top, 4)
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var remoteChangesCard: some View {
    changeListCard(
      title: String(localized: "远端将写入的路径"),
      systemImage: "icloud.and.arrow.down",
      emptyMessage: String(localized: "没有检测到远端文件变化。"),
      changes: snapshot.remoteChanges
    )
  }

  private var localChangesCard: some View {
    changeListCard(
      title: String(localized: "将保留的本地改动"),
      systemImage: "internaldrive",
      emptyMessage: String(localized: "本地工作区没有未提交改动。"),
      changes: snapshot.localChanges
    )
  }

  private func changeListCard(
    title: String,
    systemImage: String,
    emptyMessage: String,
    changes: [RepositorySafeSyncChange]
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      if changes.isEmpty {
        Text(emptyMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(changes) { change in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(change.status)
              .font(.caption.weight(.semibold).monospaced())
              .foregroundStyle(change.isDeletion ? WorkbenchTheme.risk : WorkbenchTheme.warning)
              .frame(minWidth: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
              Text(change.path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              if let sourcePath = change.sourcePath {
                Text("原路径：\(sourcePath)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            Spacer(minLength: 0)
          }
          .padding(.vertical, 3)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(change.status)，\(change.path)")
        }
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var identicalCollisionsCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("内容相同的同路径文件", systemImage: "checkmark.shield")
        .font(.headline)
      Text("这些未跟踪文件与远端内容和权限完全一致。软件会先创建并校验恢复备份，再让远端版本接管路径。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(snapshot.identicalUntrackedCollisions) { collision in
        Text(collision.path)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchTheme.success.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func feedbackCard(_ feedback: PublishActionFeedback) -> some View {
    Label(
      feedback.message,
      systemImage: feedback.status == .failure ? "xmark.octagon" : "exclamationmark.triangle"
    )
    .font(.callout)
    .foregroundStyle(feedback.status == .failure ? WorkbenchTheme.risk : WorkbenchTheme.warning)
    .fixedSize(horizontal: false, vertical: true)
    .textSelection(.enabled)
    .padding(WorkbenchSpacing.section)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var safetyNote: some View {
    Label(
      "确认前不会改变 HEAD 或工作区；执行前会重新核对分支、远端提交和每个本地改动。此操作不会暂存、提交、推送、stash、reset 或 clean。",
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
        .disabled(isApplying)
      Spacer()
      if isApplying {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在安全同步远端")
      }
      Button("确认安全同步", action: confirmAction)
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isApplying)
        .accessibilityIdentifier("repository-safe-sync-confirm")
        .accessibilityHint("重新验证审阅内容后，把当前分支快进到指定远端提交")
    }
    .padding(WorkbenchSpacing.spacious)
  }
}
