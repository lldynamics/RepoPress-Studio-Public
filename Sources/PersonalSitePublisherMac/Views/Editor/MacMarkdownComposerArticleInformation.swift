import SwiftUI

extension MacMarkdownComposerView {
  var articleInformationDisclosure: some View {
    HStack(spacing: 8) {
      Button {
        isArticleInformationExpanded.toggle()
      } label: {
        Label("文章信息", systemImage: isArticleInformationExpanded ? "chevron.down" : "chevron.right")
      }
      .buttonStyle(.plain)
      .disabled(writingToolDensity != .basic || frontMatterIssue != nil)
      .accessibilityValue(
        writingToolDensity != .basic || isArticleInformationExpanded || frontMatterIssue != nil
          ? String(localized: "已展开") : String(localized: "已收起")
      )
      .accessibilityIdentifier("markdown-article-information-toggle")
      Text(
        writingToolDensity == .basic && !isArticleInformationExpanded && frontMatterIssue == nil
          ? String(localized: "标题、日期、标签等信息已收起，展开可编辑源码。")
          : String(localized: "编辑文章标题、日期、标签和其他字段。")
      )
      .foregroundStyle(.secondary)
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(.caption)
    .padding(.horizontal, 16)
    .padding(.vertical, 7)
    .accessibilityElement(children: .contain)
  }
}
