import PublishingWorkbenchCore
import SwiftUI

/// Explicit review boundary for the guarded stash/rebase/restore preset.
struct RepositoryRebaseSyncConfirmationView: View {
  let confirmation: RepositoryRebaseSyncConfirmation
  let isApplying: Bool
  let feedback: PublishActionFeedback?
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var snapshot: RepositoryRebaseSyncSnapshot { confirmation.snapshot }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          branchCard
          workflowCard
          localChangesCard
          if let feedback, feedback.status == .failure || feedback.status == .warning {
            feedbackCard(feedback)
          }
          safetyNote
        }
        .padding(WorkbenchSpacing.spacious)
      }
      Divider()
      footer
    }
    .frame(minWidth: 660, idealWidth: 740, minHeight: 600, idealHeight: 720)
    .interactiveDismissDisabled(isApplying)
    .accessibilityIdentifier("repository-rebase-sync-confirmation")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "arrow.triangle.branch")
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.primary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("确认变基同步")
          .font(.headline)
        Text("用已审阅的远端提交重放本地提交，并在前后安全封存、恢复未提交改动。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var branchCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("分支时间线", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.headline)
      RepositoryBranchGraphWidget(
        presentation: RepositoryBranchGraphPresentation(
          branchName: snapshot.branch,
          upstreamName: snapshot.upstream,
          aheadCount: snapshot.aheadCount,
          behindCount: snapshot.behindCount,
          localHeadSHA: snapshot.localHeadSHA,
          remoteHeadSHA: snapshot.remoteHeadSHA
        )
      )
      Divider()
      LabeledContent("本地 HEAD", value: String(snapshot.localHeadSHA.prefix(12)))
      LabeledContent("已审阅远端", value: String(snapshot.remoteHeadSHA.prefix(12)))
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var workflowCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("一键预设将依次执行", systemImage: "list.number")
        .font(.headline)
      workflowStep(
        number: 1,
        title: "封存本地未提交改动",
        detail: "包含已暂存、未暂存和未跟踪的普通文件；已有 stash 不会被删除。"
      )
      workflowStep(
        number: 2,
        title: "对已审阅远端 SHA 变基",
        detail: "只执行 rebase，不会推送、强制推送、reset、clean 或自动 abort。"
      )
      workflowStep(
        number: 3,
        title: "恢复本地未提交改动",
        detail: "只恢复本次创建且验证过的 stash；冲突时保留恢复副本并停止。"
      )
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func workflowStep(number: Int, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.caption.weight(.bold).monospacedDigit())
        .frame(width: 22, height: 22)
        .background(WorkbenchTheme.primary.opacity(0.12), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var localChangesCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        "将封存的本地改动（\(snapshot.localChanges.count)）",
        systemImage: "shippingbox"
      )
      .font(.headline)
      if snapshot.localChanges.isEmpty {
        Text("当前工作区干净；将直接变基本地提交。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.localChanges) { change in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(change.status)
              .font(.caption.weight(.semibold).monospaced())
              .foregroundStyle(WorkbenchTheme.warning)
              .frame(minWidth: 30, alignment: .leading)
            Text(change.path)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
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
      "确认前不会改变 HEAD、索引、工作区或 stash。执行前会重新核对分支、远端 SHA、差异和未跟踪文件内容。",
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
          .accessibilityLabel("正在变基同步")
      }
      Button("封存并变基同步", action: confirmAction)
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isApplying)
        .accessibilityIdentifier("repository-rebase-sync-confirm")
        .accessibilityHint("重新验证审阅内容后，封存本地改动、变基并恢复改动")
    }
    .padding(WorkbenchSpacing.spacious)
  }
}
