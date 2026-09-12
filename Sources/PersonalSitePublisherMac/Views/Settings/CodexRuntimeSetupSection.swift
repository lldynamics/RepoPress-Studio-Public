import PublishingWorkbenchCore
import SwiftUI

struct CodexRuntimeSetupSection: View {
  let status: CodexAppServerRuntimeStatus?
  let onPrepared: () async -> Void
  @State private var setupTask: Task<Void, Never>?
  @State private var progress: String?
  @State private var failure: String?
  @State private var showDetails = false

  var body: some View {
    if let status, CodexRuntimeSetupService.needsRecommendedUpdate(status) || setupTask != nil {
      let plan = CodexRuntimeSetupService.plan(for: status)
      VStack(alignment: .leading, spacing: 8) {
        Label(
          status.isAvailable ? String(localized: "连接组件有可用更新") : String(localized: "首次使用需要准备连接组件"),
          systemImage: "shippingbox"
        )
        .font(.headline)
        Text(plan.explanation)
          .font(.caption).foregroundStyle(.secondary)
        if status.isCompatible {
          Text(String(localized: "当前版本仍可使用。更新后会在 AI 空闲时重新连接，编辑内容和对话会保留。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          if plan.isAutomatic {
            Button(plan.title) { prepare(plan) }
              .workbenchProminentActionStyle()
              .disabled(setupTask != nil)
              .accessibilityIdentifier("settings-ai-codex-prepare")
          }
          Link(String(localized: "官方安装说明"), destination: CodexRuntimeSetupService.installationGuide)
          if setupTask != nil {
            ProgressView().controlSize(.small)
            Button(String(localized: "取消")) { setupTask?.cancel() }
          }
        }
        if let progress {
          Text(progress).font(.caption).accessibilityIdentifier(
            "settings-ai-codex-prepare-progress")
        }
        if let failure {
          Text(failure).font(.caption).foregroundStyle(WorkbenchTheme.warning).textSelection(
            .enabled)
        }
        DisclosureGroup(String(localized: "安装信息"), isExpanded: $showDetails) {
          Text(String(localized: "推荐版本：\(CodexRuntimeSetupService.recommendedVersion.description)"))
          if let path = plan.runtimeURL?.path { Text(path).textSelection(.enabled) }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
      .onDisappear { setupTask?.cancel() }
    }
  }

  private func prepare(_ plan: CodexRuntimeSetupPlan) {
    guard setupTask == nil else { return }
    failure = nil
    progress = String(localized: "正在准备…")
    setupTask = Task { @MainActor in
      defer { setupTask = nil }
      do {
        _ = try await CodexRuntimeSetupService().prepare(plan: plan) { message in
          Task { @MainActor in progress = message }
        }
        try Task.checkCancellation()
        let reconnected = await CodexAppServerClient.shared.reconnectAfterRuntimeUpdate()
        progress =
          reconnected
          ? String(localized: "组件已准备完成，正在检查登录和模型…") : String(localized: "组件已更新，当前 AI 操作结束后会自动启用。")
        while await CodexAppServerClient.shared.isRuntimeReconnectPending {
          try await Task.sleep(for: .milliseconds(500))
        }
        try Task.checkCancellation()
        await onPrepared()
      } catch is CancellationError {
        progress = String(localized: "已停止准备。安装可能已部分完成，请重新检测组件状态。")
      } catch {
        progress = nil
        failure = error.localizedDescription
      }
    }
  }
}
