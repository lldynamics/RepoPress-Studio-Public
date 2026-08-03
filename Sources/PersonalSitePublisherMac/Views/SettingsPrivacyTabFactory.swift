import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsPrivacyTabFactory {
  static func make(context: SettingsContext) -> some View {
    PrivacySettingsView(
      privacySettings: context.store.privacySettings,
      status: context.store.privacyProtectionStatus,
      onQuickHide: {
        context.actions.quickHideFromSettings()
      },
      onReturnToWorkbench: {
        context.actions.exitQuickHideFromSettings()
      },
      updatePrivacySettings: { settings in
        context.actions.updatePrivacySettings(settings)
      }
    )
  }
}
