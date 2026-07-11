import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsView: View {
  let privacySettings: PrivacyProtectionSettings
  let status: PrivacyProtectionStatus
  let audit: PrivacyProtectionAudit
  let events: [PrivacyProtectionEvent]
  let onLock: () -> Void
  let onUnlock: () -> Void
  let updatePrivacySettings: (PrivacyProtectionSettings) -> Void
  let onCopyChecklist: () -> Void
  let onCopyAuditReport: () -> Void
  let onCopyEvidence: () -> Void

  var body: some View {
    Form {
      PrivacySettingsCurrentStatusSection(
        status: status,
        onLock: {
          onLock()
        },
        onUnlock: {
          onUnlock()
        }
      )

      PrivacySettingsLockSection(
        requiresUnlockOnLaunch: privacySettingBinding(keyPath: \.requiresUnlockOnLaunch),
        locksWhenInactive: privacySettingBinding(keyPath: \.locksWhenInactive)
      )

      PrivacySettingsVisibilitySection(
        masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent)
      )

#if DEBUG
      PrivacyAdvancedDiagnosticsSection(
        audit: audit,
        events: events,
        onCopyChecklist: {
          onCopyChecklist()
        },
        onCopyAuditReport: {
          onCopyAuditReport()
        },
        onCopyEvidence: {
          onCopyEvidence()
        }
      )
#endif
    }
    .formStyle(.grouped)
    .padding()
  }

  private func privacySettingBinding(keyPath: WritableKeyPath<PrivacyProtectionSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { privacySettings[keyPath: keyPath] },
      set: { value in
        var settings = privacySettings
        settings[keyPath: keyPath] = value
        updatePrivacySettings(settings)
      }
    )
  }
}
