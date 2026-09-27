import SwiftUI

extension MacMarkdownComposerView {
  var isArticleInformationFolded: Bool {
    !isArticleInformationExpanded && frontMatterIssue == nil
  }

  /// Shown beside the file path in the title row instead of as a separate
  /// strip above the editor. Front Matter has one explicit disclosure control.
  var articleInformationToggle: MacMarkdownArticleInformationToggle? {
    return MacMarkdownArticleInformationToggle(
      isExpanded: Binding(
        get: { !isArticleInformationFolded },
        set: { isArticleInformationExpanded = $0 }
      ),
      isEnabled: frontMatterIssue == nil
    )
  }
}

struct MacMarkdownArticleInformationToggle: View {
  @Binding var isExpanded: Bool
  let isEnabled: Bool

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Label("文章信息", systemImage: isExpanded ? "chevron.down" : "chevron.right")
        .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.plain)
    .font(.caption)
    .foregroundStyle(.secondary)
    .disabled(!isEnabled)
    .help(
      isExpanded
        ? String(localized: "编辑文章标题、日期、标签和其他字段。")
        : String(localized: "标题、日期、标签等信息已收起，展开可编辑源码。")
    )
    .accessibilityValue(isExpanded ? String(localized: "已展开") : String(localized: "已收起"))
    .accessibilityIdentifier("markdown-article-information-toggle")
  }
}
