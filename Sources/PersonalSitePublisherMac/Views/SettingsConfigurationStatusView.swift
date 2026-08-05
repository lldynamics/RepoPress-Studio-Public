import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsConfigurationStatusView: View {
  let context: SettingsContext
  @Environment(\.openSettings) private var openSettings
  @AppStorage("settingsRequestedTabID") private var requestedSettingsTabID = ""

  var body: some View {
    Form {
      SettingsConfigurationHealthCard(
        profile: context.store.activeProfile,
        aiProviderConfig: context.store.aiProviderConfig(for: context.store.activeProfile),
        repositoryTokenAvailability: context.store.repositoryTokenAvailability,
        aiTokenAvailability: context.store.ai.tokenAvailability,
        privacySettings: context.store.privacySettings,
        selectDestination: context.selectConfigurationHealthDestination,
        isEmbedded: true
      )

      Section("数据管理") {
        Text("版本、回收站、备份、恢复和内容迁移已集中到一个入口。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("打开数据管理", systemImage: "externaldrive") {
          requestedSettingsTabID = SettingsTab.dataManagement.id
          openSettings()
        }
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .accessibilityIdentifier("configuration-status-settings")
  }
}
