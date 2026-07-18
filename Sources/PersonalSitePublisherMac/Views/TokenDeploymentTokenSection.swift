import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentTokenSection: View {
  let deploymentProvider: DeploymentProvider
  let deploymentTokenInput: Binding<String>
  let hasDeploymentToken: Bool
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void
  @State private var isDeleteConfirmationPresented = false

  var body: some View {
    Section("部署凭据") {
      SecureField(String(localized: "部署平台访问令牌"), text: deploymentTokenInput)
        .accessibilityLabel("部署平台访问令牌")
        .accessibilityHint(deploymentTokenHint)

      HStack {
        Button(String(localized: "保存部署访问令牌"), action: onSaveToken)
          .workbenchProminentActionStyle()
          .disabled(deploymentTokenInput.wrappedValue.trimmedForPublishing.isEmpty)
      }

      HStack {
        Label(deploymentTokenStatusText, systemImage: hasDeploymentToken ? "checkmark.seal" : "key")
          .foregroundStyle(hasDeploymentToken ? WorkbenchTheme.success : Color.secondary)

        Spacer()

        Button("刷新状态", action: onRefreshTokenState)
          .buttonStyle(.borderless)

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!hasDeploymentToken)
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
    hasDeploymentToken
      ? String(localized: "已保存部署访问令牌")
      : String(localized: "未保存部署访问令牌")
  }

  private var deploymentTokenHint: String {
    deploymentProvider == .custom
      ? String(localized: "仅用于自定义 HTTPS 状态端点")
      : String(localized: "仅用于当前部署平台的官方 API")
  }
}
