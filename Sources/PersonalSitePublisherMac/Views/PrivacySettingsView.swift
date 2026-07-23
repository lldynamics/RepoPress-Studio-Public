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
      PrivacySettingsVisibilitySection(
        masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent)
      )

      PrivacySettingsCurrentStatusSection(
        status: status,
        onLock: {
          onLock()
        },
        onUnlock: {
          onUnlock()
        }
      )

      Section("隐私与支持") {
        Link(destination: Self.privacyPolicyURL) {
          Label("隐私政策", systemImage: "hand.raised")
        }
        .help("在浏览器中打开隐私政策")

        Link(destination: Self.supportURL) {
          Label("技术支持", systemImage: "questionmark.circle")
        }
        .help("在浏览器中打开技术支持页面")
      }

    }
    .formStyle(.grouped)
    .padding()
  }

  private static var privacyPolicyURL: URL {
    let path = usesChineseSupportPages
      ? "https://apps.chengjinfang.com/personal-site-publisher/privacy/"
      : "https://apps.chengjinfang.com/personal-site-publisher/privacy/en/"
    return URL(string: path)!
  }

  private static var supportURL: URL {
    let path = usesChineseSupportPages
      ? "https://apps.chengjinfang.com/personal-site-publisher/"
      : "https://apps.chengjinfang.com/personal-site-publisher/en/"
    return URL(string: path)!
  }

  private static var usesChineseSupportPages: Bool {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
  }

  private func privacySettingBinding<Value>(
    keyPath: WritableKeyPath<PrivacyProtectionSettings, Value>
  ) -> Binding<Value> {
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
