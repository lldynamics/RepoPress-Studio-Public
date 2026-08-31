import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var localPreviewSection: some View {
    if let plan = store.localSitePreviewPlan {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("本地预览")
            .font(.headline)
          Text("启动站点后检查端口，再打开当前文章或整个站点。")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(plan.previewURL.absoluteString)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Label(
            plan.usesDynamicPort ? "已自动切换动态端口" : "使用默认端口",
            systemImage: plan.usesDynamicPort ? "arrow.triangle.2.circlepath" : "network"
          )
          .font(.caption)
          .foregroundStyle(plan.usesDynamicPort ? WorkbenchTheme.warning : .secondary)
        }

        let currentDraftID = store.selectedDraftID
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)],
          alignment: .leading,
          spacing: 8
        ) {
          Button {
            localSitePreviewCommandAction?.open()
          } label: {
            if store.localSitePreviewRuntimeStatus.isRunning {
              Label("在应用内预览", systemImage: "rectangle.inset.filled")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Label("检查并启动预览", systemImage: "rectangle.inset.filled")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .workbenchProminentActionStyle()
          .disabled(
            !LocalSitePreviewTrustConfirmationPolicy.repositoryStartOpensConfirmationPanel(
              commandActionAvailable: localSitePreviewCommandAction != nil
            ) || !plan.diagnostics.isReadyToStart
          )
          .accessibilityIdentifier("repository-preview-open-in-app")

          Button {
            externalBrowserPreviewCoordinator.cancelPendingOpen()
            store.stopLocalSitePreview()
          } label: {
            Label("停止", systemImage: "stop.circle")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(!store.localSitePreviewRuntimeStatus.isRunning)
          .accessibilityIdentifier("repository-preview-stop")

          Button {
            Task {
              await store.verifyLocalSitePreviewReachability()
            }
          } label: {
            Label("检测端口", systemImage: "network")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(!store.localSitePreviewRuntimeStatus.isRunning)
          .accessibilityIdentifier("repository-preview-check-port")

          Button {
            guard let currentDraftID else { return }
            externalBrowserPreviewCoordinator.openCurrentArticle(for: currentDraftID)
          } label: {
            Label("打开当前文章", systemImage: "doc.richtext")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(currentDraftID == nil || externalBrowserPreviewCoordinator.isBusy)
          .accessibilityIdentifier("repository-preview-open-current-article")

          Button {
            guard let currentDraftID else { return }
            externalBrowserPreviewCoordinator.openSiteHome(for: currentDraftID)
          } label: {
            Label("打开预览", systemImage: "safari")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(currentDraftID == nil || externalBrowserPreviewCoordinator.isBusy)
          .help(String(localized: "保存当前文章并在页面就绪后打开站点"))
          .accessibilityIdentifier("repository-preview-open-site")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-preview-actions")

        Label(
          store.localSitePreviewRuntimeStatus.message,
          systemImage: store.localSitePreviewRuntimeStatus.isReachable
            ? "checkmark.circle"
            : (store.localSitePreviewRuntimeStatus.isRunning ? "play.circle" : "stop.circle")
        )
        .font(.caption)
        .foregroundStyle(
          store.localSitePreviewRuntimeStatus.isReachable ? WorkbenchTheme.success : Color.secondary
        )
        .accessibilityIdentifier("repository-preview-runtime-status")

        Label(
          plan.diagnostics.statusTitle,
          systemImage: plan.diagnostics.isReadyToStart
            ? "checkmark.seal" : "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(
          plan.diagnostics.isReadyToStart ? WorkbenchTheme.success : WorkbenchTheme.warning)

        ForEach(plan.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 8) {
          Label("诊断信息", systemImage: "stethoscope")
            .font(.callout.weight(.semibold))

          Text(plan.command)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .lineLimit(3)

          Button {
            copy(plan.command, message: "已复制本地预览启动命令。")
          } label: {
            Label("复制启动命令", systemImage: "terminal")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("repository-preview-copy-command")

          if let pid = store.localSitePreviewRuntimeStatus.processIdentifier {
            Text("PID \(pid)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }

          if !store.localSitePreviewRuntimeStatus.recentLogLines.isEmpty {
            Text("最近日志")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(
              store.localSitePreviewRuntimeStatus.recentLogLines.suffix(8).joined(separator: "\n")
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(8)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          WorkbenchBackgroundStyle.control,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-preview-diagnostics")
      }
      .padding(14)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-local-preview")
    }
  }
}
