import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSiteSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>
  @Binding var expansionState: DefaultRuleExpansionState

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

        Button {
          activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
          activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd HH:mm:ss"
          activeProfileBinding.slugValidationRule.wrappedValue = .lowercaseKebab
          activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = false
        } label: {
          Text("Hexo 规范")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              activeProfile.dateFormat == "yyyy-MM-dd HH:mm:ss" ? WorkbenchTheme.brand.opacity(0.15) : Color.primary.opacity(0.06),
              in: Capsule()
            )
            .foregroundStyle(activeProfile.dateFormat == "yyyy-MM-dd HH:mm:ss" ? WorkbenchTheme.brand : Color.primary)
        }
        .buttonStyle(.plain)

        Button {
          activeProfileBinding.frontMatterStyle.wrappedValue = .yaml
          activeProfileBinding.dateFormat.wrappedValue = "yyyy-MM-dd'T'HH:mm:ssXXX"
          activeProfileBinding.includeDraftFlagInFrontMatter.wrappedValue = true
        } label: {
          Text("Hugo 规范")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              activeProfile.dateFormat.contains("XXX") ? WorkbenchTheme.brand.opacity(0.15) : Color.primary.opacity(0.06),
              in: Capsule()
            )
            .foregroundStyle(activeProfile.dateFormat.contains("XXX") ? WorkbenchTheme.brand : Color.primary)
        }
        .buttonStyle(.plain)
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

    Section("进阶配置") {
      DisclosureGroup(isExpanded: $expansionState.advancedFrontMatter) {
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
      } label: {
        disclosureLabel(
          title: String(localized: "文件名与头信息字段"),
          detail: String(localized: "日期格式、Slug 规则与可选字段"),
          systemImage: "doc.badge.gearshape"
        )
      }
      .accessibilityIdentifier("default-rule-advanced-front-matter")

      DisclosureGroup(isExpanded: $expansionState.frontMatterPreview) {
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            Text("模拟文章头信息")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)

            Text(generatedFrontMatterPreview)
              .font(.caption.monospaced())
              .foregroundStyle(.primary)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color(nsColor: .textBackgroundColor))
              .cornerRadius(6)
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
              )
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("模拟发布路径与 URL")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text("文件:")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(simulatedFilePath)
                  .font(.caption.monospaced())
                  .foregroundStyle(.primary)
              }
              HStack(spacing: 6) {
                Text("URL:")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(simulatedURLPath)
                  .font(.caption.monospaced())
                  .foregroundStyle(.blue)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
          }
        }
        .padding(.top, 6)
      } label: {
        disclosureLabel(
          title: String(localized: "Front Matter 预览"),
          detail: String(localized: "检查当前默认值生成的文章头信息"),
          systemImage: "doc.text.magnifyingglass"
        )
      }
      .accessibilityIdentifier("default-rule-front-matter-preview")
    }
  }

  private var simulatedFilePath: String {
    let slug = "example-article"
    let pattern = activeProfile.markdownPathPattern.isEmpty ? "content/posts/{slug}.md" : activeProfile.markdownPathPattern
    return pattern
      .replacingOccurrences(of: "{slug}", with: slug)
      .replacingOccurrences(of: "{year}", with: "2026")
      .replacingOccurrences(of: "{month}", with: "08")
      .replacingOccurrences(of: "{day}", with: "06")
  }

  private var simulatedURLPath: String {
    let siteURL = activeProfile.deploymentSiteURL?.trimmedForPublishing
    let base = (siteURL?.isEmpty ?? true) ? "https://example.com" : siteURL!
    let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "\(trimmed)/posts/2026/08/example-article/"
  }

  private var generatedFrontMatterPreview: String {
    let style = activeProfile.frontMatterStyle
    let delimiter = style == .yaml ? "---" : "+++"
    var lines: [String] = [delimiter]
    lines.append("title: 示例文章标题")
    lines.append("date: 2026-08-06 10:00:00")
    if !activeProfile.defaultAuthor.isEmpty {
      lines.append("author: \(activeProfile.defaultAuthor)")
    }
    if !activeProfile.defaultTags.isEmpty {
      lines.append("tags: [\(activeProfile.defaultTags.joined(separator: ", "))]")
    }
    if !activeProfile.defaultCategories.isEmpty {
      lines.append("categories: [\(activeProfile.defaultCategories.joined(separator: ", "))]")
    }
    if activeProfile.includeDraftFlagInFrontMatter {
      lines.append("draft: true")
    }
    if activeProfile.includeCoverInFrontMatter {
      lines.append("cover: /images/example-cover.png")
    }
    lines.append(delimiter)
    return lines.joined(separator: "\n")
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private func disclosureLabel(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
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
