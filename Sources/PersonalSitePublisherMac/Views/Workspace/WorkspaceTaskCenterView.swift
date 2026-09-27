import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskCenterView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  /// Action routing intentionally retains the full store without observing it.
  /// Task and history panes observe their own facades, so editor and unrelated
  /// workspace mutations do not invalidate them.
  private let store: WorkbenchStore
  private let windowSession: WorkspaceWindowSession
  @State private var retryingTaskID: String?
  @State private var duplicateChargeConfirmationTask: WorkbenchTaskItem?
  @State private var expandedTaskIDs = Set<String>()
  @State private var taskActionFeedback: String?
  @State private var focusedReleaseRecord: TaskCenterReleaseRecordFocus?

  init(store: WorkbenchStore, windowSession: WorkspaceWindowSession) {
    self.store = store
    self.windowSession = windowSession
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      TabView {
        taskList
          .tabItem { Label("任务", systemImage: "list.bullet.rectangle") }
        WorkspaceTaskCenterActivityView(
          operationLog: store.operationLog,
          openSyncWorkspace: {
            WorkspaceTaskCenterNavigation.openSyncWorkspace(
              store: store, windowSession: windowSession
            )
            dismiss()
          }
        )
        .tabItem { Label("活动记录", systemImage: "clock.arrow.circlepath") }
      }
      .padding([.horizontal, .bottom], 12)
    }
    .frame(minWidth: 800, idealWidth: 900, minHeight: 580, idealHeight: 640)
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
      Text("继续将移除当前未完成的回复并重新生成，可能消耗额外配额。")
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
    .accessibilityLabel("任务中心")
    .accessibilityIdentifier("workspace-task-center")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "list.bullet.rectangle.portrait")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("任务中心")
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

  private var taskList: some View {
    VStack(spacing: 0) {
      if let taskActionFeedback {
        Text(taskActionFeedback)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .accessibilityIdentifier("workspace-task-action-feedback")
      }
      ScrollView {
        if activityStatus.taskCenterItems.isEmpty {
          ContentUnavailableView {
            Label("暂无任务", systemImage: "checkmark.circle")
          } description: {
            Text("AI 请求、资料导入、图片处理、站点扫描、Git 推送和部署状态会集中显示在这里。")
          }
          .frame(maxWidth: .infinity, minHeight: 240)
        } else {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(WorkspaceTaskCenterPresentation.ordered(activityStatus.taskCenterItems)) {
              task in
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
          .padding(16)
        }
      }
    }
    .accessibilityIdentifier("workspace-task-center-tasks")
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
    if let message = WorkspaceTaskCenterNavigation.locate(
      task, store: store, windowSession: windowSession
    ) {
      taskActionFeedback = message
      return false
    }
    if case .releaseRecord(let recordID) = task.target {
      focusedReleaseRecord = TaskCenterReleaseRecordFocus(id: recordID)
    } else {
      dismiss()
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
