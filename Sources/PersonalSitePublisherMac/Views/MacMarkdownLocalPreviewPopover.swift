import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownLocalPreviewPopover: View {
  @EnvironmentObject private var state: WorkbenchLocalSitePreviewFeatureFacade
  let currentArticleURL: URL?

  @State private var isCheckingReachability = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(width: 360)
    .task(id: state.activeProfileID) {
      state.refreshStatus()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-local-site-preview-popover")
  }

  private var header: some View {
    HStack(spacing: 9) {
      Label(
        "本地预览",
        systemImage: state.runtimeStatus.isRunning ? "safari" : "play.rectangle"
      )
      .font(.headline)

      Spacer(minLength: 8)

      statusBadge
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  @ViewBuilder
  private var content: some View {
    if let plan = state.plan {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("\(plan.siteKind.localizedDisplayName) · \(plan.previewURL.absoluteString)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          Text(state.runtimeStatus.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        HStack(spacing: 8) {
          startStopButton

          Button {
            state.refreshStatus()
          } label: {
            Image(systemName: "arrow.clockwise")
              .accessibilityLabel("刷新状态")
          }
          .buttonStyle(.bordered)
          .help(String(localized: "刷新本地预览状态"))
          .accessibilityIdentifier("markdown-local-preview-refresh-status")
        }

        HStack(spacing: 8) {
          Button {
            Task { @MainActor in
              isCheckingReachability = true
              await state.verifyReachability()
              isCheckingReachability = false
            }
          } label: {
            Label("检测端口", systemImage: "network")
          }
          .buttonStyle(.bordered)
          .disabled(!state.runtimeStatus.isRunning || isCheckingReachability)
          .accessibilityIdentifier("markdown-local-preview-check-port")

          Button {
            state.reload()
          } label: {
            Label("刷新预览", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(.bordered)
          .disabled(!state.runtimeStatus.isRunning)
          .accessibilityIdentifier("markdown-local-preview-reload")
        }

        HStack(spacing: 8) {
          Button {
            guard let url = currentArticleURL ?? previewURL else { return }
            ExternalURLOpener.open(url)
          } label: {
            Label(
              currentArticleURL == nil ? "浏览器打开" : "打开当前文章",
              systemImage: "safari"
            )
          }
          .buttonStyle(.bordered)
          .disabled(!state.runtimeStatus.isRunning || previewURL == nil)
          .accessibilityIdentifier("markdown-local-preview-open-browser")
        }

        if !plan.diagnostics.isReadyToStart {
          diagnosticsHint(plan: plan)
        }
      }
      .padding(16)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Label("尚未配置本地站点", systemImage: "exclamationmark.triangle")
          .font(.callout.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
        Text("当前写作界面没有可用的本地仓库，暂时无法启动预览。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("请在站点设置中选择仓库并完成扫描。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)
    }
  }

  private var statusBadge: some View {
    Label(statusTitle, systemImage: statusIcon)
      .font(.caption)
      .foregroundStyle(statusColor)
  }

  private var statusTitle: String {
    if state.runtimeStatus.isReachable {
      return "可访问"
    }
    if state.runtimeStatus.isRunning {
      return "启动中"
    }
    return "未启动"
  }

  private var statusIcon: String {
    if state.runtimeStatus.isReachable {
      return "checkmark.circle.fill"
    }
    if state.runtimeStatus.isRunning {
      return "play.circle"
    }
    return "stop.circle"
  }

  private var statusColor: Color {
    if state.runtimeStatus.isReachable {
      return WorkbenchTheme.success
    }
    if state.runtimeStatus.isRunning {
      return WorkbenchTheme.progress
    }
    return .secondary
  }

  private var previewURL: URL? {
    state.runtimeStatus.previewURL ?? state.plan?.previewURL
  }

  @ViewBuilder
  private var startStopButton: some View {
    if state.runtimeStatus.isRunning {
      startStopButtonBody
        .buttonStyle(.bordered)
    } else {
      startStopButtonBody
        .workbenchProminentActionStyle()
    }
  }

  private var startStopButtonBody: some View {
    Button {
      if state.runtimeStatus.isRunning {
        state.stop()
      } else {
        state.start()
      }
    } label: {
      Label(
        state.runtimeStatus.isRunning ? "停止预览" : "启动预览",
        systemImage: state.runtimeStatus.isRunning ? "stop.circle" : "play.circle"
      )
    }
    .disabled(!state.runtimeStatus.isRunning && state.plan?.diagnostics.isReadyToStart != true)
    .accessibilityIdentifier("markdown-local-preview-start-stop")
  }

  private func diagnosticsHint(plan: LocalSitePreviewPlan) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(plan.diagnostics.statusTitle, systemImage: "exclamationmark.triangle")
        .font(.caption.weight(.medium))
        .foregroundStyle(WorkbenchTheme.warning)

      if let blockingIssue = plan.diagnostics.issues.first(where: { $0.severity.isBlocking }) {
        Text(blockingIssue.message)
      } else if let dependency = plan.diagnostics.dependencies.first(where: {
        $0.status == .missing || $0.status == .invalid
      }) {
        Text(dependency.detail)
      } else {
        Text("请先完成本地预览所需的仓库配置。")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("markdown-local-preview-diagnostics")
  }
}
