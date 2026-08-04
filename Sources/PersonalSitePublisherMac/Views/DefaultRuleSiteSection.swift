import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSiteSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>

  var body: some View {
    Group {
      Section("站点与文章默认") {
        Picker("站点类型", selection: siteKindBinding) {
          ForEach(SiteKind.allCases) { kind in
            Text(kind.localizedDisplayName).tag(kind)
          }
        }
        .accessibilityLabel("站点类型")
        .accessibilityValue(activeProfile.siteKind.localizedDisplayName)

        HStack {
          Text("快捷套用框架规范：")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button("Hexo 规范") {
            activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
            activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd HH:mm:ss"
            activeProfileBinding.slugValidationRule.wrappedValue = .lowercaseKebab
            activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = false
          }
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))

          Button("Hugo 规范") {
            activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
            activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd'T'HH:mm:ssXXX"
            activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = true
          }
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
        }
        .padding(.vertical, 2)

        Picker("文章头信息格式", selection: activeProfileBinding.frontMatterStyle) {
          ForEach(FrontMatterStyle.allCases) { style in
            Text(style.localizedDisplayName).tag(style)
          }
        }
        .accessibilityLabel("文章头信息格式")
        .accessibilityValue(activeProfile.frontMatterStyle.localizedDisplayName)

        TextField("默认作者", text: activeProfileBinding.defaultAuthor)
          .accessibilityLabel("默认作者")
          .accessibilityValue(activeProfile.defaultAuthor.isEmpty ? "未填写" : activeProfile.defaultAuthor)

        TextField("默认标签", text: stringListBinding(\.defaultTags))
          .accessibilityLabel("默认标签")
          .accessibilityValue(activeProfile.defaultTags.isEmpty ? "未填写" : activeProfile.defaultTags.joined(separator: "，"))

        TextField("默认分类", text: stringListBinding(\.defaultCategories))
          .accessibilityLabel("默认分类")
          .accessibilityValue(activeProfile.defaultCategories.isEmpty ? "未填写" : activeProfile.defaultCategories.joined(separator: "，"))
      }

      Section("文件名与头信息字段") {
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

      DefaultRuleCustomFrontMatterSection()
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
