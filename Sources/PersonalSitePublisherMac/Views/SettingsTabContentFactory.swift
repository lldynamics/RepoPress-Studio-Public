import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsTabContentFactory {
  @ViewBuilder
  static func makeContent(for tab: SettingsTab, context: SettingsContext) -> some View {
    switch tab {
    case .defaultRules:
      SettingsDefaultRulesTabFactory.make(context: context)
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
