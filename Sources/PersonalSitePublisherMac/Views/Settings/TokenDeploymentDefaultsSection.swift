import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentDefaultsSection: View {
  let deploymentProviderBinding: Binding<DeploymentProvider>
  let deploymentProviderDisplayName: String
  let productionVerificationIssues: [String]
  let needsExplicitProviderConfirmation: Bool
  let deploymentSiteURL: Binding<String>
  let deploymentSiteURLDisplayValue: String
  let deploymentStatusEndpointURL: Binding<String>
  let deploymentStatusEndpointURLDisplayValue: String
  let deploymentStatusEndpointUsesTokenBinding: Binding<Bool>
  let deploymentProjectID: Binding<String>
  let deploymentProjectIDDisplayValue: String
  let deploymentAccountID: Binding<String>
  let deploymentAccountIDDisplayValue: String

  var body: some View {
    Section("连接必填") {
      Picker("平台", selection: deploymentProviderBinding) {
        ForEach(DeploymentProvider.allCases) { provider in
          Text(provider.localizedDisplayName).tag(provider)
        }
      }
      .accessibilityLabel("部署状态平台")
      .accessibilityValue(deploymentProviderDisplayName)

      if !productionVerificationIssues.isEmpty {
        Label("生产部署尚未完整配置", systemImage: "exclamationmark.triangle")
          .foregroundStyle(WorkbenchTheme.warning)

        Text(productionVerificationIssues.joined(separator: "\n"))
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityIdentifier("deployment-platform-configuration-warning")
      }

      if needsExplicitProviderConfirmation {
        Button("确认使用\(deploymentProviderDisplayName)") {
          deploymentProviderBinding.wrappedValue = deploymentProviderBinding.wrappedValue
        }
        .accessibilityIdentifier("confirm-deployment-provider")
      }

      TextField("站点 URL", text: deploymentSiteURL)
        .accessibilityLabel("站点 URL")
        .accessibilityValue(deploymentSiteURLDisplayValue)

      TextField("状态端点 URL", text: deploymentStatusEndpointURL)
        .accessibilityLabel("状态端点 URL")
        .accessibilityValue(deploymentStatusEndpointURLDisplayValue)

      Toggle("状态端点使用部署访问令牌", isOn: deploymentStatusEndpointUsesTokenBinding)
        .accessibilityLabel("状态端点使用部署访问令牌")
        .accessibilityValue(deploymentStatusEndpointUsesTokenBinding.wrappedValue ? "开启" : "关闭")
        .disabled(deploymentProviderBinding.wrappedValue != .custom)

      if deploymentProviderBinding.wrappedValue != .custom {
        Text("平台部署访问令牌只发送到平台官方 API；如需向状态端点发送 Bearer Token，请选择“自定义端点”平台并使用 HTTPS。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      TextField("部署项目 / Site ID", text: deploymentProjectID)
        .accessibilityLabel("部署项目或 Site ID")
        .accessibilityValue(deploymentProjectIDDisplayValue)

      TextField("部署账号 / Team / Account ID", text: deploymentAccountID)
        .accessibilityLabel("部署账号、Team 或 Account ID")
        .accessibilityValue(deploymentAccountIDDisplayValue)

      Text(
        "GitHub/GitLab 会优先读取 Pages 与构建状态；Netlify 填写站点 ID 和访问令牌后会读取最近部署记录；Vercel、Cloudflare Pages 和自定义平台使用这里的状态端点或站点 URL 做发布后校验。只有自定义平台的 HTTPS 状态端点可使用 Bearer Token。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
