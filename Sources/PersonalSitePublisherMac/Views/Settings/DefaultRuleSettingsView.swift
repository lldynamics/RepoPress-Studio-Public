import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleExpansionState: Equatable {
  var advancedFrontMatter = false
  var frontMatterPreview = false
  var pathRules = false

  mutating func revealPathRules(
    for navigationDestination: SettingsDestination?,
    legacyHealthDestination: SettingsConfigurationHealthDestination?
  ) {
    guard
      Self.shouldRevealPathRules(
        for: navigationDestination,
        legacyHealthDestination: legacyHealthDestination
      )
    else { return }
    pathRules = true
  }

  static func shouldRevealPathRules(
    for navigationDestination: SettingsDestination?,
    legacyHealthDestination: SettingsConfigurationHealthDestination?
  ) -> Bool {
    navigationDestination == .rules(.paths) || legacyHealthDestination == .defaultRules
  }
}

struct DefaultRuleSettingsView: View {
  let store: WorkbenchStore
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  var body: some View {
    Form {
      SettingsSubsectionAnchor(subsection: .rulesBasics)
      DefaultRuleBasicsFocusedSection(
        activeProfileBinding: activeProfileBinding,
        siteKindBinding: siteKindBinding
      )
      SettingsSubsectionAnchor(subsection: .rulesDiscovery)
      RepositoryDraftDiscoverySettingsSection(
        store: store,
        activeProfileBinding: activeProfileBinding
      )
      SettingsSubsectionAnchor(subsection: .rulesFrontMatter)
      DefaultRuleFrontMatterFocusedSection(activeProfileBinding: activeProfileBinding)
      SettingsSubsectionAnchor(subsection: .rulesPaths)
      Section("文件路径与模板") {
        DefaultRulePathSection(
          activeProfileBinding: activeProfileBinding,
          shouldFocusPaths: shouldFocusPathRules,
          navigationRequestID: pathNavigationRequestID
        )

        Text("仅在站点目录结构不同时调整；默认值适用于当前站点类型。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("default-rule-path-rules")
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("default-rule-settings")
  }

  private var shouldFocusPathRules: Bool {
    DefaultRuleExpansionState.shouldRevealPathRules(
      for: navigationDestination,
      legacyHealthDestination: healthDestination
    )
  }

  private var pathNavigationRequestID: UUID {
    healthDestination == .defaultRules ? healthNavigationRequestID : navigationRequestID
  }

}

private struct DefaultRuleBasicsFocusedSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>

  var body: some View {
    Section("常用默认") {
      Picker("站点类型", selection: siteKindBinding) {
        ForEach(SiteKind.allCases) { kind in
          Text(kind.localizedDisplayName).tag(kind)
        }
      }
      .accessibilityLabel("站点类型")
      .accessibilityValue(activeProfile.siteKind.localizedDisplayName)

      HStack(spacing: 8) {
        Text("快捷套用框架规范：")
          .font(.caption)
          .foregroundStyle(.secondary)

        Button("Hexo 规范") {
          activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
          activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd HH:mm:ss"
          activeProfileBinding.slugValidationRule.wrappedValue = .lowercaseKebab
          activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = false
        }

        Button("Hugo 规范") {
          activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
          activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd'T'HH:mm:ssXXX"
          activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = true
        }
      }
      .buttonStyle(.borderless)
      .accessibilityElement(children: .contain)

      TextField("默认作者", text: activeProfileBinding.defaultAuthor)
        .accessibilityLabel("默认作者")
        .accessibilityValue(
          activeProfile.defaultAuthor.isEmpty ? "未填写" : activeProfile.defaultAuthor)

      TextField("默认标签", text: stringListBinding(\.defaultTags))
        .accessibilityLabel("默认标签")
        .accessibilityValue(
          activeProfile.defaultTags.isEmpty
            ? "未填写" : activeProfile.defaultTags.joined(separator: "，"))

      TextField("默认分类", text: stringListBinding(\.defaultCategories))
        .accessibilityLabel("默认分类")
        .accessibilityValue(
          activeProfile.defaultCategories.isEmpty
            ? "未填写" : activeProfile.defaultCategories.joined(separator: "，"))
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private func stringListBinding(_ keyPath: WritableKeyPath<SiteProfile, [String]>) -> Binding<
    String
  > {
    Binding(
      get: { activeProfileBinding.wrappedValue[keyPath: keyPath].joined(separator: ", ") },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        profile[keyPath: keyPath] =
          value
          .split { $0 == "," || $0 == "，" }
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        activeProfileBinding.wrappedValue = profile
      }
    )
  }
}

private struct DefaultRuleFrontMatterFocusedSection: View {
  let activeProfileBinding: Binding<SiteProfile>

  var body: some View {
    Section("文章头信息") {
      Picker("文章头信息格式", selection: activeProfileBinding.frontMatterStyle) {
        ForEach(FrontMatterStyle.allCases) { style in
          Text(style.localizedDisplayName).tag(style)
        }
      }
      .accessibilityLabel("文章头信息格式")
      .accessibilityValue(activeProfile.frontMatterStyle.localizedDisplayName)

      TextField("日期格式", text: activeProfileBinding.dateFormat)
        .accessibilityLabel("日期格式")
        .accessibilityValue(activeProfile.dateFormat.isEmpty ? "未填写" : activeProfile.dateFormat)

      Picker("Slug 规则", selection: activeProfileBinding.slugValidationRule) {
        ForEach(SiteSlugValidationRule.allCases) { rule in
          Text(rule.localizedDisplayName).tag(rule)
        }
      }
      .accessibilityLabel("Slug 规则")
      .accessibilityValue(activeProfile.slugValidationRule.localizedDisplayName)

      Toggle("包含 draft 字段", isOn: activeProfileBinding.includeDraftFlagInFrontMatter)
        .accessibilityLabel("文章头信息包含 draft 字段")
        .accessibilityValue(activeProfile.includeDraftFlagInFrontMatter ? "开启" : "关闭")

      Toggle("包含封面图字段", isOn: activeProfileBinding.includeCoverInFrontMatter)
        .accessibilityLabel("文章头信息包含封面图字段")
        .accessibilityValue(activeProfile.includeCoverInFrontMatter ? "开启" : "关闭")
    }
    .accessibilityIdentifier("default-rule-advanced-front-matter")

    Section("Front Matter 预览") {
      VStack(alignment: .leading, spacing: 10) {
        Text(generatedFrontMatterPreview)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 4) {
          Text("模拟发布路径与 URL")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

          Text("文件: \(simulatedFilePath)")
            .font(.caption.monospaced())
          Text("URL: \(simulatedURLPath)")
            .font(.caption.monospaced())
            .foregroundStyle(WorkbenchTheme.brand)
        }
      }
      .accessibilityIdentifier("default-rule-front-matter-preview")
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var frontMatterPreview: DefaultRuleFrontMatterPreview {
    DefaultRuleFrontMatterPreview.make(profile: activeProfile)
  }

  private var generatedFrontMatterPreview: String {
    frontMatterPreview.frontMatter
  }

  private var simulatedFilePath: String {
    frontMatterPreview.markdownPath
  }

  private var simulatedURLPath: String {
    frontMatterPreview.url
  }
}
