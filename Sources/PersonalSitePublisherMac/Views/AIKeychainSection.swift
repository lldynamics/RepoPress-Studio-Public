import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct AIKeychainSection: View {
  let aiAPIKeyInput: Binding<String>
  let config: AIProviderConfig
  let tokenAvailability: KeychainTokenAvailability
  let connectionReport: AIConnectionTestReport?
  let isAIActionRunning: Bool
  let actionMessage: String?
  let onSaveAPIKey: () -> Void
  let onDeleteAPIKey: () -> Void
  let onRefreshState: () -> Void
  let onTestConnection: () -> Void

  var body: some View {
    Section("Keychain") {
      SecureField("API Key", text: aiAPIKeyInput)
        .accessibilityLabel("AI API Key")
        .accessibilityHint("输入后可保存到钥匙串")

      AIConnectionStatusCard(
        config: config,
        tokenAvailability: tokenAvailability,
        report: connectionReport
      )

      HStack {
        Button("保存 API Key") {
          onSaveAPIKey()
        }
        .accessibilityLabel("保存 AI API Key")

        Button("删除") {
          onDeleteAPIKey()
        }
        .accessibilityLabel("删除 AI API Key")

        Button("刷新状态") {
          onRefreshState()
        }
        .accessibilityLabel("刷新 AI Key 状态")

        Button {
          onTestConnection()
        } label: {
          Label("测试连接", systemImage: "network")
        }
        .disabled(isAIActionRunning)
        .accessibilityLabel("测试 AI 连接")
      }

      Label(
        tokenAvailability.hasToken ? "已保存 API Key" : "未保存 API Key",
        systemImage: tokenAvailability.hasToken ? "checkmark.seal" : "key"
      )
      .foregroundStyle(tokenAvailability.hasToken ? .green : .secondary)

      if let message = actionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
