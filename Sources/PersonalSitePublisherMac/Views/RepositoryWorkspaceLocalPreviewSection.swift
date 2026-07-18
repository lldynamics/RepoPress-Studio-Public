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
            Task {
              await store.verifyLocalSitePreviewReachability()
            }
          } label: {
            Label("检测端口", systemImage: "network")
          }
          .disabled(!store.localSitePreviewRuntimeStatus.isRunning)

          if let draft = store.selectedDraft, let articleURL = store.localSitePreviewURL(for: draft) {
            Button {
              ExternalURLOpener.open(articleURL)
            } label: {
              Label("打开当前文章", systemImage: "doc.richtext")
            }
            .disabled(!store.localSitePreviewRuntimeStatus.isReachable)
          }

          Button {
            ExternalURLOpener.open(plan.previewURL)
          } label: {
            Label("打开预览", systemImage: "safari")
          }
        }

        Label(
          store.localSitePreviewRuntimeStatus.message,
          systemImage: store.localSitePreviewRuntimeStatus.isReachable
            ? "checkmark.circle"
            : (store.localSitePreviewRuntimeStatus.isRunning ? "play.circle" : "stop.circle")
        )
          .font(.caption)
          .foregroundStyle(store.localSitePreviewRuntimeStatus.isReachable ? WorkbenchTheme.success : Color.secondary)

        ForEach(plan.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        DisclosureGroup {
          VStack(alignment: .leading, spacing: 6) {
            Text(plan.command)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .lineLimit(3)

            Button {
              copy(plan.command, message: "已复制本地预览启动命令。")
            } label: {
              Label("复制启动命令", systemImage: "terminal")
            }

            if let pid = store.localSitePreviewRuntimeStatus.processIdentifier {
              Text("PID \(pid)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }

            if !store.localSitePreviewRuntimeStatus.recentLogLines.isEmpty {
              Text("最近日志")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(store.localSitePreviewRuntimeStatus.recentLogLines.suffix(8).joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } label: {
          Label("诊断信息", systemImage: "stethoscope")
            .font(.caption.weight(.semibold))
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }
}
