import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct AIKeychainSection: View {
  let aiAPIKeyInput: Binding<String>
  let shouldFocusInput: Bool
  let navigationRequestID: UUID
  let config: AIProviderConfig
  let tokenAvailability: KeychainTokenAvailability
  let connectionReport: AIConnectionTestReport?
  let isConnectionReportStale: Bool
  let isAIActionRunning: Bool
  let actionMessage: String?
  let onSaveAPIKey: () -> Void
  let onDeleteAPIKey: () -> Void
  let onRefreshState: () -> Void
  let onTestConnection: () -> Void
  @FocusState private var isAPIKeyFocused: Bool
  @State private var isDeleteConfirmationPresented = false
  @State private var isKeyRevealed = false

  var body: some View {
    Section("API 凭据") {
      HStack(spacing: 8) {
        if isKeyRevealed {
          TextField("API Key", text: aiAPIKeyInput)
            .focused($isAPIKeyFocused)
            .font(.body.monospaced())
            .accessibilityLabel("AI API Key")
        } else {
          SecureField("API Key", text: aiAPIKeyInput)
            .focused($isAPIKeyFocused)
            .accessibilityLabel("AI API Key")
        }

        Button {
          isKeyRevealed.toggle()
        } label: {
          Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyRevealed ? "隐藏 API Key" : "显示 API Key 明文")
      }
      .accessibilityLabel("AI API Key")
      .accessibilityHint("输入后可保存到钥匙串")

      AIConnectionStatusCard(
        config: config,
        tokenAvailability: tokenAvailability,
        report: connectionReport
      )

      if isConnectionReportStale {
        Label("AI 配置或 Key 已变化，之前的连接测试结果已失效。", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      HStack {
        Button("保存 API Key") {
          onSaveAPIKey()
        }
        .workbenchProminentActionStyle()
        .disabled(aiAPIKeyInput.wrappedValue.trimmedForPublishing.isEmpty)
        .accessibilityLabel("保存 AI API Key")

        Button {
          onTestConnection()
        } label: {
          Label("测试连接", systemImage: "network")
        }
        .buttonStyle(.bordered)
        .disabled(isAIActionRunning)
        .accessibilityLabel("测试 AI 连接")
      }

      HStack {
        Label(
          tokenStatusTitle,
          systemImage: tokenAvailability.hasToken ? "checkmark.seal" : "key"
        )
        .foregroundStyle(tokenAvailability.hasToken ? WorkbenchTheme.success : .secondary)

        Spacer()

        Button("刷新状态") {
          onRefreshState()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("刷新 AI Key 状态")

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!tokenAvailability.hasToken)
        .accessibilityLabel("删除 AI API Key")
      }

      if let message = actionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        Image(systemName: "lock.shield.fill")
          .font(.caption)
          .foregroundStyle(Color.accentColor)
        Text("API Key 使用 macOS 系统 Keychain (AES-256) 本地安全加密保存，请求直接直连目标 API，绝无云端中转。")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    }
    .task(id: navigationRequestID) {
      guard shouldFocusInput else { return }
      isAPIKeyFocused = true
    }
    .confirmationDialog(
      "删除\(config.normalizedDisplayName) API Key？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(config.normalizedDisplayName) API Key", role: .destructive) {
        onDeleteAPIKey()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，使用当前服务的 AI 写作、对话和批量建议将不可用，直到重新保存 Key。")
    }
  }

  private var tokenStatusTitle: LocalizedStringKey {
    tokenAvailability.hasToken ? "已保存 API Key" : "未保存 API Key"
  }
}
