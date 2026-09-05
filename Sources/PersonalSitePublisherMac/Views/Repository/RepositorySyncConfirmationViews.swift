import PublishingWorkbenchCore
import SwiftUI

/// Confirmation boundary for a frozen fast-forward snapshot. Preparation is
/// read-only; the service revalidates the same evidence before applying it.
struct RepositorySafeSyncConfirmationView: View {
  let confirmation: RepositorySafeSyncConfirmation
  let isApplying: Bool
  let feedback: PublishActionFeedback?
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var snapshot: RepositorySafeSyncSnapshot { confirmation.snapshot }

  var body: some View {
    VStack(spacing: 0) {
      confirmationHeader(
        title: "确认安全同步远端",
        detail: "只把当前分支快进到已审阅的远端提交；确认前不会改变 HEAD 或工作区。",
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
      )
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          targetCard
          changeCard(
            title: "远端将写入的路径",
            systemImage: "icloud.and.arrow.down",
            emptyMessage: "没有检测到远端文件变化。",
            changes: snapshot.remoteChanges
          )
          changeCard(
            title: "将保留的本地改动",
            systemImage: "internaldrive",
            emptyMessage: "本地工作区没有未提交改动。",
            changes: snapshot.localChanges
          )
          if !snapshot.identicalUntrackedCollisions.isEmpty {
            identicalCollisionCard
          }
          feedbackCard
          Label(
            "执行前会重新核对分支、远端提交和工作区快照。此操作不会暂存、提交、推送、stash、reset 或 clean。",
            systemImage: "lock.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Label(
            "同步只更新磁盘上的 Git 仓库；软件草稿不会被静默覆盖，文章变化需在文件变更中审阅导入。",
            systemImage: "doc.badge.arrow.up"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WorkbenchSpacing.spacious)
      }
      Divider()
      confirmationFooter(
        confirmTitle: "确认安全同步",
        progressLabel: "正在安全同步远端"
      )
    }
    .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 700)
    .interactiveDismissDisabled(isApplying)
    .accessibilityIdentifier("repository-safe-sync-confirmation")
  }

  private var targetCard: some View {
    syncCard {
      Label("同步目标", systemImage: "arrow.triangle.branch")
        .font(.headline)
      LabeledContent("当前分支", value: snapshot.branch)
      LabeledContent("Upstream", value: snapshot.upstream)
      LabeledContent("本地 HEAD", value: String(snapshot.localHeadSHA.prefix(12)))
      LabeledContent("目标提交", value: String(snapshot.remoteHeadSHA.prefix(12)))
      LabeledContent("快进距离", value: "\(snapshot.behindCount) 个远端提交")
    }
  }

  private var identicalCollisionCard: some View {
    syncCard {
      Label("内容相同的同路径文件", systemImage: "checkmark.shield")
        .font(.headline)
      Text("这些未跟踪文件与远端内容及权限完全一致；软件会先建立并校验恢复备份。")
        .font(.callout)
        .foregroundStyle(.secondary)
      ForEach(snapshot.identicalUntrackedCollisions) { collision in
        Text(collision.path)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }

  private func changeCard(
    title: LocalizedStringKey,
    systemImage: String,
    emptyMessage: LocalizedStringKey,
    changes: [RepositorySafeSyncChange]
  ) -> some View {
    syncCard {
      Label(title, systemImage: systemImage).font(.headline)
      if changes.isEmpty {
        Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(changes) { change in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: change.status)
              .font(.caption.weight(.semibold).monospaced())
              .frame(minWidth: 34, alignment: .leading)
            Text(verbatim: change.path)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  @ViewBuilder
  private var feedbackCard: some View {
    if let feedback, feedback.status == .failure || feedback.status == .warning {
      Label(
        feedback.message,
        systemImage: feedback.status == .failure ? "xmark.octagon" : "exclamationmark.triangle"
      )
      .font(.callout)
      .foregroundStyle(feedback.status == .failure ? WorkbenchTheme.risk : WorkbenchTheme.warning)
      .textSelection(.enabled)
    }
  }

  private func confirmationFooter(
    confirmTitle: LocalizedStringKey,
    progressLabel: LocalizedStringKey
  ) -> some View {
    HStack(spacing: 12) {
      Button("取消", action: cancelAction)
        .keyboardShortcut(.cancelAction)
        .disabled(isApplying)
      Spacer()
      if isApplying {
        ProgressView().controlSize(.small).accessibilityLabel(progressLabel)
      }
      Button(confirmTitle, action: confirmAction)
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isApplying)
        .accessibilityIdentifier("repository-safe-sync-confirm")
    }
    .padding(WorkbenchSpacing.spacious)
  }
}

/// Explicit review for the guarded stash/rebase/restore transaction.
struct RepositoryRebaseSyncConfirmationView: View {
  let confirmation: RepositoryRebaseSyncConfirmation
  let isApplying: Bool
  let feedback: PublishActionFeedback?
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var snapshot: RepositoryRebaseSyncSnapshot { confirmation.snapshot }

  var body: some View {
    VStack(spacing: 0) {
      confirmationHeader(
        title: "确认变基同步",
        detail: "把本地提交重放到已审阅的远端提交，并安全封存、恢复未提交改动。",
        systemImage: "arrow.triangle.branch"
      )
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          syncCard {
            Label("分支与提交", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.headline)
            LabeledContent("当前分支", value: snapshot.branch)
            LabeledContent("Upstream", value: snapshot.upstream)
            LabeledContent("本地 HEAD", value: String(snapshot.localHeadSHA.prefix(12)))
            LabeledContent("已审阅远端", value: String(snapshot.remoteHeadSHA.prefix(12)))
            LabeledContent("分叉", value: "领先 \(snapshot.aheadCount) · 落后 \(snapshot.behindCount)")
          }
          syncCard {
            Label("确认后依次执行", systemImage: "list.number")
              .font(.headline)
            rebaseStep(1, "冻结并封存当前未提交改动")
            rebaseStep(2, "只对已审阅的远端 SHA 执行 rebase")
            rebaseStep(3, "按精确 stash commit SHA 恢复改动")
          }
          syncCard {
            Label("将封存的本地改动（\(snapshot.localChanges.count)）", systemImage: "shippingbox")
              .font(.headline)
            if snapshot.localChanges.isEmpty {
              Text("当前工作区干净；将直接变基本地提交。")
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
              ForEach(snapshot.localChanges) { change in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Text(verbatim: change.status)
                    .font(.caption.weight(.semibold).monospaced())
                    .frame(minWidth: 34, alignment: .leading)
                  Text(verbatim: change.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                  Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
              }
            }
          }
          if let feedback, feedback.status == .failure || feedback.status == .warning {
            Label(feedback.message, systemImage: "exclamationmark.triangle")
              .font(.callout)
              .foregroundStyle(WorkbenchTheme.warning)
              .textSelection(.enabled)
          }
          Label(
            "确认前不会改变 HEAD、索引、工作区或 stash；冲突时会停止并保留 sequencer 与恢复 stash。",
            systemImage: "lock.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Label(
            "同步后会重新扫描磁盘仓库；软件草稿不会被静默覆盖，文章变化需在文件变更中审阅导入。",
            systemImage: "doc.badge.arrow.up"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(WorkbenchSpacing.spacious)
      }
      Divider()
      HStack(spacing: 12) {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
          .disabled(isApplying)
        Spacer()
        if isApplying {
          ProgressView().controlSize(.small).accessibilityLabel("正在变基同步")
        }
        Button("封存并变基同步", action: confirmAction)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(isApplying)
          .accessibilityIdentifier("repository-rebase-sync-confirm")
      }
      .padding(WorkbenchSpacing.spacious)
    }
    .frame(minWidth: 660, idealWidth: 740, minHeight: 580, idealHeight: 720)
    .interactiveDismissDisabled(isApplying)
    .accessibilityIdentifier("repository-rebase-sync-confirmation")
  }

  private func rebaseStep(_ number: Int, _ title: LocalizedStringKey) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(verbatim: "\(number)")
        .font(.caption.weight(.bold).monospacedDigit())
        .frame(width: 22, height: 22)
        .background(WorkbenchTheme.primary.opacity(0.12), in: Circle())
      Text(title).font(.callout)
    }
    .accessibilityElement(children: .combine)
  }
}

private func confirmationHeader(
  title: LocalizedStringKey,
  detail: LocalizedStringKey,
  systemImage: String
) -> some View {
  HStack(alignment: .top, spacing: 12) {
    Image(systemName: systemImage)
      .font(.title2)
      .foregroundStyle(WorkbenchTheme.primary)
      .accessibilityHidden(true)
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    Spacer()
  }
  .padding(WorkbenchSpacing.spacious)
}

private func syncCard<Content: View>(
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: 9, content: content)
    .padding(WorkbenchSpacing.section)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
}
