import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var localPreviewSection: some View {
    if let plan = store.localSitePreviewPlan {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("本地预览")
              .font(.headline)
            Text(plan.previewURL.absoluteString)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button {
            store.startLocalSitePreview()
          } label: {
            Label("启动预览", systemImage: "play.circle")
          }
          .disabled(store.localSitePreviewRuntimeStatus.isRunning)

          Button {
            store.stopLocalSitePreview()
          } label: {
            Label("停止", systemImage: "stop.circle")
          }
          .disabled(!store.localSitePreviewRuntimeStatus.isRunning)

          Button {
            ExternalURLOpener.open(plan.previewURL)
          } label: {
            Label("打开预览", systemImage: "safari")
          }
          Button {
            copy(plan.command, message: "已复制本地预览启动命令。")
          } label: {
            Label("复制启动命令", systemImage: "terminal")
          }
        }

        Text(plan.command)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .lineLimit(3)

        Label(store.localSitePreviewRuntimeStatus.message, systemImage: store.localSitePreviewRuntimeStatus.isRunning ? "play.circle" : "stop.circle")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let pid = store.localSitePreviewRuntimeStatus.processIdentifier {
          Text("PID \(pid)")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }

        ForEach(plan.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }
}
