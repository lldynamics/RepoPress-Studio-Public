import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryAutomationSection: View {
  @ObservedObject var automationSettings: WorkbenchAutomationSettingsFeatureFacade

  var body: some View {
    Section("当前工作区自动化") {
      Toggle("启用当前工作区自动检查远端", isOn: repositoryAutoSyncEnabledBinding)
        .toggleStyle(.switch)
        .accessibilityLabel("启用当前工作区自动检查远端")
        .accessibilityValue(
          automationSettings.repositoryAutoSyncSettings.isEnabled ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-enabled")

      Picker("当前工作区最短检查间隔", selection: repositoryAutoSyncIntervalBinding) {
        ForEach(TokenRepositoryAutomationSettingsSupport.intervalOptions, id: \.self) { minutes in
          Text("\(minutes) 分钟").tag(minutes)
        }
      }
      .pickerStyle(.menu)
      .disabled(!automationSettings.repositoryAutoSyncSettings.isEnabled)
      .accessibilityLabel("当前工作区远端自动检查最短间隔")
      .accessibilityValue(
        "\(automationSettings.repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟"
      )
      .accessibilityIdentifier("token-repository-auto-sync-interval")

      Toggle("检查前 fetch upstream", isOn: repositoryAutoSyncFetchBeforeScanBinding)
        .toggleStyle(.checkbox)
        .disabled(!automationSettings.repositoryAutoSyncSettings.isEnabled)
        .accessibilityLabel("当前工作区检查前 fetch upstream")
        .accessibilityValue(
          automationSettings.repositoryAutoSyncSettings.fetchBeforeScan ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-fetch-upstream")

      Toggle("自动导入远端文章", isOn: repositoryAutoImportRemoteArticlesBinding)
        .toggleStyle(.checkbox)
        .disabled(!automationSettings.repositoryAutoSyncSettings.isEnabled)
        .accessibilityLabel("当前工作区自动导入远端文章")
        .accessibilityValue(
          automationSettings.repositoryAutoSyncSettings.autoImportRemoteArticles ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-auto-import")

      Text("这些选项只作用于当前工作区；保存、发布、切换分支或回到前台时会按需检查，所选分钟数用于限制最短重检间隔。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("token-repository-automation")
  }

  private var repositoryAutoSyncEnabledBinding: Binding<Bool> {
    Binding(
      get: { automationSettings.repositoryAutoSyncSettings.isEnabled },
      set: { isEnabled in
        automationSettings.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            automationSettings.repositoryAutoSyncSettings,
            isEnabled: isEnabled
          )
        )
      }
    )
  }

  private var repositoryAutoSyncIntervalBinding: Binding<Int> {
    Binding(
      get: { automationSettings.repositoryAutoSyncSettings.normalizedIntervalMinutes },
      set: { intervalMinutes in
        automationSettings.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            automationSettings.repositoryAutoSyncSettings,
            intervalMinutes: intervalMinutes
          )
        )
      }
    )
  }

  private var repositoryAutoSyncFetchBeforeScanBinding: Binding<Bool> {
    Binding(
      get: { automationSettings.repositoryAutoSyncSettings.fetchBeforeScan },
      set: { fetchBeforeScan in
        automationSettings.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            automationSettings.repositoryAutoSyncSettings,
            fetchBeforeScan: fetchBeforeScan
          )
        )
      }
    )
  }

  private var repositoryAutoImportRemoteArticlesBinding: Binding<Bool> {
    Binding(
      get: { automationSettings.repositoryAutoSyncSettings.autoImportRemoteArticles },
      set: { autoImportRemoteArticles in
        automationSettings.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            automationSettings.repositoryAutoSyncSettings,
            autoImportRemoteArticles: autoImportRemoteArticles
          )
        )
      }
    )
  }
}

enum TokenRepositoryAutomationSettingsSupport {
  static let intervalOptions = [
    RepositoryAutoSyncSettings.minimumIntervalMinutes,
    15,
    30,
    60,
    RepositoryAutoSyncSettings.maximumIntervalMinutes,
  ]

  static func updated(
    _ settings: RepositoryAutoSyncSettings,
    isEnabled: Bool? = nil,
    intervalMinutes: Int? = nil,
    fetchBeforeScan: Bool? = nil,
    autoImportRemoteArticles: Bool? = nil
  ) -> RepositoryAutoSyncSettings {
    RepositoryAutoSyncSettings(
      isEnabled: isEnabled ?? settings.isEnabled,
      intervalMinutes: normalizedInterval(
        intervalMinutes ?? settings.normalizedIntervalMinutes,
        minimum: RepositoryAutoSyncSettings.minimumIntervalMinutes,
        maximum: RepositoryAutoSyncSettings.maximumIntervalMinutes
      ),
      fetchBeforeScan: fetchBeforeScan ?? settings.fetchBeforeScan,
      autoImportRemoteArticles: autoImportRemoteArticles ?? settings.autoImportRemoteArticles
    )
  }

  private static func normalizedInterval(_ value: Int, minimum: Int, maximum: Int) -> Int {
    min(maximum, max(minimum, value))
  }
}
