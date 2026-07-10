import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsDefaultRulesTabFactory {
  static func make(context: SettingsContext) -> some View {
    DefaultRuleSettingsView(
      defaultShowsInspector: context.defaultShowsInspector,
      autoRunPreflightBinding: context.autoRunPreflightBinding,
      scanRepositoryOnLaunch: context.scanRepositoryOnLaunch,
      activeProfileBinding: context.activeProfileBinding,
      siteKindBinding: context.siteKindBinding
    )
  }
}
