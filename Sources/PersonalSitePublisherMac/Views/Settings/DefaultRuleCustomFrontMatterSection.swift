import SwiftUI

struct DefaultRuleCustomFrontMatterSection: View {
  @AppStorage("customFrontMatterPreset") private var customFrontMatterPreset = """
  featured_image: ""
  toc: true
  math: true
  """

  var body: some View {
    // The parent owns the Section and DisclosureGroup so Form sections never nest.
    VStack(alignment: .leading, spacing: 8) {
      Text("在此配置新建文章时需自动带出的自定义 YAML 属性（例如 Hexo / Hugo 主题拓展字段）：")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)

      TextEditor(text: $customFrontMatterPreset)
        .font(.workbenchMetadata.monospaced())
        .frame(minHeight: 90)
        .accessibilityLabel("自定义 Front-matter 预设字段")
        .overlay(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )

      HStack {
        Button("常用推荐模版") {
          customFrontMatterPreset = """
          featured_image: ""
          toc: true
          math: true
          draft: false
          """
        }
        .buttonStyle(.borderless)
        .font(.workbenchMetadata)

        Spacer()

        Button("清空预设") {
          customFrontMatterPreset = ""
        }
        .buttonStyle(.borderless)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
      }
    }
    .padding(.vertical, WorkbenchSpacing.tight)
  }
}
