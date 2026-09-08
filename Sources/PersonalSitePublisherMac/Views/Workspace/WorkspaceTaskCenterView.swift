import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskCenterView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceWindowID) private var workspaceWindowID
  @Environment(\.openWindow) private var openWindow
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  @ObservedObject private var operationLog: WorkbenchOperationLogFeatureFacade
  /// Action routing intentionally retains the full store without observing it.
  /// The task center's redraw inputs are limited to activity and operation-log
  /// facades, so editor and unrelated workspace mutations do not invalidate it.
  private let store: WorkbenchStore
  @State private var retryingTaskID: String?
  @State private var duplicateChargeConfirmationTask: WorkbenchTaskItem?
  @State private var expandedTaskIDs = Set<String>()
  @State private var taskActionFeedback: String?
  @State private var focusedReleaseRecord: TaskCenterReleaseRecordFocus?

  init(store: WorkbenchStore) {
    self.store = store
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
    _operationLog = ObservedObject(wrappedValue: store.operationLog)
  }

  var body: some View {
    let recentEntries = privacyAwareRecentActivityEntries

    VStack(spacing: 0) {
      header
      if let taskActionFeedback {
        Text(taskActionFeedback)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.bottom, 8)
          .accessibilityIdentifier("workspace-task-action-feedback")
      }
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if activityStatus.taskCenterItems.isEmpty {
            ContentUnavailableView {
              Label("暂无任务", systemImage: "checkmark.circle")
            } description: {
              Text("AI 请求、资料导入、图片处理、站点扫描、Git 推送和部署状态会集中显示在这里。")
            }
            .frame(maxWidth: .infinity, minHeight: 150)
          } else {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(
                WorkspaceTaskCenterPresentation.ordered(activityStatus.taskCenterItems)
              ) { task in
                WorkspaceTaskCenterRow(
                  task: task,
                  isRetrying: retryingTaskID == task.id,
                  isExpanded: expandedTaskIDs.contains(task.id),
                  retry: { retry(task) },
                  locate: { _ = locate(task) },
                  cancel: { cancel(task) },
                  toggleDetails: { toggleDetails(task) },
                  copyDiagnostic: { copyDiagnostic(for: task) }
                )
              }
            }
          }

          if operationLog.isQuickHideActive {
            Label("活动记录已隐藏", systemImage: "eye.slash")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("workspace-task-center-recent-activity-hidden")
          } else {
            recentActivity(entries: recentEntries)
          }
        }
        .padding(16)
      }
    }
    .frame(width: 480, height: panelHeight(activityCount: recentEntries.count))
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
    .sheet(item: $focusedReleaseRecord) { focus in
      VStack(spacing: 0) {
        ReleaseHistoryDetailView(store: store, focusedRecordID: focus.id)
        Divider()
        Button(String(localized: "关闭")) {
          focusedReleaseRecord = nil
        }
        .padding()
      }
      .frame(minWidth: 760, minHeight: 620)
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
    let waiting = activityStatus.waitingTaskCount
    if waiting > 0 {
      return String(localized: "进行中 \(active) · 失败 \(failed) · 等待处理 \(waiting)")
    }
    if active == 0, failed == 0 {
      return String(localized: "所有后台任务均已完成")
    }
    return String(localized: "进行中 \(active) · 失败待处理 \(failed)")
  }

  private func panelHeight(activityCount: Int) -> CGFloat {
    let taskCount = activityStatus.taskCenterItems.count
    guard taskCount > 0 else { return min(560, max(300, CGFloat(activityCount) * 58 + 250)) }
    return min(560, max(300, CGFloat(taskCount) * 112 + CGFloat(activityCount) * 58 + 100))
  }

  private func recentActivity(entries: [WorkbenchOperationLogEntry]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("最近活动", systemImage: "clock.arrow.circlepath")
          .font(.headline)
        Spacer()
        Button("查看全部活动记录…") {
          dismiss()
          openWindow(id: "operation-log")
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("operation-log-open")
      }

      if entries.isEmpty {
        Text("完成的发布、维护和同步操作会显示在这里。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(entries) { entry in
            WorkspaceRecentActivityRow(entry: entry)
          }
        }
      }
    }
    .accessibilityIdentifier("workspace-task-center-recent-activity")
  }

  private var privacyAwareRecentActivityEntries: [WorkbenchOperationLogEntry] {
    guard !operationLog.isQuickHideActive else { return [] }
    return Array(operationLog.entries.prefix(5))
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
    if task.requiresPublishReview {
      guard locate(task) else { return }
      taskActionFeedback = String(localized: "请在原记录核对分支与发布方式，重新审阅后执行；未自动提交或推送。")
      return
    }
    retryingTaskID = task.id
    Task { @MainActor in
      await activityStatus.retryTask(
        task,
        confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge
      )
      retryingTaskID = nil
    }
  }

  @discardableResult
  private func locate(_ task: WorkbenchTaskItem) -> Bool {
    if let message = activityStatus.locateTask(task, windowID: workspaceWindowID) {
      taskActionFeedback = message
      return false
    }
    if case .releaseRecord(let recordID) = task.target {
      focusedReleaseRecord = TaskCenterReleaseRecordFocus(id: recordID)
    }
    taskActionFeedback = String(localized: "已定位到任务目标。")
    return true
  }

  private func cancel(_ task: WorkbenchTaskItem) {
    taskActionFeedback =
      activityStatus.cancelTask(task)
      ?? String(localized: "已请求停止该任务。")
  }

  private func toggleDetails(_ task: WorkbenchTaskItem) {
    if expandedTaskIDs.contains(task.id) {
      expandedTaskIDs.remove(task.id)
    } else {
      expandedTaskIDs.insert(task.id)
    }
  }

  private func copyDiagnostic(for task: WorkbenchTaskItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(task.diagnosticText, forType: .string)
    taskActionFeedback = String(localized: "已复制任务诊断。")
  }
}

