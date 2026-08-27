import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskCenterView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  let store: WorkbenchStore
  @State private var retryingTaskID: String?
  @State private var duplicateChargeConfirmationTask: WorkbenchTaskItem?

  init(store: WorkbenchStore) {
    self.store = store
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      if activityStatus.taskCenterItems.isEmpty {
        ContentUnavailableView {
          Label("暂无任务", systemImage: "checkmark.circle")
        } description: {
          Text("AI 请求、资料导入、图片处理、站点扫描、Git 推送和部署状态会集中显示在这里。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(WorkspaceTaskCenterPresentation.ordered(activityStatus.taskCenterItems)) { task in
              WorkspaceTaskCenterRow(
                task: task,
                isRetrying: retryingTaskID == task.id,
                retry: { retry(task) }
              )
            }
          }
          .padding(16)
        }
      }
    }
    .frame(width: 480, height: panelHeight)
    .onExitCommand { dismiss() }
    .confirmationDialog(
      "重新生成可能重复计费",
      isPresented: Binding(
        get: { duplicateChargeConfirmationTask != nil },
        set: { isPresented in
          if !isPresented {
            duplicateChargeConfirmationTask = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("重新生成", role: .destructive) {
        guard let task = duplicateChargeConfirmationTask else { return }
        duplicateChargeConfirmationTask = nil
        beginRetry(task, confirmingPossibleDuplicateCharge: true)
      }
      Button("取消", role: .cancel) {
        duplicateChargeConfirmationTask = nil
      }
    } message: {
      Text("AI 已返回部分内容，软件没有自动重放请求。继续会移除这段未完成回复并重新生成，可能产生重复内容和费用。")
    }
    .accessibilityLabel("统一任务中心")
    .accessibilityIdentifier("workspace-task-center")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "list.bullet.rectangle.portrait")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("统一任务中心")
          .font(.headline)
        Text(headerDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private var headerDetail: String {
    let active = activityStatus.activeTaskCount
    let failed = activityStatus.failedTaskCount
    if active == 0, failed == 0 {
      return String(localized: "所有后台任务均已完成")
    }
    return String(localized: "进行中 \(active) · 失败待处理 \(failed)")
  }

  private var panelHeight: CGFloat {
    let taskCount = activityStatus.taskCenterItems.count
    guard taskCount > 0 else { return 240 }
    return min(480, max(300, CGFloat(taskCount) * 112 + 80))
  }

  private func retry(_ task: WorkbenchTaskItem) {
    guard task.canRetry else { return }
    if task.requiresDuplicateChargeConfirmation {
      guard retryingTaskID == nil else { return }
      duplicateChargeConfirmationTask = task
      return
    }
    beginRetry(task)
  }

  private func beginRetry(
    _ task: WorkbenchTaskItem,
    confirmingPossibleDuplicateCharge: Bool = false
  ) {
    guard task.canRetry, retryingTaskID == nil else { return }
    retryingTaskID = task.id
    Task { @MainActor in
      await activityStatus.retryTask(
        task,
        confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge
      )
      retryingTaskID = nil
    }
  }
}

private struct WorkspaceTaskCenterRow: View {
  let task: WorkbenchTaskItem
  let isRetrying: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: task.kind.systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(statusColor)
          .frame(width: 22, height: 22)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(task.title)
              .font(.callout.weight(.semibold))
            Text(task.state.title)
              .font(.caption.weight(.medium))
              .foregroundStyle(statusColor)
          }
          Text(task.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        if task.canRetry {
          Button {
            retry()
          } label: {
            if isRetrying {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("重试", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isRetrying)
          .accessibilityIdentifier("workspace-task-retry-\(task.id)")
        }
      }

      if let progress = task.progress {
        HStack(spacing: 8) {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
          Text("\(Int(progress * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("任务进度")
        .accessibilityValue("\(Int(progress * 100))% · \(task.detail)")
      } else if task.isActive {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("任务进行中")
      }

      if let failureReason = task.failureReason, task.isFailure {
        Label {
          Text(String(localized: "失败原因：\(failureReason)"))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(WorkbenchTheme.risk)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(statusColor.opacity(0.18), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-task-row-\(task.id)")
  }

  private var statusColor: Color {
    switch task.state {
    case .running:
      return WorkbenchTheme.progress
    case .failed:
      return WorkbenchTheme.risk
    case .completed:
      return WorkbenchTheme.success
    case .cancelled:
      return .secondary
    }
  }
}
