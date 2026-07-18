import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsTabContentFactory {
  @ViewBuilder
  static func makeContent(for tab: SettingsTab, context: SettingsContext) -> some View {
    switch tab {
    case .configurationStatus:
      SettingsConfigurationHealthCard(
        profile: context.store.activeProfile,
        repositoryTokenAvailability: context.store.repositoryTokenAvailability,
        aiTokenAvailability: context.store.ai.tokenAvailability,
        privacySettings: context.store.privacySettings,
        isProUnlocked: context.store.monetizationState.entitlement.isUnlocked,
        proSource: context.store.monetizationState.entitlement.source.localizedDisplayName,
        selectDestination: context.selectConfigurationHealthDestination
      )
    case .defaultRules:
      DefaultRuleSettingsView(
        autoRunPreflightBinding: context.autoRunPreflightBinding,
        scanRepositoryOnLaunch: context.scanRepositoryOnLaunch,
        activeProfileBinding: context.activeProfileBinding,
        siteKindBinding: context.siteKindBinding,
        healthDestination: context.healthDestination,
        healthNavigationRequestID: context.healthNavigationRequestID
      )
    case .token:
      SettingsTokenTabFactory.make(context: context)
    case .ai:
      SettingsAITabFactory.make(context: context)
    case .privacy:
      SettingsPrivacyTabFactory.make(context: context)
    case .pro:
      SettingsProTabFactory.make(context: context)
    }
  }
}