private struct TaskCenterReleaseRecordFocus: Identifiable {
  let id: UUID
}

private struct WorkspaceRecentActivityRow: View {
  let entry: WorkbenchOperationLogEntry

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: entry.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.caption.weight(.semibold))
        Text(entry.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        HStack(spacing: 4) {
          if let targetLabel = entry.targetLabel {
            Text(targetLabel)
            Text("·")
          }
          Text(workspaceOperationOutcomeTitle(entry.outcome))
          Text("·")
          Text(entry.occurredAt, style: .relative)
        }
        .font(.workbenchMetadata)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .combine)
  }
}

private func workspaceOperationOutcomeTitle(_ outcome: WorkbenchOperationLogOutcome) -> String {
  switch outcome {
  case .succeeded:
    return String(localized: "已完成")
  case .partial:
    return String(localized: "部分完成")
  case .failed:
    return String(localized: "失败")
  case .cancelled:
    return String(localized: "已取消")
  case .recorded:
    return String(localized: "已记录")
  case .observed:
    return String(localized: "已观察")
  }
}

private struct WorkspaceTaskCenterRow: View {
  let task: WorkbenchTaskItem
  let isRetrying: Bool
  let isExpanded: Bool
  let retry: () -> Void
  let locate: () -> Void
  let cancel: () -> Void
  let toggleDetails: () -> Void
  let copyDiagnostic: () -> Void

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
          if let checkedAt = task.checkedAt {
            Text("最近检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
          }
          Text(task.primaryPresentationDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 5) {
          if task.canRetry {
            Button {
              retry()
            } label: {
              if isRetrying {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label(
                  task.retryTitle,
                  systemImage: task.requiresPublishReview
                    ? "doc.text.magnifyingglass" : "arrow.clockwise")
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRetrying)
            .accessibilityIdentifier("workspace-task-retry-\(task.id)")
          }
          if task.canCancel {
            Button(String(localized: "停止"), role: .destructive, action: cancel)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .accessibilityIdentifier("workspace-task-cancel-\(task.id)")
          }
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

      HStack(spacing: 10) {
        Button(String(localized: "查看详情"), action: toggleDetails)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("workspace-task-details-\(task.id)")
        if task.target != nil {
          Button(String(localized: "定位目标"), action: locate)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("workspace-task-locate-\(task.id)")
        }
        Button(String(localized: "复制诊断"), action: copyDiagnostic)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("workspace-task-copy-diagnostic-\(task.id)")
        Spacer()
      }
      .font(.caption)

      if isExpanded {
        Text(task.diagnosticText)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 6))
          .accessibilityIdentifier("workspace-task-diagnostic-\(task.id)")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
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
    case .cancelled, .waiting, .needsAttention:
      return .secondary
    }
  }
}
