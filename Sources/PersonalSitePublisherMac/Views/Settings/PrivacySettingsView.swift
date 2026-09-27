import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsView: View {
  let privacySettings: PrivacyProtectionSettings
  let status: PrivacyProtectionStatus
  let updatePrivacySettings: (PrivacyProtectionSettings) -> Void
  var body: some View {
    Form {
      PrivacySettingsVisibilitySection(
        masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent),
        subsectionAnchor: .privacyMasking
      )
      maskingPreviewSection
      currentStatusSection
      supportSection
    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("privacy-settings")
  }

  private var maskingPreviewSection: some View {
    Section("遮挡效果预览") {
      VStack(alignment: .leading, spacing: 6) {
        Text("私密文章或离席遮罩效果")
          .font(.caption)
          .foregroundStyle(.secondary)

        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchSpacing.card) {
            privacyPreviewCard(
              title: String(localized: "公开文本示例"),
              content: String(localized: "这是一段正常的文章正文。"),
              isMasked: false
            )
            privacyPreviewCard(
              title: String(localized: "私密掩码示例"),
              content: String(localized: "这是一段敏感私密内容。"),
              isMasked: true
            )
          }

          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            privacyPreviewCard(
              title: String(localized: "公开文本示例"),
              content: String(localized: "这是一段正常的文章正文。"),
              isMasked: false
            )
            privacyPreviewCard(
              title: String(localized: "私密掩码示例"),
              content: String(localized: "这是一段敏感私密内容。"),
              isMasked: true
            )
          }
        }
      }
    }
  }

  private var currentStatusSection: some View {
    PrivacySettingsCurrentStatusSection(
      status: status,
      subsectionAnchor: .privacyStatus
    )
  }

  private var supportSection: some View {
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

  private func privacyPreviewCard(
    title: String,
    content: String,
    isMasked: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
      Text(content)
        .font(.subheadline)
        .blur(radius: isMasked && privacySettings.masksPrivateContent ? 4 : 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(WorkbenchSpacing.control)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(
      isMasked && privacySettings.masksPrivateContent
        ? String(localized: "内容已遮挡")
        : content
    )
  }

  private static var privacyPolicyURL: URL? {
    let path =
      usesChineseSupportPages
      ? "https://apps.chengjinfang.com/personal-site-publisher/privacy/"
      : "https://apps.chengjinfang.com/personal-site-publisher/privacy/en/"
    return URL(string: path)
  }

  private static var supportURL: URL? {
    let path =
      usesChineseSupportPages
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
