import Foundation

public struct SEOAuditFinding: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var severity: PreflightSeverity
  public var title: String
  public var message: String
  public var field: String?

  public init(
    id: UUID = UUID(),
    severity: PreflightSeverity,
    title: String,
    message: String,
    field: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.field = field
  }
}

public struct SEOAuditReport: Codable, Hashable, Sendable {
  public var titleCharacterCount: Int
  public var summaryCharacterCount: Int
  public var bodyCharacterCount: Int
  public var h1Count: Int
  public var hasPublishableCoverImage: Bool
  public var markdownPath: String
  public var frontMatterPreview: String
  public var findings: [SEOAuditFinding]

  public init(
    titleCharacterCount: Int,
    summaryCharacterCount: Int,
    bodyCharacterCount: Int,
    h1Count: Int,
    hasPublishableCoverImage: Bool,
    markdownPath: String,
    frontMatterPreview: String,
    findings: [SEOAuditFinding]
  ) {
    self.titleCharacterCount = titleCharacterCount
    self.summaryCharacterCount = summaryCharacterCount
    self.bodyCharacterCount = bodyCharacterCount
    self.h1Count = h1Count
    self.hasPublishableCoverImage = hasPublishableCoverImage
    self.markdownPath = markdownPath
    self.frontMatterPreview = frontMatterPreview
    self.findings = findings
  }

  public var warningCount: Int {
    findings.filter { $0.severity == .warning }.count
  }

  public var errorCount: Int {
    findings.filter { $0.severity == .error }.count
  }

  public var statusTitle: String {
    if errorCount > 0 {
      return "\(errorCount) 个错误"
    }
    if warningCount > 0 {
      return "\(warningCount) 个建议"
    }
    return "SEO 基础项通过"
  }
}

public struct SEOAuditService {
  private let frontMatterRenderer: FrontMatterRenderer

  public init(frontMatterRenderer: FrontMatterRenderer = FrontMatterRenderer()) {
    self.frontMatterRenderer = frontMatterRenderer
  }

  public func report(draft: ArticleDraft, profile: SiteProfile) -> SEOAuditReport {
    let title = draft.title.trimmedForPublishing
    let summary = draft.summary.trimmedForPublishing
    let body = draft.bodyMarkdown.trimmedForPublishing
    let h1Headings = h1Headings(in: draft.bodyMarkdown)
    let hasCover = hasPublishableCoverImage(draft: draft)

    var findings: [SEOAuditFinding] = []
    findings.append(contentsOf: titleFindings(title))
    findings.append(contentsOf: summaryFindings(summary))
    findings.append(contentsOf: headingFindings(h1Headings, title: title))
    findings.append(contentsOf: coverFindings(hasCover: hasCover, draft: draft))
    findings.append(contentsOf: taxonomyFindings(draft: draft, profile: profile))
    findings.append(
      .init(
        severity: .info,
        title: "发布路径",
        message: profile.markdownPath(for: draft),
        field: "path"
      )
    )

    return SEOAuditReport(
      titleCharacterCount: title.count,
      summaryCharacterCount: summary.count,
      bodyCharacterCount: body.count,
      h1Count: h1Headings.count,
      hasPublishableCoverImage: hasCover,
      markdownPath: profile.markdownPath(for: draft),
      frontMatterPreview: frontMatterRenderer.render(draft: draft, profile: profile),
      findings: sorted(findings)
    )
  }

  private func titleFindings(_ title: String) -> [SEOAuditFinding] {
    if title.isEmpty {
      return [
        .init(
          severity: .error,
          title: "标题为空",
          message: "搜索结果和社交分享需要稳定标题。",
          field: "title"
        )
      ]
    }

    if title.count < 10 {
      return [
        .init(
          severity: .warning,
          title: "标题偏短",
          message: "当前 \(title.count) 个字符，建议补足主题、对象或场景。",
          field: "title"
        )
      ]
    }

    if title.count > 60 {
      return [
        .init(
          severity: .warning,
          title: "标题偏长",
          message: "当前 \(title.count) 个字符，搜索结果里可能被截断。",
          field: "title"
        )
      ]
    }

    return [
      .init(
        severity: .info,
        title: "标题长度合适",
        message: "\(title.count) 个字符。",
        field: "title"
      )
    ]
  }

