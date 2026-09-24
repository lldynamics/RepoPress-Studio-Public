import SwiftUI

@MainActor
struct SettingsConfigurationStatusView: View {
  let context: SettingsContext
  var body: some View {
    Form {
      SettingsTaskShortcutsView(selectDestination: context.selectSettingsDestination)
        .settingsSubsectionAnchor(.configurationTasks)

      SettingsConfigurationHealthCard(
        profile: context.store.activeProfile,
        aiProviderConfig: context.store.aiProviderConfig(for: context.store.activeProfile),
        repositoryTokenAvailability: context.store.repositoryTokenAvailability,
        aiTokenAvailability: context.store.ai.tokenAvailability,
        selectDestination: context.selectConfigurationHealthDestination,
        isEmbedded: true
      )
      .settingsSubsectionAnchor(.configurationReadiness)
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("configuration-status-settings")
  }

}
