import Foundation

struct PreflightDuplicateIndex: Sendable {
  private let indexedDraftIDs: Set<UUID>
  private let duplicateTitleDraftIDs: Set<UUID>
  private let duplicatePathDraftIDs: Set<UUID>

  init(drafts: [ArticleDraft], profile: SiteProfile) {
    let uniqueDrafts = Array(
      Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values
    )
    indexedDraftIDs = Set(uniqueDrafts.map(\.id))

    let titledDrafts = uniqueDrafts
      .filter { !$0.title.isEmpty }
      .sorted { lhs, rhs in
        let comparison = lhs.title.caseInsensitiveCompare(rhs.title)
        if comparison == .orderedSame {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return comparison == .orderedAscending
      }
    var duplicateTitleIDs = Set<UUID>()
    var groupStart = titledDrafts.startIndex
    while groupStart < titledDrafts.endIndex {
      var groupEnd = titledDrafts.index(after: groupStart)
      while groupEnd < titledDrafts.endIndex,
            titledDrafts[groupStart].title.caseInsensitiveCompare(titledDrafts[groupEnd].title) == .orderedSame {
        groupEnd = titledDrafts.index(after: groupEnd)
      }
      if titledDrafts.distance(from: groupStart, to: groupEnd) > 1 {
        duplicateTitleIDs.formUnion(titledDrafts[groupStart..<groupEnd].map(\.id))
      }
      groupStart = groupEnd
    }
    duplicateTitleDraftIDs = duplicateTitleIDs

    var draftIDsByPath: [String: Set<UUID>] = [:]
    for draft in uniqueDrafts {
      draftIDsByPath[profile.markdownPath(for: draft), default: []].insert(draft.id)
    }
    duplicatePathDraftIDs = draftIDsByPath.values.reduce(into: Set<UUID>()) { result, draftIDs in
      if draftIDs.count > 1 {
        result.formUnion(draftIDs)
      }
    }
  }

  func hasDuplicateTitle(for draftID: UUID) -> Bool? {
    guard indexedDraftIDs.contains(draftID) else { return nil }
    return duplicateTitleDraftIDs.contains(draftID)
  }

  func hasDuplicatePath(for draftID: UUID) -> Bool? {
    guard indexedDraftIDs.contains(draftID) else { return nil }
    return duplicatePathDraftIDs.contains(draftID)
  }
}

public struct PreflightCheckService: Sendable {
  private static let markdownImageRegex = try? NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(([^)]+)\)"#
  )
  private let publicRiskScanner: PublicRiskScanner
  private let imagePrivacySanitizer: ImagePrivacySanitizingService

  public init(
    publicRiskScanner: PublicRiskScanner = PublicRiskScanner(),
    imagePrivacySanitizer: ImagePrivacySanitizingService = ImagePrivacySanitizingService()
  ) {
    self.publicRiskScanner = publicRiskScanner
    self.imagePrivacySanitizer = imagePrivacySanitizer
  }

  public func run(
    draft: ArticleDraft,
    allDrafts: [ArticleDraft],
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport? = nil,
    includeRepositoryReadiness: Bool = true
  ) -> [PreflightIssue] {
    run(
      draft: draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: repositoryReport,
      includeRepositoryReadiness: includeRepositoryReadiness,
      duplicateIndex: nil
    )
  }

  func run(
    draft: ArticleDraft,
    allDrafts: [ArticleDraft],
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport? = nil,
    includeRepositoryReadiness: Bool = true,
    duplicateIndex: PreflightDuplicateIndex?
  ) -> [PreflightIssue] {
    var issues: [PreflightIssue] = []
    let title = draft.title.trimmedForPublishing
    let slug = draft.slug.trimmedForPublishing

    if title.isEmpty {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.text("标题为空"),
        message: CoreL10n.text("发布前必须填写 title。"),
        field: "title"
      ))
    }

    if slug.isEmpty {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.text("Slug 为空"),
        message: CoreL10n.text("发布路径需要稳定 slug。"),
        field: "slug"
      ))
    } else if !SlugService.isValid(slug, rule: profile.slugValidationRule) {
      issues.append(.init(
        // Keep the slug visible in publishing review without preventing an
        // otherwise safe publish. Unsafe rendered paths are checked
        // independently below, while an empty slug remains a hard error.
        severity: .warning,
        title: CoreL10n.text("Slug 格式非法"),
        message: profile.slugValidationRule.detail,
        field: "slug"
      ))
    }

    if draft.draft && !draft.isPrivate {
      issues.append(.init(
        severity: .warning,
        title: CoreL10n.text("仍是草稿"),
        message: CoreL10n.text("draft 为 true，发布前需要确认这是计划行为。"),
        field: "draft"
      ))
    }

    if draft.date > Date().addingTimeInterval(60) {
      issues.append(.init(
        severity: .warning,
        title: CoreL10n.text("日期在未来"),
        message: CoreL10n.text("确认文章发布日期是否正确。"),
        field: "date"
      ))
    }

    if draft.bodyMarkdown.trimmedForPublishing.count < 80 {
      issues.append(.init(
        severity: .warning,
        title: CoreL10n.text("正文偏短"),
        message: CoreL10n.text("正文少于 80 个字符，发布前建议确认内容完整。"),
        field: "body"
      ))
    }

    issues.append(contentsOf: publicRiskScanner.scan(draft: draft))

    let markdownPath = profile.markdownPath(for: draft)
    issues.append(
      contentsOf: repositoryPathIssues(
        label: CoreL10n.text("Markdown 路径"),
        path: markdownPath,
        field: "markdownPathPattern",
        requiredRoot: profile.contentRoot,
        rootLabel: CoreL10n.text("内容目录")
      )
    )
    issues.append(
      contentsOf: patternIssues(
        label: CoreL10n.text("Markdown 路径规则"),
        pattern: profile.markdownPathPattern,
        field: "markdownPathPattern"
      )
    )
    issues.append(contentsOf: rootPathIssues(
      label: CoreL10n.text("内容目录"),
      path: profile.contentRoot,
      field: "contentRoot"
    ))
    issues.append(contentsOf: rootPathIssues(
      label: CoreL10n.text("图片目录"),
      path: profile.assetRoot,
      field: "assetRoot"
    ))

    let hasDuplicateTitle = duplicateIndex?.hasDuplicateTitle(for: draft.id) ?? allDrafts.contains {
      $0.id != draft.id && !$0.title.isEmpty && $0.title.caseInsensitiveCompare(draft.title) == .orderedSame
    }
    if hasDuplicateTitle {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.text("标题重复"),
        message: CoreL10n.text("本地已有同名文章，发布前需要区分标题。"),
        field: "title"
      ))
    }

    let hasDuplicatePath = duplicateIndex?.hasDuplicatePath(for: draft.id) ?? allDrafts.contains {
      $0.id != draft.id && profile.markdownPath(for: $0) == markdownPath
    }
    if hasDuplicatePath {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.text("发布路径重复"),
        message: CoreL10n.format("%@ 已被另一篇草稿占用。", markdownPath),
        field: "slug"
      ))
    }

    let shouldIncludeRepositoryReadiness = includeRepositoryReadiness && profile.purpose.requiresRepositoryReadiness
    if shouldIncludeRepositoryReadiness && profile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      issues.append(.init(
        severity: .warning,
        title: CoreL10n.text("未选择本地仓库"),
        message: profile.purpose.repositoryRootMissingMessage,
        field: "repository"
      ))
    }

    if shouldIncludeRepositoryReadiness, let repositoryReport {
      issues.append(
        contentsOf: repositoryReport.preflightIssues(
          requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
        )
      )
    }

    for attachment in draft.attachments {
      let isVideo = attachment.mediaKind == .video
      if !isVideo, attachment.altText.trimmedForPublishing.isEmpty {
        issues.append(.init(
          severity: .warning,
          title: CoreL10n.text("图片缺少 alt"),
          message: CoreL10n.format("%@ 还没有可发布的 alt 文本。", attachment.originalFilename),
          field: "attachments",
          category: .missingMediaAlt
        ))
      }

      if attachment.relativePublishPath.trimmedForPublishing.isEmpty {
        issues.append(.init(
          severity: .error,
          title: CoreL10n.text(isVideo ? "视频发布路径为空" : "图片发布路径为空"),
          message: CoreL10n.format(
            isVideo ? "%@ 缺少视频发布路径。" : "%@ 缺少发布路径。",
            attachment.originalFilename
          ),
          field: "attachments",
          category: .missingMediaPublishPath
        ))
      }

      issues.append(
        contentsOf: repositoryPathIssues(
          label: CoreL10n.text(isVideo ? "视频路径" : "图片路径"),
          path: attachment.repositoryPath,
          field: "attachments",
          requiredRoot: profile.assetRoot,
          rootLabel: CoreL10n.text(isVideo ? "视频目录" : "图片目录"),
          category: .unsafeMediaRepositoryPath
        )
      )
      issues.append(contentsOf: publicPathIssues(path: attachment.relativePublishPath, filename: attachment.originalFilename))

      if !isVideo, let sourceFilePath = attachment.sourceFilePath?.nilIfEmpty {
        do {
          let inspection = try imagePrivacySanitizer.inspect(
            at: URL(fileURLWithPath: sourceFilePath)
          )
          if inspection.requiresSanitization {
            issues.append(
              .init(
                severity: .error,
                title: CoreL10n.text("图片包含隐私元数据"),
                message: CoreL10n.format(
                  "%@ 包含定位、设备、作者或其他可识别元数据；请在图片工作台清理后再发布。",
                  attachment.originalFilename
                ),
                field: "attachments",
                category: .publicRisk,
                relatedValue: attachment.repositoryPath
              ))
          }
        } catch {
          issues.append(
            .init(
              severity: .error,
              title: CoreL10n.text("无法验证图片隐私元数据"),
              message: CoreL10n.format(
                "%@ 无法完成隐私元数据检查；请重新导入或在图片工作台处理后再发布。",
                attachment.originalFilename
              ),
              field: "attachments",
              category: .publicRisk,
              relatedValue: attachment.repositoryPath
            ))
        }
      }
    }

    for missingImagePath in missingMarkdownImagePaths(in: draft) {
      issues.append(.init(
        severity: .warning,
        title: CoreL10n.text("正文图片未登记"),
        message: CoreL10n.format("%@ 不在当前文章附件列表中。", missingImagePath),
        field: "body",
        category: .unregisteredBodyImage,
        relatedValue: missingImagePath
      ))
    }

    if issues.isEmpty {
      issues.append(.init(
        severity: .info,
        title: CoreL10n.text("检查通过"),
        message: CoreL10n.text("当前文章满足本地发布前检查条件。")
      ))
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
    rootLabel: String,
    category: PreflightIssueCategory? = nil
  ) -> [PreflightIssue] {
    var issues: [PreflightIssue] = []
    let value = path.trimmedForPublishing

    if value.isEmpty {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.format("%@为空", label),
        message: CoreL10n.text("路径规则渲染结果为空。"),
        field: field,
        category: category
      ))
      return issues
    }

    let normalizedPath = value.normalizedRelativePath()
    if hasUnsafeRepositoryPathSyntax(value) {
      issues.append(.init(
        severity: .error,
        title: CoreL10n.format("%@不安全", label),
        message: CoreL10n.format("%@ 必须是仓库内的相对路径，且不能包含 ..、反斜杠或 URL。", value),
        field: field,
        category: category
      ))
      return issues
    }

    let root = requiredRoot.normalizedRelativePath()
    if !root.isEmpty, !isWithin(normalizedPath, root: root) {
      issues.append(
        .init(
          severity: .error,
          title: CoreL10n.format("%@不在%@", label, rootLabel),
          message: CoreL10n.format("%@ 不在 %@ 下，请检查站点路径规则。", normalizedPath, root),
          field: field,
          category: category
        )
      )
    }

    return issues
  }

  private func patternIssues(label: String, pattern: String, field: String) -> [PreflightIssue] {
    let value = pattern.trimmedForPublishing
    guard !value.isEmpty else {
      return [.init(
        severity: .error,
        title: CoreL10n.format("%@为空", label),
        message: CoreL10n.text("路径规则不能为空。"),
        field: field
      )]
    }

    guard hasUnsafeRepositoryPathSyntax(value) else {
      return []
    }

    return [
      .init(
        severity: .error,
        title: CoreL10n.format("%@不安全", label),
        message: CoreL10n.format("%@ 必须渲染为仓库内相对路径，不能使用绝对路径、..、反斜杠或 URL。", value),
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
        title: CoreL10n.format("%@不安全", label),
        message: CoreL10n.format("%@ 必须是仓库内相对目录，不能使用绝对路径、..、反斜杠或 URL。", value),
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
          title: CoreL10n.text("公开图片路径不安全"),
          message: CoreL10n.format("%@ 的公开路径 %@ 不能包含 ..、反斜杠或 URL。", filename, value),
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
    let registered = Set(
      draft.attachments
        .filter { $0.mediaKind == .image }
        .map(\.relativePublishPath)
    )
    guard let regex = Self.markdownImageRegex else {
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
