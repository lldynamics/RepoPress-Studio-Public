import PublishingWorkbenchCore
import SwiftUI

struct TokenDeploymentAutomationSection: View {
  @ObservedObject var automationSettings: WorkbenchAutomationSettingsFeatureFacade

  var body: some View {
    Section("当前工作区部署自动化") {
      Toggle("启用当前工作区部署状态自动检查", isOn: deploymentPollingEnabledBinding)
        .toggleStyle(.switch)
        .accessibilityLabel("启用当前工作区部署状态自动检查")
        .accessibilityValue(
          automationSettings.deploymentPollingSettings.isEnabled ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-deployment-polling-enabled")

      Picker("当前工作区最短检查间隔", selection: deploymentPollingIntervalBinding) {
        ForEach(TokenDeploymentAutomationSettingsSupport.intervalOptions, id: \.self) { minutes in
          Text("\(minutes) 分钟").tag(minutes)
        }
      }
      .pickerStyle(.menu)
      .disabled(!automationSettings.deploymentPollingSettings.isEnabled)
      .accessibilityLabel("当前工作区部署状态自动检查最短间隔")
      .accessibilityValue(
        "\(automationSettings.deploymentPollingSettings.normalizedIntervalMinutes) 分钟"
      )
      .accessibilityIdentifier("token-deployment-polling-interval")

      Text("这些选项只作用于当前工作区；发布或回到前台时会按需检查，所选分钟数用于限制最短重检间隔。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("token-deployment-automation")
  }

  private var deploymentPollingEnabledBinding: Binding<Bool> {
    Binding(
      get: { automationSettings.deploymentPollingSettings.isEnabled },
      set: { isEnabled in
        automationSettings.updateDeploymentPollingSettings(
          TokenDeploymentAutomationSettingsSupport.updated(
            automationSettings.deploymentPollingSettings,
            isEnabled: isEnabled
          )
        )
      }
    )
  }

  private var deploymentPollingIntervalBinding: Binding<Int> {
    Binding(
      get: { automationSettings.deploymentPollingSettings.normalizedIntervalMinutes },
      set: { intervalMinutes in
        automationSettings.updateDeploymentPollingSettings(
          TokenDeploymentAutomationSettingsSupport.updated(
            automationSettings.deploymentPollingSettings,
            intervalMinutes: intervalMinutes
          )
        )
      }
    )
  }
}

enum TokenDeploymentAutomationSettingsSupport {
  static let intervalOptions = [
    DeploymentPollingSettings.minimumIntervalMinutes,
    10,
    15,
    30,
    DeploymentPollingSettings.maximumIntervalMinutes,
  ]

  static func updated(
    _ settings: DeploymentPollingSettings,
    isEnabled: Bool? = nil,
    intervalMinutes: Int? = nil
  ) -> DeploymentPollingSettings {
    DeploymentPollingSettings(
      isEnabled: isEnabled ?? settings.isEnabled,
      intervalMinutes: normalizedInterval(
        intervalMinutes ?? settings.normalizedIntervalMinutes,
        minimum: DeploymentPollingSettings.minimumIntervalMinutes,
        maximum: DeploymentPollingSettings.maximumIntervalMinutes
      )
    )
  }

  private static func normalizedInterval(_ value: Int, minimum: Int, maximum: Int) -> Int {
    min(maximum, max(minimum, value))
  }
}
