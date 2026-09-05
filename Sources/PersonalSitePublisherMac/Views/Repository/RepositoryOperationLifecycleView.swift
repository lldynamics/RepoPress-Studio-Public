import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

/// Persistent action bar for an in-progress Git sequencer or RepoPress stash
/// recovery. It remains visible after the last conflict path is staged.
struct RepositoryOperationLifecycleView: View {
  let lifecycle: RepositoryOperationLifecycle
  let recovery: RepositoryRebaseRecoveryContext?
  let diagnostic: String?
  let isRunning: Bool
  let completeAction: (String) -> Void
  let abortAction: () -> Void
  let restoreRebaseWIPAction: () -> Void
  let finishStashRecoveryAction: () -> Void
  let discardRecoveryRecordAction: () -> Void

  @State private var mergeMessage = String(localized: "Merge remote changes")
  @State private var isAbortConfirmationPresented = false
  @State private var isDiscardRecoveryConfirmationPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Label(title, systemImage: systemImage)
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        statusBadge
      }

      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let recovery {
        Label(
          String(
            format: String(localized: "本地改动恢复点：%@（%@）"),
            String(recovery.stashCommitSHA.prefix(12)),
            recoveryPhaseName(recovery.phase)
          ),
          systemImage: "archivebox"
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      }

      if let diagnostic, !diagnostic.isEmpty {
        Label(diagnostic, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .textSelection(.enabled)
      }

      if lifecycle.kind == .merge, lifecycle.unresolvedConflictCount == 0 {
        TextField("Merge 提交说明", text: $mergeMessage)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Merge 提交说明")
          .disabled(isRunning)
          .accessibilityIdentifier("repository-merge-commit-message")
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { actionButtons }
        VStack(alignment: .leading, spacing: 8) { actionButtons }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchTheme.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(WorkbenchTheme.warning.opacity(0.35))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-operation-lifecycle")
    .confirmationDialog(
      abortTitle,
      isPresented: $isAbortConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(abortButtonTitle, role: .destructive, action: abortAction)
      Button("取消", role: .cancel) {}
    } message: {
      Text(abortDetail)
    }
    .confirmationDialog(
      "确定移除恢复记录？",
      isPresented: $isDiscardRecoveryConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("移除恢复记录", role: .destructive, action: discardRecoveryRecordAction)
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会移除软件的恢复记录；Git stash 与工作区不会被删除或改写。之后软件不会再自动恢复这份 stash。")
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    if lifecycle.kind == .merge || lifecycle.kind == .rebase {
      Button {
        completeAction(mergeMessage)
      } label: {
        Label(completeButtonTitle, systemImage: "checkmark.circle")
      }
      .workbenchProminentActionStyle()
      .disabled(
        isRunning
          || !lifecycle.isCompletionReady
          || (lifecycle.kind == .merge && mergeMessage.trimmedForPublishing.isEmpty)
      )
      .accessibilityIdentifier("repository-operation-complete")

      Button(role: .destructive) {
        isAbortConfirmationPresented = true
      } label: {
        Label(abortButtonTitle, systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .disabled(isRunning)
      .accessibilityIdentifier("repository-operation-abort")
    } else if lifecycle.kind == .none, let recovery {
      switch recovery.phase {
      case .stashedBeforeRebase, .rebaseConflict, .rebaseCompleted:
        Button(action: restoreRebaseWIPAction) {
          Label("恢复封存的本地改动", systemImage: "archivebox")
        }
        .workbenchProminentActionStyle()
        .disabled(isRunning)
        .accessibilityIdentifier("repository-rebase-wip-restore")

      case .stashRestoreConflict:
        Button(action: finishStashRecoveryAction) {
          Label("完成本地改动恢复", systemImage: "checkmark.shield")
        }
        .workbenchProminentActionStyle()
        .disabled(isRunning)
        .accessibilityIdentifier("repository-stash-recovery-finish")

      case .completed:
        Button(action: finishStashRecoveryAction) {
          Label("清理已完成的恢复记录", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)
        .disabled(isRunning)
        .accessibilityIdentifier("repository-stash-recovery-cleanup")

      case .stashRestoreInProgress, .incomplete:
        discardRecoveryRecordButton
      }
    } else if lifecycle.kind == .none, diagnostic != nil {
      discardRecoveryRecordButton
    }

    if isRunning {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("正在处理 Git 操作")
    }
  }

  private var discardRecoveryRecordButton: some View {
    Button(role: .destructive) {
      isDiscardRecoveryConfirmationPresented = true
    } label: {
      Label("移除恢复记录…", systemImage: "archivebox.badge.xmark")
    }
    .buttonStyle(.bordered)
    .disabled(isRunning)
    .accessibilityIdentifier("repository-recovery-record-discard")
  }

  private var title: LocalizedStringKey {
    switch lifecycle.kind {
    case .merge: LocalizedStringKey("合并尚未完成")
    case .rebase: LocalizedStringKey("变基尚未完成")
    case .unmergedIndex: LocalizedStringKey("本地改动恢复冲突")
    case .ambiguous: LocalizedStringKey("Git 操作状态不明确")
    case .none:
      if diagnostic != nil {
        LocalizedStringKey("恢复记录无法读取")
      } else {
        recovery == nil
          ? LocalizedStringKey("Git 操作已结束")
          : LocalizedStringKey("本地改动恢复待确认")
      }
    }
  }

  private var systemImage: String {
    switch lifecycle.kind {
    case .merge: "arrow.triangle.merge"
    case .rebase: "arrow.triangle.branch"
    case .unmergedIndex: "archivebox"
    case .ambiguous: "questionmark.diamond"
    case .none: "checkmark.shield"
    }
  }

  private var detail: LocalizedStringKey {
    switch lifecycle.kind {
    case .merge where lifecycle.unresolvedConflictCount == 0:
      LocalizedStringKey("所有冲突已暂存。完成合并提交后，Git 才会退出 MERGING 状态。")
    case .merge:
      LocalizedStringKey("请逐个审阅冲突文件；全部暂存后才能完成合并。")
    case .rebase where lifecycle.unresolvedConflictCount == 0:
      LocalizedStringKey("当前冲突已暂存。点击继续变基；若还有下一批冲突，软件会继续停留在此流程。")
    case .rebase:
      LocalizedStringKey("请逐个审阅并暂存当前变基冲突。本地改动的精确 stash 将继续保留。")
    case .unmergedIndex:
      LocalizedStringKey("stash 已开始恢复，但出现冲突。此状态没有可安全通用的 continue/abort；请逐个确认最终版本。")
    case .ambiguous:
      LocalizedStringKey("同时检测到多个 Git 操作标记，软件已停止自动写入。")
    case .none where recovery?.phase == .stashRestoreConflict:
      LocalizedStringKey("所有 stash 恢复冲突已暂存。完成后会保留原 stash 作为备份，不会自动删除。")
    case .none where recovery?.phase == .stashedBeforeRebase:
      LocalizedStringKey("软件在变基前的安全点中断。可按已记录的精确 stash 恢复本地改动；不会猜测其他 stash。")
    case .none where recovery?.phase == .rebaseConflict:
      LocalizedStringKey("变基序列已在软件外结束或放弃。验证 HEAD 后可恢复变基前的本地改动。")
    case .none where recovery?.phase == .rebaseCompleted:
      LocalizedStringKey("变基已完成，但本地改动尚未恢复。点击后只会应用记录中的精确 stash。")
    case .none where recovery?.phase == .stashRestoreInProgress:
      LocalizedStringKey("软件在 stash 应用期间中断。为避免重复应用造成数据损坏，已禁止自动重试，请检查工作区。")
    case .none where recovery?.phase == .completed:
      LocalizedStringKey("本地改动已恢复；这是一条未清理的完成记录，不会重复应用 stash。")
    case .none:
      LocalizedStringKey("恢复记录需要人工检查；软件不会猜测或重复应用 stash。")
    }
  }

  private var statusBadge: some View {
    Text(statusBadgeTitle)
    .font(.caption.weight(.semibold).monospacedDigit())
    .foregroundStyle(
      lifecycle.unresolvedConflictCount == 0 ? WorkbenchTheme.success : WorkbenchTheme.warning
    )
  }

  private var completeButtonTitle: LocalizedStringKey {
    lifecycle.kind == .merge
      ? LocalizedStringKey("完成合并并提交")
      : LocalizedStringKey("继续变基")
  }

  private var abortButtonTitle: LocalizedStringKey {
    lifecycle.kind == .merge
      ? LocalizedStringKey("放弃本次合并")
      : LocalizedStringKey("放弃本次变基")
  }

  private var abortTitle: LocalizedStringKey {
    lifecycle.kind == .merge
      ? LocalizedStringKey("确定放弃本次合并？")
      : LocalizedStringKey("确定放弃本次变基？")
  }

  private var abortDetail: LocalizedStringKey {
    lifecycle.kind == .merge
      ? LocalizedStringKey("Git 将恢复到合并开始前。")
      : LocalizedStringKey("Git 将恢复到变基开始前，然后按记录的精确 stash 恢复本地改动。")
  }

  private var statusBadgeTitle: String {
    if lifecycle.kind == .none, recovery != nil || diagnostic != nil {
      return String(localized: "恢复记录待处理")
    }
    return lifecycle.unresolvedConflictCount == 0
      ? String(localized: "已暂存全部冲突")
      : String(
        format: String(localized: "%lld 个未解决"),
        Int64(lifecycle.unresolvedConflictCount)
      )
  }

  private func recoveryPhaseName(_ phase: RepositoryRebaseRecoveryContext.Phase) -> String {
    switch phase {
    case .stashedBeforeRebase: String(localized: "变基前已封存")
    case .rebaseConflict: String(localized: "变基冲突")
    case .rebaseCompleted: String(localized: "等待恢复 stash")
    case .stashRestoreInProgress: String(localized: "stash 恢复中断")
    case .stashRestoreConflict: String(localized: "stash 恢复冲突")
    case .incomplete: String(localized: "需人工检查")
    case .completed: String(localized: "恢复已完成")
    }
  }
}
