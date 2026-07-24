import AppKit
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
      if DistributionFeaturePolicy.allowsExternalAIProviders {
        SettingsAITabFactory.make(context: context)
      } else {
        EmptyStateView(
          title: "AI 服务当前不可用",
          message: "请重新打开设置；如果问题仍然存在，请检查应用版本和服务配置。",
          systemImage: "checkmark.shield"
        )
      }
    case .knowledge:
      KnowledgeSettingsView(
        knowledge: context.store.knowledge,
        browserBridge: context.browserBridge,
        onOpenLibrary: {
          context.store.selectSection(.library)
          NSApp.activate(ignoringOtherApps: true)
          NSApp.windows.first(where: { $0.canBecomeMain && $0.title != String(localized: "设置") })?
            .makeKeyAndOrderFront(nil)
        }
      )
    case .privacy:
      SettingsPrivacyTabFactory.make(context: context)
    case .pro:
      SettingsProTabFactory.make(context: context)
    }
  }
}
