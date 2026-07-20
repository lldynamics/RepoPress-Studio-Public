import AppKit
import SwiftUI

#if !APP_STORE_BUILD
struct BrowserExtensionConnectionView: View {
  @EnvironmentObject private var bridge: KnowledgeBrowserBridge
  @Environment(\.dismiss) private var dismiss
  @State private var isTokenVisible = false
  @State private var isRotationConfirmationPresented = false
  @State private var firefoxReleaseState = FirefoxExtensionReleaseState.detect()
  @State private var nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
  @State private var nativeMessagingMessage: String?
  @State private var browserPendingNativeMessagingUninstall: BrowserNativeMessagingBrowser?

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
          LabeledContent(String(localized: "传输"), value: "Unix Domain Socket")
          LabeledContent {
            Text(KnowledgeBrowserBridge.socketPath)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          } label: {
            Text("套接字")
          }
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
          Text("令牌只用于本机原生连接。不要粘贴到网页或发送给其他人。")
            .font(.caption)
            .foregroundStyle(.secondary)
          LabeledContent("有效期") {
            Text(bridge.connectionTokenExpiresAt.formatted(date: .abbreviated, time: .shortened))
              .monospacedDigit()
          }
          Text("连接令牌有效 30 天；过期或手动更换后，旧令牌会立即失效，插件需要重新配对。")
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

