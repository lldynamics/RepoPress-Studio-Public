import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsView: View {
  let privacySettings: PrivacyProtectionSettings
  let status: PrivacyProtectionStatus
  let onLock: () -> Void
  let onUnlock: () -> Void
  let updatePrivacySettings: (PrivacyProtectionSettings) -> Void

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

      PrivacySettingsVisibilitySection(
        masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent)
      )
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
