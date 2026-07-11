import AppKit
import PublishingWorkbenchCore
import SwiftUI
import WebKit

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

          Button {
            isLocalPreviewPresented = true
          } label: {
            Label("内嵌预览", systemImage: "rectangle.on.rectangle")
          }
          .disabled(!store.localSitePreviewRuntimeStatus.isReachable)

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

        Label(
          store.localSitePreviewRuntimeStatus.message,
          systemImage: store.localSitePreviewRuntimeStatus.isReachable
            ? "checkmark.circle"
            : (store.localSitePreviewRuntimeStatus.isRunning ? "play.circle" : "stop.circle")
        )
          .font(.caption)
          .foregroundStyle(store.localSitePreviewRuntimeStatus.isReachable ? .green : .secondary)

        if let pid = store.localSitePreviewRuntimeStatus.processIdentifier {
          Text("PID \(pid)")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }

        if !store.localSitePreviewRuntimeStatus.recentLogLines.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("最近日志")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(store.localSitePreviewRuntimeStatus.recentLogLines.suffix(8).joined(separator: "\n"))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(8)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

struct LocalSitePreviewSheet: View {
  let previewURL: URL?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("本地站点预览")
          .font(.headline)
        Spacer()
        if let previewURL {
          Button {
            ExternalURLOpener.open(previewURL)
          } label: {
            Label("在浏览器中打开", systemImage: "safari")
          }
        }
        Button("关闭") {
          dismiss()
        }
      }
      .padding(12)
      .background(.bar)

      if let previewURL {
        LocalSitePreviewWebView(url: previewURL)
          .frame(minWidth: 760, minHeight: 520)
      } else {
        ContentUnavailableView(
          "预览地址不可用",
          systemImage: "network.slash",
          description: Text("请先启动并检测本地预览服务器。")
        )
        .frame(minWidth: 520, minHeight: 320)
      }
    }
  }
}

private struct LocalSitePreviewWebView: NSViewRepresentable {
  let url: URL

  final class Coordinator {
    var lastLoadedURL: URL?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    guard context.coordinator.lastLoadedURL != url else { return }
    context.coordinator.lastLoadedURL = url
    nsView.load(URLRequest(url: url))
  }
}
