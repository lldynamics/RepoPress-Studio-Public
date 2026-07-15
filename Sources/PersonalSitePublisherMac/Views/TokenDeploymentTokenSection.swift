import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentTokenSection: View {
  let deploymentProvider: DeploymentProvider
  let deploymentTokenInput: Binding<String>
  let hasDeploymentToken: Bool
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void

  var body: some View {
    Section("部署 Token") {
      SecureField("\(deploymentProvider.localizedDisplayName) Deployment Token", text: deploymentTokenInput)
        .accessibilityLabel("\(deploymentProvider.localizedDisplayName) 部署 Token")
        .accessibilityHint(
          deploymentProvider == .custom
            ? "仅用于自定义 HTTPS 状态端点"
            : "仅用于当前部署平台的官方 API"
        )

      HStack {
        Button("保存部署 Token", action: onSaveToken)
        Button("删除", action: onDeleteToken)
        Button("刷新状态", action: onRefreshTokenState)
      }

      Label(
        hasDeploymentToken ? "已保存 \(deploymentProvider.localizedDisplayName) 部署 Token" : "未保存 \(deploymentProvider.localizedDisplayName) 部署 Token",
        systemImage: hasDeploymentToken ? "checkmark.seal" : "key"
      )
      .foregroundStyle(hasDeploymentToken ? .green : .secondary)

      Text("部署 Token 与仓库 Token 使用独立的钥匙串项；切换部署平台后需要保存该平台自己的 Token。旧共用 Token 只会在 GitHub/GitLab Pages 的兼容场景自动迁移。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
