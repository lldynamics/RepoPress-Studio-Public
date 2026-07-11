import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentDefaultsSection: View {
  let readiness: DeploymentStatusProviderReadiness
  let deploymentProviderBinding: Binding<DeploymentProvider>
  let deploymentProviderDisplayName: String
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
    Section("部署状态默认") {
      Picker("平台", selection: deploymentProviderBinding) {
        ForEach(DeploymentProvider.allCases) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .accessibilityLabel("部署状态平台")
      .accessibilityValue(deploymentProviderDisplayName)

      TextField("站点 URL", text: deploymentSiteURL)
        .accessibilityLabel("站点 URL")
        .accessibilityValue(deploymentSiteURLDisplayValue)

      TextField("状态端点 URL", text: deploymentStatusEndpointURL)
        .accessibilityLabel("状态端点 URL")
        .accessibilityValue(deploymentStatusEndpointURLDisplayValue)

      Toggle("状态端点使用部署 Token", isOn: deploymentStatusEndpointUsesTokenBinding)
        .accessibilityLabel("状态端点使用部署 Token")
        .accessibilityValue(deploymentStatusEndpointUsesTokenBinding.wrappedValue ? "开启" : "关闭")

      TextField("部署项目 / Site ID", text: deploymentProjectID)
        .accessibilityLabel("部署项目或 Site ID")
        .accessibilityValue(deploymentProjectIDDisplayValue)

      TextField("部署账号 / Team / Account ID", text: deploymentAccountID)
        .accessibilityLabel("部署账号、Team 或 Account ID")
        .accessibilityValue(deploymentAccountIDDisplayValue)

      Text("GitHub/GitLab 会优先读取 Pages 与构建状态；Netlify 填写 Site ID 和 Token 后会读取最近 Deploy；Vercel、Cloudflare Pages 和自定义平台使用这里的状态端点或站点 URL 做发布后校验。只有开启状态端点授权时，才会向状态端点发送 Bearer Token。")
        .font(.caption)
        .foregroundStyle(.secondary)

      Label(
        readiness.statusTitle,
        systemImage: readiness.isAPIReady ? "checkmark.seal" : readiness.canCheckAnyStatus ? "exclamationmark.triangle" : "xmark.octagon"
      )
      .foregroundStyle(readiness.isAPIReady ? .green : readiness.canCheckAnyStatus ? .orange : .red)

      Text(readiness.nextStep)
        .font(.caption)
        .foregroundStyle(.secondary)

      if !readiness.missingRequirements.isEmpty {
        Text("待补齐：\(readiness.missingRequirements.joined(separator: "、"))")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      Text(readiness.fallbackMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
