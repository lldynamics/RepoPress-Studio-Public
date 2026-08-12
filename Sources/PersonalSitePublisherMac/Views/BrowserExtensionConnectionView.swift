import AppKit
import BrowserExtensionProtocolSupport
import SafariServices
import SwiftUI

struct BrowserExtensionConnectionView: View {
  @EnvironmentObject private var bridge: KnowledgeBrowserBridge
  @Environment(\.dismiss) private var dismiss
  @State private var isTokenVisible = false
  @State private var isRotationConfirmationPresented = false
  @State private var isLedgerRebuildConfirmationPresented = false
  @State private var safariExtensionIsEnabled: Bool?
  @State private var safariExtensionStatusMessage = "正在检查 Safari 扩展状态…"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("浏览器资料采集")
            .font(.title2.weight(.semibold))
          Text("使用浏览器官方扩展，把网页归档和可检索正文保存到本机资料库。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭") { dismiss() }
      }
      .padding(20)

      Divider()

      Form {
        Section("本机连接") {
          Toggle(
            "启用浏览器连接",
            isOn: Binding(
              get: { bridge.isEnabled },
              set: { bridge.setEnabled($0) }
            )
          )
          if bridge.isEnabled {
            LabeledContent("状态") {
              Label(
                bridge.localizedStatusDisplayName,
                systemImage: bridge.state == .ready
                  ? "checkmark.circle.fill"
                  : "circle.dotted"
              )
              .foregroundStyle(
                bridge.state == .ready ? WorkbenchTheme.success : Color.secondary
              )
            }
            LabeledContent("地址") {
              Text(KnowledgeBrowserBridge.endpointURL)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
            Text("连接只监听 127.0.0.1，不接受局域网或互联网访问；每次请求还必须携带下面的随机令牌。")
              .font(.caption)
              .foregroundStyle(.secondary)
            if let lastMessage = bridge.lastMessage {
              Text(lastMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if bridge.importOperationLedgerPersistenceIssue != nil {
              HStack {
                if bridge.requiresImportOperationLedgerRebuild {
                  Button("备份并重建账本…", role: .destructive) {
                    isLedgerRebuildConfirmationPresented = true
                  }
                } else {
                  Button("重试账本写入") {
                    Task {
                      await bridge.retryImportOperationLedgerPersistence()
                    }
                  }
                }
              }
            }
          } else {
            Text("关闭时不会访问浏览器连接钥匙串，也不会监听本机端口。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if bridge.isEnabled {
          Section("扩展连接令牌") {
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
            Text("令牌只用于你安装的浏览器扩展。不要粘贴到网页或发送给其他人。")
              .font(.caption)
              .foregroundStyle(.secondary)
            LabeledContent("有效期") {
              Text(
                bridge.connectionTokenExpiresAt.formatted(
                  date: .abbreviated,
                  time: .shortened
                )
              )
              .monospacedDigit()
            }
            Button("更换连接令牌…", role: .destructive) {
              isRotationConfirmationPresented = true
            }
          }
        }

        Section("安装浏览器扩展") {
          Text("当前版本支持 Safari、Chrome 和 Firefox。Safari Web Extension 随应用内置；Chrome 和 Firefox 扩展独立安装和更新。")
            .font(.callout)

          LabeledContent("Safari") {
            HStack(spacing: 10) {
              Label(
                safariExtensionStatusMessage,
                systemImage: safariExtensionIsEnabled == true
                  ? "checkmark.circle.fill"
                  : "safari"
              )
              .foregroundStyle(
                safariExtensionIsEnabled == true ? WorkbenchTheme.success : Color.secondary
              )
              Button("打开扩展设置") {
                openSafariExtensionSettings()
              }
              Button {
                refreshSafariExtensionState()
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .help("重新检查 Safari 扩展状态")
            }
          }

          LabeledContent("Chrome") {
            Button {
              openChromeWebStore()
            } label: {
              Label("打开 Chrome 网上应用店", systemImage: "arrow.up.right.square")
            }
          }

          LabeledContent("Firefox") {
            VStack(alignment: .leading, spacing: 6) {
              Button {
                openFirefoxDebugging()
              } label: {
                Label("打开 Firefox 调试页", systemImage: "wrench.and.screwdriver")
              }
              Text("Firefox 在 about:debugging 中选择“临时载入附加组件”，再选中 BrowserExtension/Firefox/manifest.json。加载后把上面的令牌粘贴到插件中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          Text("Safari 扩展随应用安装；Chrome 和 Firefox 扩展独立更新，均通过本机回环接口连接。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("保存内容") {
          Text("Chrome 优先生成自包含 MHTML；Safari 和 Firefox 在大小上限内生成离线 HTML。应用未打开时，扩展会把待导入内容保留在浏览器本地队列，应用恢复后再重试。")
            .font(.callout)
        }
      }
      .formStyle(.grouped)
    }
    .frame(minWidth: 660, idealWidth: 760, minHeight: 600, idealHeight: 680)
    .onAppear {
      bridge.refreshExpiredConnectionToken()
      refreshSafariExtensionState()
    }
    .onChange(of: bridge.lastOpenedDocumentID) { _, documentID in
      if documentID != nil { dismiss() }
    }
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
      Text("现有浏览器扩展会立即断开，需要粘贴新令牌后重新连接。")
    }
    .confirmationDialog(
      "备份并重建浏览器保存账本？",
      isPresented: $isLedgerRebuildConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("备份并重建", role: .destructive) {
        Task {
          await bridge.rebuildImportOperationLedger()
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("损坏账本会先保留为备份，然后创建空账本。已有资料不会被删除，但旧操作回执将不再用于去重。")
    }
  }

  private var maskedToken: String {
    String(repeating: "•", count: 24)
  }

  private func openChromeWebStore() {
    guard let extensionID = BrowserExtensionProtocol.chromeProductionExtensionID,
          let url = URL(
            string: "https://chromewebstore.google.com/detail/\(extensionID)"
          )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func openFirefoxDebugging() {
    guard let url = URL(string: "about:debugging#/runtime/this-firefox") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func refreshSafariExtensionState() {
    safariExtensionStatusMessage = "正在检查 Safari 扩展状态…"
    SFSafariExtensionManager.getStateOfSafariExtension(
      withIdentifier: BrowserExtensionProtocol.safariWebExtensionBundleID
    ) { state, error in
      DispatchQueue.main.async {
        if let error {
          safariExtensionIsEnabled = nil
          safariExtensionStatusMessage = "暂时无法读取状态：\(error.localizedDescription)"
        } else if state?.isEnabled == true {
          safariExtensionIsEnabled = true
          safariExtensionStatusMessage = "已启用"
        } else {
          safariExtensionIsEnabled = false
          safariExtensionStatusMessage = "已安装，尚未启用"
        }
      }
    }
  }

  private func openSafariExtensionSettings() {
    SFSafariApplication.showPreferencesForExtension(
      withIdentifier: BrowserExtensionProtocol.safariWebExtensionBundleID
    ) { error in
      DispatchQueue.main.async {
        if let error {
          safariExtensionIsEnabled = nil
          safariExtensionStatusMessage = "无法打开 Safari 设置：\(error.localizedDescription)"
        } else {
          refreshSafariExtensionState()
        }
      }
    }
  }
}
