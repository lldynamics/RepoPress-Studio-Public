import AppKit
import SwiftUI

struct BrowserExtensionConnectionView: View {
  @EnvironmentObject private var bridge: KnowledgeBrowserBridge
  @Environment(\.dismiss) private var dismiss
  @State private var isTokenVisible = false
  @State private var isRotationConfirmationPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("浏览器资料采集")
            .font(.title2.weight(.semibold))
          Text("把当前网页的完整归档和可检索正文保存到指定资料文件夹。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭") { dismiss() }
      }
      .padding(20)

      Divider()

      Form {
        Section("连接状态") {
          LabeledContent("本机桥接") {
            Label(bridge.state.localizedDisplayName, systemImage: bridge.state == .ready ? "checkmark.circle.fill" : "circle.dotted")
              .foregroundStyle(bridge.state == .ready ? WorkbenchTheme.success : Color.secondary)
          }
          LabeledContent("地址", value: "127.0.0.1:\(KnowledgeBrowserBridge.port)")
          if let lastMessage = bridge.lastMessage {
            Text(lastMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Section("插件连接令牌") {
          HStack(spacing: 10) {
            Text(isTokenVisible ? bridge.connectionToken : maskedToken)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
              .textSelection(.enabled)
            Spacer()
            Button(isTokenVisible ? "隐藏" : "显示") {
              isTokenVisible.toggle()
            }
            Button("复制") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(bridge.connectionToken, forType: .string)
            }
          }
          Text("令牌只用于本机回环接口。不要粘贴到网页或发送给其他人。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("更换连接令牌…", role: .destructive) {
            isRotationConfirmationPresented = true
          }
        }

        Section("安装 Chrome / Edge / Firefox 插件") {
          Text("Chrome/Edge 在扩展管理页启用开发者模式并加载插件文件夹；Firefox 打开 about:debugging#/runtime/this-firefox，选择“临时载入附加组件”，再选中插件文件夹里的 manifest.json。首次连接时，把上面的令牌粘贴到插件中。")
            .font(.callout)
          HStack {
            Button {
              revealExtensionFolder(for: .chromium)
            } label: {
              Label("显示 Chrome / Edge 插件", systemImage: "folder")
            }
            Button {
              revealExtensionFolder(for: .firefox)
            } label: {
              Label("显示 Firefox 插件", systemImage: "folder")
            }
          }
        }

        Section("保存内容") {
          Text("Chrome/Edge 会优先生成自包含 MHTML 归档；Firefox 会保存可检索正文与清理后的原始 HTML。两者都通过本机回环接口直接写入资料库，脚本不会作为检索文本执行。")
            .font(.callout)
        }
      }
      .formStyle(.grouped)
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 640)
    .confirmationDialog(
      "更换连接令牌？",
      isPresented: $isRotationConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("更换令牌", role: .destructive) {
        bridge.rotateConnectionToken()
        isTokenVisible = true
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("现有浏览器插件会立即断开，需要粘贴新令牌后重新连接。")
    }
  }

  private var maskedToken: String {
    String(repeating: "•", count: 24)
  }

  private enum BrowserExtensionKind {
    case chromium
    case firefox
  }

  private func revealExtensionFolder(for kind: BrowserExtensionKind) {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension", isDirectory: true)
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BrowserExtension", isDirectory: true)
    let roots = [bundled, source]
      .compactMap { $0 }
    let target = roots
      .map { root in
        kind == .firefox
          ? root.appendingPathComponent("Firefox", isDirectory: true)
          : root
      }
      .first { FileManager.default.fileExists(atPath: $0.path) }
    guard let target else { return }
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }
}
