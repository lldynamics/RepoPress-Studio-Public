import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentTokenSection: View {
  let deploymentProvider: DeploymentProvider
  let deploymentTokenInput: Binding<String>
  let tokenAvailability: KeychainTokenAvailability
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void
  @State private var isDeleteConfirmationPresented = false
  @State private var isJustSaved = false

  var body: some View {
    Section("部署凭据") {
      SecureField(String(localized: "部署平台访问令牌"), text: deploymentTokenInput)
        .accessibilityLabel("部署平台访问令牌")
        .accessibilityHint(deploymentTokenHint)

      HStack(alignment: .center, spacing: 10) {
        Button(String(localized: "保存部署访问令牌")) {
          onSaveToken()
          withAnimation {
            isJustSaved = true
          }
          Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
              withAnimation {
                isJustSaved = false
              }
            }
          }
        }
        .workbenchProminentActionStyle()
        .disabled(deploymentTokenInput.wrappedValue.trimmedForPublishing.isEmpty)

        if isJustSaved {
          Label("已保存", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.success)
            .transition(.opacity)
        } else if !deploymentTokenInput.wrappedValue.trimmedForPublishing.isEmpty {
          Text("待保存修改")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }

      HStack {
        Label(deploymentTokenStatusText, systemImage: tokenStatusSystemImage)
          .foregroundStyle(tokenStatusColor)

        Spacer()

        Button("刷新状态", action: onRefreshTokenState)
          .buttonStyle(.borderless)

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!tokenAvailability.hasToken)
      }

      if let accessFailureMessage = tokenAvailability.accessFailureMessage {
        Text("操作失败：\(accessFailureMessage)")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .textSelection(.enabled)
      }

      Text("部署访问令牌与仓库访问令牌使用独立的钥匙串项；切换部署平台后需要保存该平台自己的令牌。旧共用令牌不会自动作为部署访问令牌使用，需要重新保存。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .confirmationDialog(
      "删除\(deploymentProvider.localizedDisplayName)部署访问令牌？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(deploymentProvider.localizedDisplayName)部署访问令牌", role: .destructive) {
        onDeleteToken()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会删除当前部署平台的独立钥匙串项，不会删除仓库访问令牌。")
    }
  }

  private var deploymentTokenStatusText: String {
    switch tokenAvailability.accessState {
    case .available:
      return String(localized: "已保存部署访问令牌")
    case .missing:
      return String(localized: "未保存部署访问令牌")
    case .accessFailed:
      return String(localized: "Keychain 读取失败")
    }
  }

  private var tokenStatusSystemImage: String {
    tokenAvailability.accessState == .accessFailed
      ? "exclamationmark.triangle"
      : (tokenAvailability.hasToken ? "checkmark.seal" : "key")
  }

  private var tokenStatusColor: Color {
    switch tokenAvailability.accessState {
    case .available:
      return WorkbenchTheme.success
    case .missing:
      return .secondary
    case .accessFailed:
      return WorkbenchTheme.warning
    }
  }

  private var deploymentTokenHint: String {
    deploymentProvider == .custom
      ? String(localized: "仅用于自定义 HTTPS 状态端点")
      : String(localized: "仅用于当前部署平台的官方 API")
  }
}