  private func summaryFindings(_ summary: String) -> [SEOAuditFinding] {
    if summary.isEmpty {
      return [
        .init(
          severity: .warning,
          title: "摘要为空",
          message: "建议写一段能直接作为 meta description 的摘要。",
          field: "summary"
        )
      ]
    }

    if summary.count < 50 {
      return [
        .init(
          severity: .warning,
          title: "摘要偏短",
          message: "当前 \(summary.count) 个字符，建议补充问题、结论或适用场景。",
          field: "summary"
        )
      ]
    }

    if summary.count > 160 {
      return [
        .init(
          severity: .warning,
          title: "摘要偏长",
          message: "当前 \(summary.count) 个字符，搜索结果摘要可能被截断。",
          field: "summary"
        )
      ]
    }

    return [
      .init(
        severity: .info,
        title: "摘要长度合适",
        message: "\(summary.count) 个字符。",
        field: "summary"
      )
    ]
  }

  private func headingFindings(_ h1Headings: [String], title: String) -> [SEOAuditFinding] {
    if h1Headings.isEmpty {
      return [
        .init(
          severity: .warning,
          title: "正文缺少 H1",
          message: "建议正文保留一个一级标题，方便预览和页面结构检查。",
          field: "body"
        )
      ]
    }

    if h1Headings.count > 1 {
      return [
        .init(
          severity: .warning,
          title: "正文有多个 H1",
          message: "当前 \(h1Headings.count) 个一级标题，建议保留一个主标题。",
          field: "body"
        )
      ]
    }

    let heading = h1Headings[0]
    if !title.isEmpty && heading.caseInsensitiveCompare(title) != .orderedSame {
      return [
        .init(
          severity: .info,
          title: "H1 与标题不同",
          message: "Front Matter title 和正文 H1 可以不同，但发布前建议确认这符合你的主题表达。",
          field: "body"
        )
      ]
    }

    return [
      .init(
        severity: .info,
        title: "正文 H1 已设置",
        message: heading,
        field: "body"
      )
    ]
  }

  private func coverFindings(hasCover: Bool, draft: ArticleDraft) -> [SEOAuditFinding] {
    if draft.isPrivate {
      return [
        .init(
          severity: .info,
          title: "私密文章不输出预览图",
          message: "Front Matter 不会包含封面路径，降低公开泄露风险。",
          field: "cover"
        )
      ]
    }

    if hasCover {
      return [
        .init(
          severity: .info,
          title: "预览图已设置",
          message: "发布包会输出当前框架对应的封面字段。",
          field: "cover"
        )
      ]
    }

    return [
      .init(
        severity: .warning,
        title: "缺少预览图",
        message: "公开文章建议设置封面图，用于社交分享和列表页。",
        field: "cover"
      )
    ]
  }

  private func taxonomyFindings(draft: ArticleDraft, profile: SiteProfile) -> [SEOAuditFinding] {
    let tags = draft.tags.isEmpty ? profile.defaultTags : draft.tags
    if tags.isEmpty {
      return [
        .init(
          severity: .warning,
          title: "标签为空",
          message: "建议至少设置一个标签，方便站内聚合和相关文章推荐。",
          field: "tags"
        )
      ]
    }

    return [
      .init(
        severity: .info,
        title: "标签已设置",
        message: tags.prefix(4).joined(separator: ", "),
        field: "tags"
      )
    ]
  }

  private func h1Headings(in markdown: String) -> [String] {
    markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("# "), trimmed.count > 2 else {
          return nil
        }
        return String(trimmed.dropFirst(2)).trimmedForPublishing.nilIfEmpty
      }
  }

  private func hasPublishableCoverImage(draft: ArticleDraft) -> Bool {
    guard let coverAttachmentID = draft.coverAttachmentID else {
      return false
    }

    return draft.attachments.contains {
      $0.id == coverAttachmentID && !$0.relativePublishPath.trimmedForPublishing.isEmpty
    }
  }

  private func sorted(_ findings: [SEOAuditFinding]) -> [SEOAuditFinding] {
    findings.sorted {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
  }
}
