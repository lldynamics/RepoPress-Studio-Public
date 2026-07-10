import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSiteSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>

  var body: some View {
    Section("站点规则") {
      Picker("站点类型", selection: siteKindBinding) {
        ForEach(SiteKind.allCases) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .accessibilityLabel("站点类型")
      .accessibilityValue(activeProfile.siteKind.displayName)

      Picker("Front Matter", selection: activeProfileBinding.frontMatterStyle) {
        ForEach(FrontMatterStyle.allCases) { style in
          Text(style.displayName).tag(style)
        }
      }
      .accessibilityLabel("Front Matter 格式")
      .accessibilityValue(activeProfile.frontMatterStyle.displayName)

      TextField("默认作者", text: activeProfileBinding.defaultAuthor)
        .accessibilityLabel("默认作者")
        .accessibilityValue(activeProfile.defaultAuthor.isEmpty ? "未填写" : activeProfile.defaultAuthor)

      TextField("默认标签", text: stringListBinding(\.defaultTags))
        .accessibilityLabel("默认标签")
        .accessibilityValue(activeProfile.defaultTags.isEmpty ? "未填写" : activeProfile.defaultTags.joined(separator: "，"))

      TextField("默认分类", text: stringListBinding(\.defaultCategories))
        .accessibilityLabel("默认分类")
        .accessibilityValue(activeProfile.defaultCategories.isEmpty ? "未填写" : activeProfile.defaultCategories.joined(separator: "，"))

      TextField("日期格式", text: activeProfileBinding.dateFormat)
        .accessibilityLabel("日期格式")
        .accessibilityValue(activeProfile.dateFormat.isEmpty ? "未填写" : activeProfile.dateFormat)

      Picker("Slug 规则", selection: activeProfileBinding.slugValidationRule) {
        ForEach(SiteSlugValidationRule.allCases) { rule in
          Text(rule.displayName).tag(rule)
        }
      }
      .accessibilityLabel("Slug 规则")
      .accessibilityValue(activeProfile.slugValidationRule.displayName)

      Text(activeProfile.slugValidationRule.detail)
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Front Matter 包含 draft 字段", isOn: activeProfileBinding.includeDraftFlagInFrontMatter)
        .accessibilityLabel("Front Matter 包含 draft 字段")
        .accessibilityValue(activeProfile.includeDraftFlagInFrontMatter ? "开启" : "关闭")

      Toggle("Front Matter 包含封面图字段", isOn: activeProfileBinding.includeCoverInFrontMatter)
        .accessibilityLabel("Front Matter 包含封面图字段")
        .accessibilityValue(activeProfile.includeCoverInFrontMatter ? "开启" : "关闭")
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private func stringListBinding(_ keyPath: WritableKeyPath<SiteProfile, [String]>) -> Binding<String> {
    Binding(
      get: { activeProfileBinding.wrappedValue[keyPath: keyPath].joined(separator: ", ") },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        profile[keyPath: keyPath] = value
          .split { $0 == "," || $0 == "，" }
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        activeProfileBinding.wrappedValue = profile
      }
    )
  }
}
