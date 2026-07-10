import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsPrivacyTabFactory {
  static func make(context: SettingsContext) -> some View {
    PrivacySettingsView(
      privacySettings: context.store.privacySettings,
      status: context.store.privacyProtectionStatus,
      audit: context.store.privacyProtectionAudit,
      events: context.store.privacyProtectionEvents,
      onLock: {
        context.actions.lockPrivacyFromSettings()
      },
      onUnlock: {
        context.actions.unlockPrivacyFromSettings()
      },
      updatePrivacySettings: { settings in
        context.actions.updatePrivacySettings(settings)
      },
      onCopyChecklist: {
        context.actions.copyPrivacyChecklist()
      },
      onCopyAuditReport: {
        context.actions.copyPrivacyAuditReport()
      },
      onCopyEvidence: {
        context.actions.copyPrivacyEvidencePackage()
      }
    )
  }
}
