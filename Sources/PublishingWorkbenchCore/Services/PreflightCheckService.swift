import Foundation

public struct PreflightCheckService: Sendable {
  private let publicRiskScanner: PublicRiskScanner

  public init(publicRiskScanner: PublicRiskScanner = PublicRiskScanner()) {
    self.publicRiskScanner = publicRiskScanner
  }

  public func run(
    draft: ArticleDraft,
    allDrafts: [ArticleDraft],
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport? = nil,
    includeRepositoryReadiness: Bool = true
  ) -> [PreflightIssue] {
    var issues: [PreflightIssue] = []
    let title = draft.title.trimmedForPublishing
    let slug = draft.slug.trimmedForPublishing

    if title.isEmpty {
      issues.append(.init(severity: .error, title: "标题为空", message: "发布前必须填写 title。", field: "title"))
    }

    if slug.isEmpty {
      issues.append(.init(severity: .error, title: "Slug 为空", message: "发布路径需要稳定 slug。", field: "slug"))
    } else if !SlugService.isValid(slug, rule: profile.slugValidationRule) {
      issues.append(.init(severity: .error, title: "Slug 格式非法", message: profile.slugValidationRule.detail, field: "slug"))
    }

    if draft.draft && !draft.isPrivate {
      issues.append(.init(severity: .warning, title: "仍是草稿", message: "draft 为 true，发布前需要确认这是计划行为。", field: "draft"))
    }

    if draft.date > Date().addingTimeInterval(60) {
      issues.append(.init(severity: .warning, title: "日期在未来", message: "确认这是一篇计划发布文章。", field: "date"))
    }

    if draft.bodyMarkdown.trimmedForPublishing.count < 80 {
      issues.append(.init(severity: .warning, title: "正文偏短", message: "正文少于 80 个字符，发布前建议确认内容完整。", field: "body"))
    }

    issues.append(contentsOf: publicRiskScanner.scan(draft: draft))

    let markdownPath = profile.markdownPath(for: draft)
    issues.append(
      contentsOf: repositoryPathIssues(
        label: "Markdown 路径",
        path: markdownPath,
        field: "markdownPathPattern",
        requiredRoot: profile.contentRoot,
        rootLabel: "内容目录"
      )
    )
    issues.append(
      contentsOf: patternIssues(
        label: "Markdown 路径规则",
        pattern: profile.markdownPathPattern,
        field: "markdownPathPattern"
      )
    )
    issues.append(contentsOf: rootPathIssues(label: "内容目录", path: profile.contentRoot, field: "contentRoot"))
    issues.append(contentsOf: rootPathIssues(label: "图片目录", path: profile.assetRoot, field: "assetRoot"))

    let duplicateTitles = allDrafts.filter {
      $0.id != draft.id && !$0.title.isEmpty && $0.title.caseInsensitiveCompare(draft.title) == .orderedSame
    }
    if !duplicateTitles.isEmpty {
      issues.append(.init(severity: .error, title: "标题重复", message: "本地已有同名文章，发布前需要区分标题。", field: "title"))
    }

    let duplicatePaths = allDrafts.filter {
      $0.id != draft.id && profile.markdownPath(for: $0) == markdownPath
    }
    if !duplicatePaths.isEmpty {
      issues.append(.init(severity: .error, title: "发布路径重复", message: "\(markdownPath) 已被另一篇草稿占用。", field: "slug"))
    }

    let shouldIncludeRepositoryReadiness = includeRepositoryReadiness && profile.purpose.requiresRepositoryReadiness
    if shouldIncludeRepositoryReadiness && profile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      issues.append(.init(severity: .warning, title: "未选择本地仓库", message: profile.purpose.repositoryRootMissingMessage, field: "repository"))
    }

    if shouldIncludeRepositoryReadiness, let repositoryReport {
      issues.append(
        contentsOf: repositoryReport.preflightIssues(
          requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
        )
      )
    }

    for attachment in draft.attachments {
      if attachment.altText.trimmedForPublishing.isEmpty {
        issues.append(.init(severity: .warning, title: "图片缺少 alt", message: "\(attachment.originalFilename) 还没有可发布的 alt 文本。", field: "attachments"))
      }

      if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
        issues.append(.init(severity: .error, title: "图片发布路径为空", message: "\(attachment.originalFilename) 缺少发布路径。", field: "attachments"))
      }

