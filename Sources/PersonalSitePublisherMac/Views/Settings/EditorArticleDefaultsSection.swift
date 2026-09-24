import SwiftUI

struct EditorArticleDefaultsSection: View {
  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Text("此预设适用于所有站点的新文章；站点专属的作者、标签、分类和路径仍在“内容与路径”中设置。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        DefaultRuleCustomFrontMatterSection()
          .padding(.top, 4)
      }
      .accessibilityIdentifier("settings-global-front-matter-preset")
    } header: {
      Text("新建文章默认")
        .settingsSubsectionAnchor(.appearanceDefaults)
    }
  }
}
