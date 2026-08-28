import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsConfigurationStatusView: View {
  let context: SettingsContext
  @Environment(\.settingsSubsection) private var settingsSubsection

  var body: some View {
    Form {
      if activeSubsection == .configurationReadiness {
        SettingsConfigurationHealthCard(
          profile: context.store.activeProfile,
          aiProviderConfig: context.store.aiProviderConfig(for: context.store.activeProfile),
          repositoryTokenAvailability: context.store.repositoryTokenAvailability,
          aiTokenAvailability: context.store.ai.tokenAvailability,
          selectDestination: context.selectConfigurationHealthDestination,
          isEmbedded: true
        )
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.automatic)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("configuration-status-settings")
  }

  private var activeSubsection: SettingsSubsection {
    settingsSubsection.tab == .configurationStatus
      ? settingsSubsection
      : .configurationReadiness
  }
}
