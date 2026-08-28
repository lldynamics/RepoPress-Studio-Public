import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsView: View {
  let privacySettings: PrivacyProtectionSettings
  let status: PrivacyProtectionStatus
  let onQuickHide: () -> Void
  let updatePrivacySettings: (PrivacyProtectionSettings) -> Void
  @Environment(\.settingsSubsection) private var settingsSubsection

  var body: some View {
    Form {
      switch displayedSubsection {
      case .privacyQuickHide:
        quickHideSection
        currentStatusSection
      case .privacyMasking:
        PrivacySettingsVisibilitySection(
          masksPrivateContent: privacySettingBinding(keyPath: \.masksPrivateContent)
        )
        maskingPreviewSection
      case .privacyStatus:
        currentStatusSection
        supportSection
      default:
        EmptyView()
      }

    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("privacy-settings")
  }

  private var displayedSubsection: SettingsSubsection {
    settingsSubsection.tab == .privacy ? settingsSubsection : .privacyQuickHide
  }

  private var quickHideSection: some View {
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
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            Text("快速隐藏 / 临时遮挡")
              .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 2) {
              Text("⌃").font(.caption.monospaced().weight(.semibold)).padding(.horizontal, 4)
                .padding(.vertical, 1).background(
                  Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
              Text("⌘").font(.caption.monospaced().weight(.semibold)).padding(.horizontal, 4)
                .padding(.vertical, 1).background(
                  Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
              Text("L").font(.caption.monospaced().weight(.semibold)).padding(.horizontal, 4)
                .padding(.vertical, 1).background(
                  Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("快捷键 Control Command L")
          }
          Text("在软件任何界面按下全局快捷键即可快速遮挡或隐藏工作台。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
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
    PrivacySettingsCurrentStatusSection(status: status, onQuickHide: onQuickHide)
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
