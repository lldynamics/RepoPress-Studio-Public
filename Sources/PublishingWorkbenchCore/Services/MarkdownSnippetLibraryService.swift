import Foundation

public enum MarkdownSnippetKind: String, CaseIterable, Codable, Hashable, Sendable {
  case articleTemplate
  case snippet
}

public struct MarkdownSnippet: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var detail: String
  public var systemImage: String
  public var kind: MarkdownSnippetKind
  public var markdown: String
  public var siteProfileID: UUID?

  public init(
    id: String,
    title: String,
    detail: String,
    systemImage: String,
    kind: MarkdownSnippetKind,
    markdown: String,
    siteProfileID: UUID? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.kind = kind
    self.markdown = markdown
    self.siteProfileID = siteProfileID
  }

  public var isSiteScoped: Bool {
    siteProfileID != nil
  }
}

public enum MarkdownSnippetLibraryService {
  public static let maximumCustomSnippetCount = 100

  public static let builtIns: [MarkdownSnippet] = [
    MarkdownSnippet(
      id: "template-guide",
      title: "教程文章",
      detail: "背景、步骤、验证和常见问题",
      systemImage: "list.number",
      kind: .articleTemplate,
      markdown: """
      # {{title}}

      ## 背景

      简要说明问题与适用场景。

      ## 操作步骤

      1. 第一步
      2. 第二步
      3. 第三步

      ## 验证结果

      说明如何确认操作成功。

      ## 常见问题

      ### 问题一

      补充答案。
      """
    ),
    MarkdownSnippet(
      id: "template-review",
      title: "评测文章",
      detail: "结论、优缺点、适用人群与建议",
      systemImage: "star.bubble",
      kind: .articleTemplate,
      markdown: """
      # {{title}}

      ## 结论先行

      写下最重要的判断。

      ## 优点

      - （待补充）

      ## 局限

      - （待补充）

      ## 适合谁

      ## 最终建议
      """
    ),
    MarkdownSnippet(
      id: "snippet-callout",
      title: "提示卡片",
      detail: "插入醒目的提示引用",
      systemImage: "lightbulb",
      kind: .snippet,
      markdown: "> **提示**：在这里补充需要读者注意的内容。"
    ),
    MarkdownSnippet(
      id: "snippet-details",
      title: "折叠详情",
      detail: "插入 details/summary 区块",
      systemImage: "chevron.down.square",
      kind: .snippet,
      markdown: """
      <details>
      <summary>查看详情</summary>

      在这里补充内容。

      </details>
      """
    ),
    MarkdownSnippet(
      id: "snippet-footnote",
      title: "脚注",
      detail: "插入脚注引用与定义",
      systemImage: "text.badge.plus",
      kind: .snippet,
      markdown: "这里需要补充说明[^note]。\n\n[^note]: 脚注内容。"
    ),
    MarkdownSnippet(
      id: "snippet-mermaid",
      title: "Mermaid 流程图",
      detail: "插入可在预览中渲染的流程图",
      systemImage: "point.3.connected.trianglepath.dotted",
      kind: .snippet,
      markdown: """
      ```mermaid
      flowchart TD
        A[开始] --> B[处理]
        B --> C[完成]
      ```
      """
    ),
  ]

  public static func expandedMarkdown(
    for snippet: MarkdownSnippet,
    draft: ArticleDraft,
    date: Date = Date()
  ) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return snippet.markdown
      .replacingOccurrences(of: "{{title}}", with: draft.title.trimmedForPublishing.nilIfEmpty ?? "未命名文章")
      .replacingOccurrences(of: "{{slug}}", with: draft.slug)
      .replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
  }

  public static func availableSnippets(
    for siteProfileID: UUID,
    customSnippets: [MarkdownSnippet]
  ) -> [MarkdownSnippet] {
    builtIns + customSnippets.filter { $0.siteProfileID == siteProfileID }
  }

  public static func savingCustomSnippet(
    id: String? = nil,
    title: String,
    detail: String,
    kind: MarkdownSnippetKind,
    markdown: String,
    siteProfileID: UUID,
    in existing: [MarkdownSnippet]
  ) -> [MarkdownSnippet] {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty, !normalizedMarkdown.isEmpty else {
      return existing
    }

    let snippetID = id ?? "custom-\(UUID().uuidString.lowercased())"
    let snippet = MarkdownSnippet(
      id: snippetID,
      title: normalizedTitle,
      detail: normalizedDetail,
      systemImage: kind == .articleTemplate ? "doc.text" : "text.badge.plus",
      kind: kind,
      markdown: normalizedMarkdown,
      siteProfileID: siteProfileID
    )
    let remaining = existing.filter { $0.id != snippetID }
    return Array(([snippet] + remaining).prefix(maximumCustomSnippetCount))
  }

  public static func removingCustomSnippet(
    id: String,
    from existing: [MarkdownSnippet]
  ) -> [MarkdownSnippet] {
    existing.filter { $0.id != id }
  }

}
