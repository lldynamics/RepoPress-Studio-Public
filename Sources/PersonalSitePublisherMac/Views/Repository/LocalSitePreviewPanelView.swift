import PublishingWorkbenchCore
import SwiftUI

struct LocalSitePreviewPanelView: View {
  let store: WorkbenchStore
  var onClose: (() -> Void)? = nil
  @EnvironmentObject private var state: WorkbenchLocalSitePreviewFeatureFacade
  @StateObject private var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  @State private var navigationError: String?
  @State private var pendingAuthorizationRequest: LocalSitePreviewAuthorizationRequest?

  init(store: WorkbenchStore, onClose: (() -> Void)? = nil) {
    self.store = store
    self.onClose = onClose
    _externalBrowserPreviewCoordinator = StateObject(
      wrappedValue: ExternalBrowserPreviewCoordinator(store: store)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .localSitePreviewTrustConfirmation(
      request: $pendingAuthorizationRequest,
      entryPoint: .panel,
      authorize: { request in
        state.authorizeAndStart(request)
      }
    )
    .onChange(of: state.activeProfileID) {
      pendingAuthorizationRequest = nil
      externalBrowserPreviewCoordinator.cancelPendingOpen()
    }
    .onChange(of: store.selectedDraftID) { _, draftID in
      externalBrowserPreviewCoordinator.cancelPendingOpen(ifDraftIsNoLongerCurrent: draftID)
    }
    .onDisappear {
      externalBrowserPreviewCoordinator.cancelPendingOpen()
    }
    .externalBrowserPreviewPresentation(coordinator: externalBrowserPreviewCoordinator)
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("本地站点预览")
          .font(.title2.weight(.semibold))
        if let plan = state.plan {
          Text("\(plan.siteKind.localizedDisplayName) · 127.0.0.1:\(plan.port ?? 0)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        } else {
          Text("尚未识别可启动的本地站点")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if previewURL != nil {
        Button {
          state.reload()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(!state.runtimeStatus.isRunning)

        Button {
          guard let draftID = store.selectedDraftID else { return }
          externalBrowserPreviewCoordinator.openSiteHome(for: draftID)
        } label: {
          Label("浏览器打开", systemImage: "safari")
        }
        .buttonStyle(.bordered)
        .disabled(
          store.selectedDraftID == nil || externalBrowserPreviewCoordinator.isBusy
        )
      }

      if let onClose {
        Button(action: onClose) {
          Label("关闭", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("local-site-preview-close")
      }

      if state.runtimeStatus.isRunning {
        Button {
          externalBrowserPreviewCoordinator.cancelPendingOpen()
          state.stop()
        } label: {
          Label("停止", systemImage: "stop.circle")
        }
        .buttonStyle(.bordered)
      } else {
        Button {
          requestStart()
        } label: {
          Label("启动预览", systemImage: "play.circle")
        }
        .workbenchProminentActionStyle()
        .disabled(state.plan?.diagnostics.isReadyToStart != true)
      }
    }
    .padding(WorkbenchSpacing.content)
  }

  @ViewBuilder
  private var content: some View {
    if let plan = state.plan, state.runtimeStatus.isRunning {
      VStack(spacing: 0) {
        LocalSitePreviewWebView(
          url: state.runtimeStatus.previewURL ?? plan.previewURL,
          reloadToken: state.refreshToken,
          onNavigationError: { message in
            navigationError = message
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        statusBar
      }
    } else if let plan = state.plan {
      ScrollView {
        diagnosticsView(plan: plan)
          .frame(maxWidth: 760, alignment: .leading)
          .padding(WorkbenchSpacing.spacious)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    } else {
      ContentUnavailableView(
        "没有可用的本地预览",
        systemImage: "safari",
        description: Text("请先为当前站点选择本地仓库，然后扫描仓库以识别启动命令。")
      )
    }
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Image(systemName: state.runtimeStatus.isReachable ? "checkmark.circle.fill" : "play.circle")
        .foregroundStyle(
          state.runtimeStatus.isReachable ? WorkbenchTheme.success : WorkbenchTheme.progress)
      Text(state.runtimeStatus.message)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let navigationError {
        Text("· " + navigationError)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .lineLimit(1)
      }
      Spacer()
      if let pid = state.runtimeStatus.processIdentifier {
        Text("PID \(pid)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(WorkbenchBackgroundStyle.card)
  }

  private func diagnosticsView(plan: LocalSitePreviewPlan) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Label(
          plan.diagnostics.statusTitle,
          systemImage: plan.diagnostics.isReadyToStart
            ? "checkmark.seal" : "exclamationmark.triangle"
        )
        .font(.headline)
        .foregroundStyle(
          plan.diagnostics.isReadyToStart ? WorkbenchTheme.success : WorkbenchTheme.warning)
        Text(state.runtimeStatus.message)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("启动命令")
          .font(.callout.weight(.semibold))
        Text(plan.command)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
      }

      if !plan.diagnostics.dependencies.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("依赖与脚本")
            .font(.callout.weight(.semibold))
          ForEach(plan.diagnostics.dependencies) { dependency in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: dependencyIcon(dependency.status))
                .foregroundStyle(dependencyColor(dependency.status))
              VStack(alignment: .leading, spacing: 2) {
                Text(dependency.name)
                  .font(.callout.weight(.medium))
                Text(dependency.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let suggestedAction = dependency.suggestedAction {
                  Text(suggestedAction)
                    .font(.caption)
                    .foregroundStyle(WorkbenchTheme.warning)
                }
              }
            }
          }
        }
      }

      if !plan.diagnostics.issues.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("仓库提示")
            .font(.callout.weight(.semibold))
          ForEach(plan.diagnostics.issues) { issue in
            Label(
              issue.message,
              systemImage: issue.severity.isBlocking ? "xmark.octagon" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(issue.severity.isBlocking ? WorkbenchTheme.risk : .secondary)
          }
        }
      }

      ForEach(plan.notes, id: \.self) { note in
        Label(note, systemImage: "lightbulb")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 12))
  }

  private func dependencyIcon(_ status: LocalSitePreviewDependencyStatus) -> String {
    switch status {
    case .available:
      return "checkmark.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .missing, .invalid:
      return "xmark.circle.fill"
    }
  }

  private func dependencyColor(_ status: LocalSitePreviewDependencyStatus) -> Color {
    switch status {
    case .available:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .missing, .invalid:
      return WorkbenchTheme.risk
    }
  }

  private var previewURL: URL? {
    state.runtimeStatus.previewURL ?? state.plan?.previewURL
  }

  private func requestStart() {
    pendingAuthorizationRequest = LocalSitePreviewTrustConfirmationPolicy.request(
      from: state.start(),
      entryPoint: .panel
    )
  }
}
