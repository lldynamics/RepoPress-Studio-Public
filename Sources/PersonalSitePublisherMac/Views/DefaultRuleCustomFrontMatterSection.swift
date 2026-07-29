import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleCustomFrontMatterSection: View {
  @AppStorage("customFrontMatterPreset") private var customFrontMatterPreset = """
  featured_image: ""
  toc: true
  math: true
  """

  var body: some View {
    Section("自定义 Front-matter 预设字段") {
      VStack(alignment: .leading, spacing: 8) {
        Text("在此配置新建文章时需自动带出的自定义 YAML 属性（例如 Hexo / Hugo 主题拓展字段）：")
          .font(.caption)
          .foregroundStyle(.secondary)

        TextEditor(text: $customFrontMatterPreset)
          .font(.caption.monospaced())
          .frame(minHeight: 90)
          .accessibilityLabel("自定义 Front-matter 预设字段")
          .overlay(
            RoundedRectangle(cornerRadius: 6)
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
          .font(.caption)

          Spacer()

          Button("清空预设") {
            customFrontMatterPreset = ""
          }
          .buttonStyle(.borderless)
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }
}
