import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryAutomationSection: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    Section("当前工作区自动化") {
      Toggle("启用当前工作区自动检查远端", isOn: repositoryAutoSyncEnabledBinding)
        .toggleStyle(.switch)
        .accessibilityLabel("启用当前工作区自动检查远端")
        .accessibilityValue(
          store.repositoryAutoSyncSettings.isEnabled ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-enabled")

      Picker("当前工作区检查间隔", selection: repositoryAutoSyncIntervalBinding) {
        ForEach(TokenRepositoryAutomationSettingsSupport.intervalOptions, id: \.self) { minutes in
          Text("\(minutes) 分钟").tag(minutes)
        }
      }
      .pickerStyle(.menu)
      .disabled(!store.repositoryAutoSyncSettings.isEnabled)
      .accessibilityLabel("当前工作区远端自动检查间隔")
      .accessibilityValue("\(store.repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟")
      .accessibilityIdentifier("token-repository-auto-sync-interval")

      Toggle("检查前 fetch upstream", isOn: repositoryAutoSyncFetchBeforeScanBinding)
        .toggleStyle(.checkbox)
        .disabled(!store.repositoryAutoSyncSettings.isEnabled)
        .accessibilityLabel("当前工作区检查前 fetch upstream")
        .accessibilityValue(
          store.repositoryAutoSyncSettings.fetchBeforeScan ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-fetch-upstream")

      Toggle("自动导入远端文章", isOn: repositoryAutoImportRemoteArticlesBinding)
        .toggleStyle(.checkbox)
        .disabled(!store.repositoryAutoSyncSettings.isEnabled)
        .accessibilityLabel("当前工作区自动导入远端文章")
        .accessibilityValue(
          store.repositoryAutoSyncSettings.autoImportRemoteArticles ? "开启" : "关闭"
        )
        .accessibilityIdentifier("token-repository-auto-sync-auto-import")

      Text("这些选项只作用于当前工作区；修改设置不会立即执行 Fetch、远端检查或文章导入。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("token-repository-automation")
  }

  private var repositoryAutoSyncEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.isEnabled },
      set: { isEnabled in
        store.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            store.repositoryAutoSyncSettings,
            isEnabled: isEnabled
          )
        )
      }
    )
  }

  private var repositoryAutoSyncIntervalBinding: Binding<Int> {
    Binding(
      get: { store.repositoryAutoSyncSettings.normalizedIntervalMinutes },
      set: { intervalMinutes in
        store.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            store.repositoryAutoSyncSettings,
            intervalMinutes: intervalMinutes
          )
        )
      }
    )
  }

  private var repositoryAutoSyncFetchBeforeScanBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.fetchBeforeScan },
      set: { fetchBeforeScan in
        store.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            store.repositoryAutoSyncSettings,
            fetchBeforeScan: fetchBeforeScan
          )
        )
      }
    )
  }

  private var repositoryAutoImportRemoteArticlesBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.autoImportRemoteArticles },
      set: { autoImportRemoteArticles in
        store.updateRepositoryAutoSyncSettings(
          TokenRepositoryAutomationSettingsSupport.updated(
            store.repositoryAutoSyncSettings,
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