      issues.append(
        contentsOf: repositoryPathIssues(
          label: "图片路径",
          path: attachment.repositoryPath,
          field: "attachments",
          requiredRoot: profile.assetRoot,
          rootLabel: "图片目录"
        )
      )
      issues.append(contentsOf: publicPathIssues(path: attachment.relativePublishPath, filename: attachment.originalFilename))
    }

    for missingImagePath in missingMarkdownImagePaths(in: draft) {
      issues.append(.init(severity: .warning, title: "正文图片未登记", message: "\(missingImagePath) 不在当前文章附件列表中。", field: "body"))
    }

    if issues.isEmpty {
      issues.append(.init(severity: .info, title: "检查通过", message: "当前文章满足本地发布前检查条件。"))
    }

    return issues.sorted {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
  }

  private func repositoryPathIssues(
    label: String,
    path: String,
    field: String,
    requiredRoot: String,
    rootLabel: String
  ) -> [PreflightIssue] {
    var issues: [PreflightIssue] = []
    let value = path.trimmedForPublishing

    if value.isEmpty {
      issues.append(.init(severity: .error, title: "\(label)为空", message: "路径规则渲染结果为空。", field: field))
      return issues
    }

    let normalizedPath = value.normalizedRelativePath()
    if hasUnsafeRepositoryPathSyntax(value) {
      issues.append(.init(severity: .error, title: "\(label)不安全", message: "\(value) 必须是仓库内的相对路径，且不能包含 ..、反斜杠或 URL。", field: field))
      return issues
    }

    let root = requiredRoot.normalizedRelativePath()
    if !root.isEmpty, !isWithin(normalizedPath, root: root) {
      issues.append(
        .init(
          severity: .error,
          title: "\(label)不在\(rootLabel)",
          message: "\(normalizedPath) 不在 \(root) 下，请检查站点路径规则。",
          field: field
        )
      )
    }

    return issues
  }

  private func patternIssues(label: String, pattern: String, field: String) -> [PreflightIssue] {
    let value = pattern.trimmedForPublishing
    guard !value.isEmpty else {
      return [.init(severity: .error, title: "\(label)为空", message: "路径规则不能为空。", field: field)]
    }

    guard hasUnsafeRepositoryPathSyntax(value) else {
      return []
    }

    return [
      .init(
        severity: .error,
        title: "\(label)不安全",
        message: "\(value) 必须渲染为仓库内相对路径，不能使用绝对路径、..、反斜杠或 URL。",
        field: field
      )
    ]
  }

  private func rootPathIssues(label: String, path: String, field: String) -> [PreflightIssue] {
    let value = path.trimmedForPublishing
    guard !value.isEmpty, hasUnsafeRepositoryPathSyntax(value) else {
      return []
    }

    return [
      .init(
        severity: .error,
        title: "\(label)不安全",
        message: "\(value) 必须是仓库内相对目录，不能使用绝对路径、..、反斜杠或 URL。",
        field: field
      )
    ]
  }

  private func publicPathIssues(path: String, filename: String) -> [PreflightIssue] {
    let value = path.trimmedForPublishing
    guard !value.isEmpty else {
      return []
    }

    if value.contains("\\") || value.contains("://") || containsParentTraversal(value) {
      return [
        .init(
          severity: .error,
          title: "公开图片路径不安全",
          message: "\(filename) 的公开路径 \(value) 不能包含 ..、反斜杠或 URL。",
          field: "attachments"
        )
      ]
    }

    return []
  }

  private func hasUnsafeRepositoryPathSyntax(_ path: String) -> Bool {
    let value = path.trimmedForPublishing
    return value.hasPrefix("/")
      || value.contains("\\")
      || value.contains("://")
      || containsParentTraversal(value)
  }

  private func containsParentTraversal(_ path: String) -> Bool {
    path
      .split(separator: "/", omittingEmptySubsequences: false)
      .contains { $0 == ".." }
  }

  private func isWithin(_ path: String, root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  private func missingMarkdownImagePaths(in draft: ArticleDraft) -> [String] {
    let registered = Set(draft.attachments.map(\.relativePublishPath))
    let pattern = #"!\[[^\]]*\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let text = draft.bodyMarkdown
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
      let path = String(text[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return nil
      }
      return registered.contains(path) ? nil : path
    }
  }
}