        Section("浏览器原生连接") {
          ForEach(BrowserNativeMessagingBrowser.allCases) { browser in
            let state = nativeMessagingState(for: browser)
            LabeledContent(browser.localizedDisplayName) {
              Label(
                nativeMessagingStatusTitle(state),
                systemImage: state.isInstalled ? "checkmark.shield.fill" : "shield.lefthalf.filled"
              )
              .foregroundStyle(state.isInstalled ? WorkbenchTheme.success : .orange)
            }
            Text(state.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack {
              Button {
                installNativeMessagingHost(for: browser)
              } label: {
                Label(
                  state.isInstalled ? "修复原生连接" : "安装原生连接",
                  systemImage: "link.badge.plus"
                )
              }
              if state.hasManifest {
                Button(role: .destructive) {
                  browserPendingNativeMessagingUninstall = browser
                } label: {
                  Label("卸载原生连接", systemImage: "link.badge.minus")
                }
              }
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.manifestURL])
              } label: {
                Label("显示宿主清单", systemImage: "doc.text.magnifyingglass")
              }
              .disabled(!FileManager.default.fileExists(atPath: state.manifestURL.path))
            }
            if browser != .edge {
              Divider()
            }
          }
          if let nativeMessagingMessage {
            Text(nativeMessagingMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Text("安装操作只写入当前用户对应浏览器的 NativeMessagingHosts 目录，无需管理员权限。插件仍需连接令牌，原生宿主不能绕过资料库鉴权。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Firefox 长期安装") {
          LabeledContent("发布版本", value: firefoxReleaseState.version ?? "未知")
          LabeledContent("Mozilla 签名") {
            Label(firefoxReleaseState.statusTitle, systemImage: firefoxReleaseState.statusSymbol)
              .foregroundStyle(firefoxReleaseState.statusColor)
          }
          Text(firefoxReleaseState.statusDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            if let signedPackageURL = firefoxReleaseState.signedPackageURL {
              Button {
                NSWorkspace.shared.open(signedPackageURL)
              } label: {
                Label("让 Firefox 验证并安装…", systemImage: "puzzlepiece.extension")
              }
              .help("交给 Firefox 打开，并由 Firefox 显示最终安装确认。")
            }
            Button {
              revealFirefoxReleaseDirectory()
            } label: {
              Label("显示发布目录", systemImage: "shippingbox")
            }
            .disabled(firefoxReleaseState.releaseDirectoryURL == nil)
          }
        }

        Section("保存内容") {
          Text("Chrome/Edge 会优先生成自包含 MHTML 归档；Firefox 会在 24 MB 上限内将可读取的图片、样式和字体内联为离线 HTML，并报告未能内联的外部资源。应用暂时未连接时，插件会在自己的本地队列中保留待导入内容，恢复后自动重试。脚本不会作为检索文本执行。")
            .font(.callout)
        }
      }
      .formStyle(.grouped)
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 640)
    .onAppear {
      bridge.refreshExpiredConnectionToken()
      firefoxReleaseState = FirefoxExtensionReleaseState.detect()
      nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
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
      Text("现有浏览器插件会立即断开，需要粘贴新令牌后重新连接。")
    }
    .confirmationDialog(
      "卸载浏览器原生连接？",
      isPresented: Binding(
        get: { browserPendingNativeMessagingUninstall != nil },
        set: { if !$0 { browserPendingNativeMessagingUninstall = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let browser = browserPendingNativeMessagingUninstall {
        Button("卸载 \(browser.localizedDisplayName) 原生连接", role: .destructive) {
          uninstallNativeMessagingHost(for: browser)
        }
      }
      Button("取消", role: .cancel) {
        browserPendingNativeMessagingUninstall = nil
      }
    } message: {
      Text("只会删除当前用户的宿主清单和安装收据，不会删除浏览器插件或资料库内容。")
    }
  }

  private var maskedToken: String {
    String(repeating: "•", count: 24)
  }

  private func nativeMessagingState(
    for browser: BrowserNativeMessagingBrowser
  ) -> BrowserNativeMessagingInstallationState {
    nativeMessagingStates[browser]
      ?? BrowserNativeMessagingInstaller.detect(browser: browser)
  }

  private func nativeMessagingStatusTitle(
    _ state: BrowserNativeMessagingInstallationState
  ) -> String {
    switch state.health {
    case .healthy:
      String(localized: "Native Messaging 已验证")
    case .notInstalled:
      String(localized: "需要安装原生宿主")
    case .invalidHostSignature:
      String(localized: "宿主签名无效")
    case .protocolMismatch:
      String(localized: "协议版本不兼容")
    case .invalidManifest, .staleHostPath, .hostUnavailable, .staleReceipt:
      String(localized: "原生连接需要修复")
    }
  }

  private func installNativeMessagingHost(for browser: BrowserNativeMessagingBrowser) {
    do {
      let manifestURL = try BrowserNativeMessagingInstaller.install(browser: browser)
      nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
      nativeMessagingMessage = String(
        localized: "已为 \(browser.localizedDisplayName) 安装宿主清单：\(manifestURL.path)。请重新打开浏览器插件。"
      )
    } catch {
      nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
      nativeMessagingMessage = error.localizedDescription
    }
  }

  private func uninstallNativeMessagingHost(for browser: BrowserNativeMessagingBrowser) {
    defer { browserPendingNativeMessagingUninstall = nil }
    do {
      try BrowserNativeMessagingInstaller.uninstall(browser: browser)
      nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
      nativeMessagingMessage = String(
        localized: "已卸载 \(browser.localizedDisplayName) 的原生连接。"
      )
    } catch {
      nativeMessagingStates = BrowserNativeMessagingInstaller.detectAll()
      nativeMessagingMessage = error.localizedDescription
    }
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

  private func revealFirefoxReleaseDirectory() {
    guard let directory = firefoxReleaseState.releaseDirectoryURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }
}

private struct FirefoxExtensionReleaseState {
  let version: String?
  let signedPackageURL: URL?
  let unsignedPackageURL: URL?
  let releaseDirectoryURL: URL?

  var statusTitle: String {
    if signedPackageURL != nil { return "签名包已就绪，等待 Firefox 验证" }
    if unsignedPackageURL != nil { return "候选包已就绪，等待签名" }
    return "尚未生成发布包"
  }

  var statusSymbol: String {
    if signedPackageURL != nil { return "checkmark.seal.fill" }
    if unsignedPackageURL != nil { return "clock.badge.exclamationmark" }
    return "shippingbox"
  }

  var statusColor: Color {
    if signedPackageURL != nil { return WorkbenchTheme.success }
    if unsignedPackageURL != nil { return .orange }
    return .secondary
  }

  var statusDescription: String {
    if signedPackageURL != nil {
      return "发布工具已确认包内正文与当前候选源码一致；Mozilla 证书信任由 Firefox 在安装时最终验证。验证通过后可长期安装并通过 HTTPS 更新清单升级。"
    }
    if unsignedPackageURL != nil {
      return "已生成可复现的未签名验证包。Firefox 正式版会拒绝它，需要先完成 Mozilla 的 unlisted 签名。"
    }
    return "发布脚本会校验版本、扩展 ID、数据声明和 HTTPS 更新地址，再生成待签名候选包。"
  }

  static func detect() -> Self {
    let bundledExtensionRoot = Bundle.main.resourceURL?
      .appendingPathComponent("BrowserExtension", isDirectory: true)
    let projectRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceExtensionRoot = projectRoot.appendingPathComponent("BrowserExtension", isDirectory: true)
    let extensionRoots = [bundledExtensionRoot, sourceExtensionRoot].compactMap { $0 }
    let version = extensionRoots.lazy.compactMap { root in
      manifestVersion(at: root.appendingPathComponent("Firefox/manifest.json"))
    }.first

    let releaseDirectories = [
      bundledExtensionRoot?.appendingPathComponent("Release", isDirectory: true),
      projectRoot.appendingPathComponent("dist/browser-extension", isDirectory: true)
    ].compactMap { $0 }
    let existingReleaseDirectories = releaseDirectories.filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    let signedName = version.map { "knowledge-capture-firefox-\($0).xpi" }
    let unsignedName = version.map { "knowledge-capture-firefox-\($0)-unsigned.xpi" }

    return Self(
      version: version,
      signedPackageURL: signedName.flatMap { name in
        existingReleaseDirectories.lazy.map { $0.appendingPathComponent(name) }
          .first { FileManager.default.fileExists(atPath: $0.path) }
      },
      unsignedPackageURL: unsignedName.flatMap { name in
        existingReleaseDirectories.lazy.map { $0.appendingPathComponent(name) }
          .first { FileManager.default.fileExists(atPath: $0.path) }
      },
      releaseDirectoryURL: existingReleaseDirectories.first
    )
  }

  private static func manifestVersion(at url: URL) -> String? {
    guard
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["version"] as? String
  }
}
#endif
