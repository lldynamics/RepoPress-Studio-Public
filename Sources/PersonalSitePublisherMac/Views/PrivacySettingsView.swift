import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsView: View {
  let privacySettings: PrivacyProtectionSettings
  let status: PrivacyProtectionStatus
  let onQuickHide: () -> Void
  let onReturnToWorkbench: () -> Void
  let updatePrivacySettings: (PrivacyProtectionSettings) -> Void

  var body: some View {
    Form {
      Section {
        HStack(spacing: 10) {
          ZStack {
            Circle()
              .fill(Color.accentColor.opacity(0.14))
              .frame(width: 32, height: 32)
            Image(systemName: "keyboard")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(Color.accentColor)
          }

          VStack(alignment: .leading, spacing: 2) {
            Text("快速隐藏 / 防偷窥保护")
              .font(.subheadline.weight(.semibold))
            Text("在软件任何界面按 ⌃⌘L 即可快速隐藏工作台。此功能仅遮挡界面，不加密本地数据。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }

      PrivacySettingsVisibilitySection(
        masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent)
      )

      PrivacySettingsCurrentStatusSection(
        status: status,
        onQuickHide: {
          onQuickHide()
        },
        onReturnToWorkbench: {
          onReturnToWorkbench()
        }
      )

      Section("隐私与支持") {
        if let privacyPolicyURL = Self.privacyPolicyURL {
          Link(destination: privacyPolicyURL) {
            Label("隐私政策", systemImage: "hand.raised")
          }
          .help("在浏览器中打开隐私政策")
        }

        if let supportURL = Self.supportURL {
          Link(destination: supportURL) {
            Label("技术支持", systemImage: "questionmark.circle")
          }
          .help("在浏览器中打开技术支持页面")
        }
      }

    }
    .formStyle(.grouped)
    .padding()
  }

  private static var privacyPolicyURL: URL? {
    let path = usesChineseSupportPages
      ? "https://apps.chengjinfang.com/personal-site-publisher/privacy/"
      : "https://apps.chengjinfang.com/personal-site-publisher/privacy/en/"
    return URL(string: path)
  }

  private static var supportURL: URL? {
    let path = usesChineseSupportPages
      ? "https://apps.chengjinfang.com/personal-site-publisher/"
      : "https://apps.chengjinfang.com/personal-site-publisher/en/"
    return URL(string: path)
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
