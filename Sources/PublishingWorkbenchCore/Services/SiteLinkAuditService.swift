import Foundation

public enum SiteLinkSyntaxKind: String, Hashable, Sendable {
  case markdown
  case referenceDefinition
  case wiki
  case autolink
  case bareURL
  case htmlAnchor
}

public enum SiteLinkResolution: String, Hashable, Sendable {
  case validInternal
  case brokenInternal
  case ambiguousInternal
  case pendingSlugRedirect
  case external
  case sameDocument
  case ignored
}

/// One link token with the exact UTF-16 target range needed for a safe,
/// token-aware replacement. The range covers only the path/URL, not its label,
/// query or fragment.
public struct SiteLinkReference: Identifiable, Hashable, Sendable {
  public var id: String {
    "\(sourceDraftID.uuidString):\(targetUTF16Range.location):\(targetUTF16Range.length)"
  }

  public var sourceDraftID: UUID
  public var sourceTitle: String
  public var anchorText: String
  public var target: String
  public var syntax: SiteLinkSyntaxKind
  public var targetUTF16Range: NSRange
  public var normalizedTarget: String?
  public var resolvedDraftID: UUID?
  public var resolution: SiteLinkResolution

  public init(
    sourceDraftID: UUID,
    sourceTitle: String,
    anchorText: String,
    target: String,
    syntax: SiteLinkSyntaxKind,
    targetUTF16Range: NSRange,
    normalizedTarget: String? = nil,
    resolvedDraftID: UUID? = nil,
    resolution: SiteLinkResolution
  ) {
    self.sourceDraftID = sourceDraftID
    self.sourceTitle = sourceTitle
    self.anchorText = anchorText
    self.target = target
    self.syntax = syntax
    self.targetUTF16Range = targetUTF16Range
    self.normalizedTarget = normalizedTarget
    self.resolvedDraftID = resolvedDraftID
    self.resolution = resolution
  }
}

public struct SiteLinkAuditReport: Sendable {
  public var references: [SiteLinkReference]
  public var items: [SiteLinkAuditItem]

  public init(references: [SiteLinkReference], items: [SiteLinkAuditItem]) {
    self.references = references
    self.items = items
  }

  public func references(
    to draftID: UUID,
    resolution: SiteLinkResolution? = nil
  ) -> [SiteLinkReference] {
    references.filter {
      $0.resolvedDraftID == draftID && (resolution == nil || $0.resolution == resolution)
    }
  }

  public func preflightIssues(for draft: ArticleDraft) -> [PreflightIssue] {
    var projected: [PreflightIssue] = items.compactMap { item in
      guard item.draftID == draft.id else { return nil }
      let severity: PreflightSeverity
      switch item.severity {
      case .error: severity = .error
      case .warning: severity = .warning
      case .info: severity = .info
      }
      let title: String
      let category: PreflightIssueCategory
      switch item.kind {
      case .brokenInternal:
        title = CoreL10n.text("内部链接无法解析")
        category = .brokenInternalLink
      case .slugRedirectReference:
        title = CoreL10n.text("旧 Slug 引用")
        category = .slugRedirectCandidate
      case .externalDead:
        title = CoreL10n.text("外部死链")
        category = .unreachableExternalLink
      case .externalUnverified:
        title = CoreL10n.text("外部链接暂时无法验证")
        category = .unreachableExternalLink
      case .anchorText, .advisory:
        return nil
      }
      return PreflightIssue(
        severity: severity,
        title: title,
        message: item.message,
        field: PreflightIssueField.body.rawValue,
        category: category,
        relatedValue: item.target
      )
    }

    if !draft.pendingSlugRedirectPaths.isEmpty {
      let legacyReferences = references(to: draft.id, resolution: .pendingSlugRedirect)
      let sourceCount = Set(legacyReferences.map(\.sourceDraftID)).count
      let routeList = draft.pendingSlugRedirectPaths.joined(separator: "、")
      let message =
        legacyReferences.isEmpty
        ? CoreL10n.format("Slug 已变更；可将旧地址 %@ 写入 aliases，保留外部来路。", routeList)
        : CoreL10n.format(
          "Slug 已变更，检测到 %d 篇文章中的 %d 处旧引用；可一键更新引用，或将 %@ 写入 aliases。",
          sourceCount,
          legacyReferences.count,
          routeList
        )
      projected.append(
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("Slug 变更待处理"),
          message: message,
          field: PreflightIssueField.slug.rawValue,
          category: .slugRedirectCandidate,
          relatedValue: draft.pendingSlugRedirectPaths.first
        ))
    }
    return projected
  }

  public func mergingPreflightIssues(
    _ baseIssues: [PreflightIssue],
    for draft: ArticleDraft
  ) -> [PreflightIssue] {
    let linkIssues = preflightIssues(for: draft)
    guard !linkIssues.isEmpty else { return baseIssues }
    var merged = baseIssues.filter { $0.title != CoreL10n.text("检查通过") }
    merged.append(contentsOf: linkIssues)
    return merged.sorted {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
  }
}

public struct SiteExternalLinkProbeResult: Hashable, Sendable {
  public var url: URL
  public var statusCode: Int?
  public var finalURL: URL?
  public var failureMessage: String?

  public init(
    url: URL,
    statusCode: Int? = nil,
    finalURL: URL? = nil,
    failureMessage: String? = nil
  ) {
    self.url = url
    self.statusCode = statusCode
    self.finalURL = finalURL
    self.failureMessage = failureMessage
  }
}

public struct SiteExternalLinkProbe: Sendable {
  public typealias Operation = @Sendable (URL) async -> SiteExternalLinkProbeResult
  private let operation: Operation

  public init(operation: @escaping Operation) {
    self.operation = operation
  }

  public func probe(_ url: URL) async -> SiteExternalLinkProbeResult {
    await operation(url)
  }

  public static let live = SiteExternalLinkProbe { url in
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.httpMethod = "GET"
    request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
    request.setValue("RepoPress-Link-Audit/1", forHTTPHeaderField: "User-Agent")
    do {
      let (_, response) = try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: 64 * 1_024,
        allowsPrivateNetworkAccess: false
      )
      return SiteExternalLinkProbeResult(
        url: url,
        statusCode: response.statusCode,
        finalURL: response.url
      )
    } catch is CancellationError {
      return SiteExternalLinkProbeResult(url: url, failureMessage: "检查已取消。")
    } catch is HTTPResponseLimitError {
      // Receiving bounded response headers and then reaching the body limit is
      // enough to establish that the endpoint is reachable.
      return SiteExternalLinkProbeResult(url: url, failureMessage: nil)
    } catch {
      return SiteExternalLinkProbeResult(url: url, failureMessage: error.localizedDescription)
    }
  }
}

public struct SiteLinkAuditService: Sendable {
  private struct TargetEntry: Hashable, Sendable {
    let draftID: UUID
    let isPendingSlugRoute: Bool
  }

  private struct RawLink: Hashable, Sendable {
    let anchor: String
    let target: String
    let syntax: SiteLinkSyntaxKind
    let targetRange: NSRange
  }

  private let externalProbe: SiteExternalLinkProbe

  private static let markdownLinkExpression = try? NSRegularExpression(
    pattern:
      #"(?<!!)\[([^\]\n]*)\]\(\s*<?([^\s)>]+)>?(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"#
  )
  private static let referenceDefinitionExpression = try? NSRegularExpression(
    pattern: #"(?m)^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]+)>?"#
  )
  private static let wikiLinkExpression = try? NSRegularExpression(
    pattern: #"(?<!!)\[\[([^\]\n]+)\]\]"#
  )
  private static let autolinkExpression = try? NSRegularExpression(
    pattern: #"<(https?://[^<>\s]+)>"#
  )
  private static let htmlAnchorExpression = try? NSRegularExpression(
    pattern: #"(?i)<a\b[^>]*\bhref\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#
  )
  private static let bareURLExpression = try? NSRegularExpression(
    pattern: #"https?://[^\s<>\[\]\(\)\"']+"#
  )
  private static let inlineCodeExpression = try? NSRegularExpression(
    pattern: #"`+[^`\n]*`+"#
  )

  public init(externalProbe: SiteExternalLinkProbe = .live) {
    self.externalProbe = externalProbe
  }

  public func report(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SiteLinkAuditReport {
    let index = routeIndex(drafts: drafts, profile: profile)
    let knownAssets = knownAssetPaths(drafts: drafts)
    var references: [SiteLinkReference] = []
    var items: [SiteLinkAuditItem] = []

    for draft in drafts where !draft.isGeneralDraft {
      let currentRoute = canonicalRoute(for: draft, profile: profile)
      let repositoryPath = (draft.repositoryPath ?? profile.markdownPath(for: draft))
        .normalizedRelativePath()
      for raw in rawLinks(in: draft.bodyMarkdown) {
        let resolved = resolve(
          raw,
          sourceDraft: draft,
          sourceRoute: currentRoute,
          sourceRepositoryPath: repositoryPath,
          profile: profile,
          index: index,
          knownAssets: knownAssets
        )
        references.append(resolved)
        if let item = auditItem(for: resolved, draft: draft) {
          items.append(item)
        }
      }
    }

    return SiteLinkAuditReport(
      references: references.sorted(by: referenceOrdering),
      items: items.sorted(by: itemOrdering)
    )
  }

  public func reportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) async throws -> SiteLinkAuditReport {
    let service = self
    let localAuditTask = Task.detached(priority: .utility) {
      service.report(drafts: drafts, profile: profile)
    }
    var result = await withTaskCancellationHandler {
      await localAuditTask.value
    } onCancel: {
      localAuditTask.cancel()
    }
    try Task.checkCancellation()
    let externalReferences = result.references.filter { $0.resolution == .external }
    let urls = Dictionary(
      externalReferences.compactMap { reference -> (String, URL)? in
        guard let url = URL(string: reference.target) else { return nil }
        return (url.absoluteString, url)
      },
      uniquingKeysWith: { first, _ in first }
    ).values.sorted { $0.absoluteString < $1.absoluteString }

    var probeResults: [String: SiteExternalLinkProbeResult] = [:]
    let concurrencyLimit = 6
    for start in stride(from: 0, to: urls.count, by: concurrencyLimit) {
      try Task.checkCancellation()
      let chunk = urls[start..<min(start + concurrencyLimit, urls.count)]
      await withTaskGroup(of: SiteExternalLinkProbeResult.self) { group in
        for url in chunk {
          group.addTask { await externalProbe.probe(url) }
        }
        for await probeResult in group {
          probeResults[probeResult.url.absoluteString] = probeResult
        }
      }
    }

    let draftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    for reference in externalReferences {
      guard let probe = probeResults[reference.target],
        let draft = draftsByID[reference.sourceDraftID],
        let item = externalAuditItem(reference: reference, probe: probe, draft: draft)
      else { continue }
      result.items.append(item)
    }
    result.items.sort(by: itemOrdering)
    return result
  }

  private func routeIndex(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> [String: Set<TargetEntry>] {
    var index: [String: Set<TargetEntry>] = [:]
    for draft in drafts where !draft.isGeneralDraft {
      let current = TargetEntry(draftID: draft.id, isPendingSlugRoute: false)
      append(current, key: "route:\(canonicalRoute(for: draft, profile: profile))", to: &index)
      let plannedPath = profile.markdownPath(for: draft).normalizedRelativePath()
      append(current, key: "repo:\(plannedPath)", to: &index)
      if let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty {
        append(current, key: "repo:\(repositoryPath)", to: &index)
        let repositoryRoute = normalizedRoute(
          SiteArticleURLResolver().relativeWebPath(
            from: repositoryPath,
            profile: profile,
            permalink: draft.permalink
          )
        )
        let isLegacy = repositoryRoute != canonicalRoute(for: draft, profile: profile)
        append(
          TargetEntry(draftID: draft.id, isPendingSlugRoute: isLegacy),
          key: "route:\(repositoryRoute)",
          to: &index
        )
      }
      for alias in draft.aliases {
        if alias.hasPrefix("/") {
          append(current, key: "route:\(normalizedRoute(alias))", to: &index)
        }
        append(current, key: "wiki:\(normalizedWikiKey(alias))", to: &index)
      }
      let pending = TargetEntry(draftID: draft.id, isPendingSlugRoute: true)
      for oldRoute in draft.pendingSlugRedirectPaths {
        append(pending, key: "route:\(normalizedRoute(oldRoute))", to: &index)
        let legacyWikiToken =
          oldRoute
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          .split(separator: "/")
          .last
          .map(String.init)
          .map(normalizedWikiKey) ?? ""
        append(pending, key: "wiki:\(legacyWikiToken)", to: &index)
      }
      for token in wikiTokens(for: draft, plannedPath: plannedPath) where !token.isEmpty {
        append(current, key: "wiki:\(token)", to: &index)
      }
    }
    return index
  }

  private func append(
    _ entry: TargetEntry,
    key: String,
    to index: inout [String: Set<TargetEntry>]
  ) {
    guard !key.hasSuffix(":") else { return }
    index[key, default: []].insert(entry)
  }

  private func resolve(
    _ raw: RawLink,
    sourceDraft: ArticleDraft,
    sourceRoute: String,
    sourceRepositoryPath: String,
    profile: SiteProfile,
    index: [String: Set<TargetEntry>],
    knownAssets: Set<String>
  ) -> SiteLinkReference {
    let target = raw.target.trimmedForPublishing
    guard !target.isEmpty else {
      return reference(raw, source: sourceDraft, resolution: .brokenInternal)
    }
    if target.hasPrefix("#") {
      return reference(
        raw,
        source: sourceDraft,
        normalizedTarget: sourceRoute,
        resolvedDraftID: sourceDraft.id,
        resolution: .sameDocument
      )
    }
    if raw.syntax == .wiki {
      let key = "wiki:\(normalizedWikiKey(pathWithoutQueryOrFragment(target)))"
      return resolvedReference(raw, source: sourceDraft, key: key, index: index)
    }

    guard let components = URLComponents(string: target) else {
      return reference(raw, source: sourceDraft, resolution: .brokenInternal)
    }
    if let scheme = components.scheme?.lowercased() {
      if scheme == "http" || scheme == "https" {
        if isSameSiteURL(components.url, profile: profile) {
          return resolvedRouteReference(
            raw,
            source: sourceDraft,
            route: normalizedRoute(components.percentEncodedPath),
            index: index
          )
        }
        return reference(raw, source: sourceDraft, resolution: .external)
      }
      return reference(raw, source: sourceDraft, resolution: .ignored)
    }
    if target.hasPrefix("//") {
      return reference(raw, source: sourceDraft, resolution: .external)
    }

    let targetPath = pathWithoutQueryOrFragment(target)
    let normalizedRepositoryTarget = resolvedRepositoryPath(
      targetPath.removingPercentEncoding ?? targetPath,
      relativeTo: sourceRepositoryPath
    )
    if looksLikeMarkdownPath(targetPath),
      let normalizedRepositoryTarget
    {
      let key = "repo:\(normalizedRepositoryTarget)"
      if index[key] != nil {
        return resolvedReference(raw, source: sourceDraft, key: key, index: index)
      }
    }

    let route: String
    if targetPath.hasPrefix("/") {
      route = normalizedRoute(targetPath)
    } else {
      route = resolvedWebRoute(targetPath, relativeTo: sourceRoute)
    }
    let assetCandidates = [
      route.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      normalizedRepositoryTarget ?? "",
    ]
    if assetCandidates.contains(where: knownAssets.contains)
      || normalizedRepositoryTarget.map({
        repositoryFileExists(at: $0, profile: profile)
      }) == true
    {
      return reference(
        raw,
        source: sourceDraft,
        normalizedTarget: route,
        resolution: .validInternal
      )
    }
    return resolvedRouteReference(raw, source: sourceDraft, route: route, index: index)
  }

  private func resolvedRouteReference(
    _ raw: RawLink,
    source: ArticleDraft,
    route: String,
    index: [String: Set<TargetEntry>]
  ) -> SiteLinkReference {
    resolvedReference(raw, source: source, key: "route:\(route)", index: index)
  }

  private func resolvedReference(
    _ raw: RawLink,
    source: ArticleDraft,
    key: String,
    index: [String: Set<TargetEntry>]
  ) -> SiteLinkReference {
    let entries = index[key] ?? []
    let draftIDs = Set(entries.map(\.draftID))
    if draftIDs.count > 1 {
      return reference(
        raw,
        source: source,
        normalizedTarget: String(
          key.dropFirst(
            key.firstIndex(of: ":").map { key.distance(from: key.startIndex, to: $0) + 1 } ?? 0)),
        resolution: .ambiguousInternal
      )
    }
    guard let entry = entries.first else {
      return reference(raw, source: source, resolution: .brokenInternal)
    }
    return reference(
      raw,
      source: source,
      normalizedTarget: String(
        key.dropFirst(
          key.firstIndex(of: ":").map { key.distance(from: key.startIndex, to: $0) + 1 } ?? 0)),
      resolvedDraftID: entry.draftID,
      resolution: entry.isPendingSlugRoute ? .pendingSlugRedirect : .validInternal
    )
  }

  private func reference(
    _ raw: RawLink,
    source: ArticleDraft,
    normalizedTarget: String? = nil,
    resolvedDraftID: UUID? = nil,
    resolution: SiteLinkResolution
  ) -> SiteLinkReference {
    SiteLinkReference(
      sourceDraftID: source.id,
      sourceTitle: source.title.nilIfEmpty ?? "未命名文章",
      anchorText: raw.anchor,
      target: raw.target,
      syntax: raw.syntax,
      targetUTF16Range: raw.targetRange,
      normalizedTarget: normalizedTarget,
      resolvedDraftID: resolvedDraftID,
      resolution: resolution
    )
  }

  private func auditItem(
    for reference: SiteLinkReference,
    draft: ArticleDraft
  ) -> SiteLinkAuditItem? {
    switch reference.resolution {
    case .brokenInternal:
      return SiteLinkAuditItem(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
        target: reference.target,
        anchorText: reference.anchorText,
        severity: reference.target.trimmedForPublishing.isEmpty ? .error : .warning,
        message: reference.target.trimmedForPublishing.isEmpty
          ? "链接目标为空。"
          : "没有匹配到当前站点的文章、别名或资源路径。",
        kind: .brokenInternal
      )
    case .ambiguousInternal:
      return SiteLinkAuditItem(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
        target: reference.target,
        anchorText: reference.anchorText,
        severity: .error,
        message: "链接目标同时匹配多篇文章，无法确定实际路由。",
        kind: .brokenInternal
      )
    case .pendingSlugRedirect:
      return SiteLinkAuditItem(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
        target: reference.target,
        anchorText: reference.anchorText,
        severity: .warning,
        message: "链接仍指向文章变更前的旧 Slug；请更新引用或为旧地址写入 aliases。",
        kind: .slugRedirectReference
      )
    case .external:
      guard
        reference.anchorText.trimmedForPublishing.count <= 4
          || reference.anchorText == reference.target
      else { return nil }
      return SiteLinkAuditItem(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
        target: reference.target,
        anchorText: reference.anchorText,
        severity: .info,
        message: "外部链接锚文本过短或直接裸露 URL，建议补充上下文。",
        kind: .anchorText
      )
    case .validInternal, .sameDocument, .ignored:
      return nil
    }
  }

  private func externalAuditItem(
    reference: SiteLinkReference,
    probe: SiteExternalLinkProbeResult,
    draft: ArticleDraft
  ) -> SiteLinkAuditItem? {
    if let status = probe.statusCode {
      if (200..<400).contains(status) || [401, 403, 405, 429].contains(status) {
        return nil
      }
      let isConfirmedDead = status == 404 || status == 410
      return SiteLinkAuditItem(
        draftID: draft.id,
        draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
        target: reference.target,
        anchorText: reference.anchorText,
        severity: isConfirmedDead ? .error : .warning,
        message: isConfirmedDead
          ? "外部地址返回 HTTP \(status)，已确认无法访问。"
          : "外部地址返回 HTTP \(status)，需要人工复查。",
        kind: isConfirmedDead ? .externalDead : .externalUnverified,
        statusCode: status,
        finalTarget: probe.finalURL?.absoluteString
      )
    }
    guard let failure = probe.failureMessage?.nilIfEmpty else { return nil }
    return SiteLinkAuditItem(
      draftID: draft.id,
      draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
      target: reference.target,
      anchorText: reference.anchorText,
      severity: .warning,
      message: "外部地址暂时无法验证：\(failure)",
      kind: .externalUnverified,
      finalTarget: probe.finalURL?.absoluteString
    )
  }

  private func rawLinks(in markdown: String) -> [RawLink] {
    let source = markdown as NSString
    let excluded = excludedCodeRanges(in: markdown)
    var links: [RawLink] = []
    var occupied: [NSRange] = []

    func appendMatches(
      expression: NSRegularExpression?,
      syntax: SiteLinkSyntaxKind,
      anchorGroup: Int?,
      targetGroup: Int,
      transform: ((String, NSRange) -> (String, NSRange))? = nil
    ) {
      guard let expression else { return }
      for match in expression.matches(
        in: markdown,
        range: NSRange(location: 0, length: source.length)
      ) {
        guard match.numberOfRanges > targetGroup else { continue }
        var range = match.range(at: targetGroup)
        guard range.location != NSNotFound,
          !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }),
          !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 })
        else { continue }
        var target = source.substring(with: range)
        if let transform {
          (target, range) = transform(target, range)
        }
        let anchor: String
        if let anchorGroup, match.numberOfRanges > anchorGroup,
          match.range(at: anchorGroup).location != NSNotFound
        {
          anchor = source.substring(with: match.range(at: anchorGroup))
        } else {
          anchor = target
        }
        links.append(RawLink(anchor: anchor, target: target, syntax: syntax, targetRange: range))
        occupied.append(range)
      }
    }

    appendMatches(
      expression: Self.markdownLinkExpression,
      syntax: .markdown,
      anchorGroup: 1,
      targetGroup: 2
    ) { value, range in
      (value, pathOnlyRange(for: value, in: range))
    }
    appendMatches(
      expression: Self.referenceDefinitionExpression,
      syntax: .referenceDefinition,
      anchorGroup: 1,
      targetGroup: 2
    ) { value, range in
      (value, pathOnlyRange(for: value, in: range))
    }
    appendMatches(
      expression: Self.wikiLinkExpression,
      syntax: .wiki,
      anchorGroup: nil,
      targetGroup: 1
    ) { value, range in
      let path = String(value.split(separator: "|", maxSplits: 1).first ?? "")
      let pathWithoutFragment = String(path.split(separator: "#", maxSplits: 1).first ?? "")
      return (
        path, NSRange(location: range.location, length: (pathWithoutFragment as NSString).length)
      )
    }
    appendMatches(
      expression: Self.autolinkExpression,
      syntax: .autolink,
      anchorGroup: nil,
      targetGroup: 1
    ) { value, range in
      (value, pathOnlyRange(for: value, in: range))
    }
    appendMatches(
      expression: Self.htmlAnchorExpression,
      syntax: .htmlAnchor,
      anchorGroup: nil,
      targetGroup: 1
    ) { value, range in
      (value, pathOnlyRange(for: value, in: range))
    }
    appendMatches(
      expression: Self.bareURLExpression,
      syntax: .bareURL,
      anchorGroup: nil,
      targetGroup: 0
    ) { value, range in
      let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!"))
      return (trimmed, NSRange(location: range.location, length: (trimmed as NSString).length))
    }
    return links.sorted { $0.targetRange.location < $1.targetRange.location }
  }

  private func excludedCodeRanges(in markdown: String) -> [NSRange] {
    let source = markdown as NSString
    var ranges: [NSRange] = []
    var openFence: (character: unichar, count: Int, location: Int)?
    var cursor = 0
    while cursor < source.length {
      let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
      let line = source.substring(with: lineRange)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let first = line.utf16.first {
        let count = line.utf16.prefix { $0 == first }.count
        if (first == 0x60 || first == 0x7e), count >= 3 {
          if let currentFence = openFence,
            currentFence.character == first,
            count >= currentFence.count
          {
            ranges.append(
              NSRange(
                location: currentFence.location,
                length: NSMaxRange(lineRange) - currentFence.location
              ))
            openFence = nil
          } else if openFence == nil {
            openFence = (first, count, lineRange.location)
          }
        }
      }
      cursor = NSMaxRange(lineRange)
    }
    if let openFence {
      ranges.append(
        NSRange(location: openFence.location, length: source.length - openFence.location))
    }
    if let inline = Self.inlineCodeExpression {
      ranges.append(
        contentsOf: inline.matches(
          in: markdown,
          range: NSRange(location: 0, length: source.length)
        ).map(\.range))
    }
    return ranges
  }

  private func canonicalRoute(for draft: ArticleDraft, profile: SiteProfile) -> String {
    normalizedRoute(
      SiteArticleURLResolver().relativeWebPath(
        from: profile.markdownPath(for: draft),
        profile: profile,
        permalink: draft.permalink
      )
    )
  }

  private func normalizedRoute(_ value: String) -> String {
    let withoutQuery = pathWithoutQueryOrFragment(value)
    let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
    var components: [String] = []
    for component in decoded.split(separator: "/").map(String.init) {
      switch component {
      case "", ".": continue
      case "..": if !components.isEmpty { components.removeLast() }
      default: components.append(component)
      }
    }
    if let last = components.last?.lowercased(), ["index", "index.html", "readme"].contains(last) {
      components.removeLast()
    } else if let last = components.last, last.lowercased().hasSuffix(".html") {
      components[components.count - 1] = String(last.dropLast(5))
    }
    return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))/"
  }

  private func resolvedWebRoute(_ target: String, relativeTo sourceRoute: String) -> String {
    let base = URL(string: "https://repopress.invalid\(normalizedRoute(sourceRoute))")!
    let resolved = URL(string: target, relativeTo: base)?.absoluteURL.path ?? target
    return normalizedRoute(resolved)
  }

  private func resolvedRepositoryPath(_ target: String, relativeTo sourcePath: String) -> String? {
    guard !target.hasPrefix("/") else {
      return String(target.dropFirst()).normalizedRelativePath().nilIfEmpty
    }
    let sourceDirectory = URL(fileURLWithPath: "/" + sourcePath)
      .deletingLastPathComponent()
    let resolved = sourceDirectory.appendingPathComponent(target).standardizedFileURL.path
    guard resolved.hasPrefix("/"), !resolved.hasPrefix("/../") else { return nil }
    return String(resolved.dropFirst()).normalizedRelativePath().nilIfEmpty
  }

  private func pathWithoutQueryOrFragment(_ value: String) -> String {
    let beforeFragment =
      value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    return String(
      beforeFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
        ?? "")
  }

  private func pathOnlyRange(for value: String, in range: NSRange) -> NSRange {
    NSRange(
      location: range.location,
      length: (pathWithoutQueryOrFragment(value) as NSString).length
    )
  }

  private func normalizedWikiKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private func wikiTokens(for draft: ArticleDraft, plannedPath: String) -> Set<String> {
    let basename = URL(fileURLWithPath: plannedPath).deletingPathExtension().lastPathComponent
    return Set([draft.title, draft.slug, basename].map(normalizedWikiKey))
  }

  private func looksLikeMarkdownPath(_ path: String) -> Bool {
    let lower = path.lowercased()
    return lower.hasSuffix(".md") || lower.hasSuffix(".mdx") || lower.hasSuffix(".markdown")
  }

  private func isSameSiteURL(_ url: URL?, profile: SiteProfile) -> Bool {
    guard let url,
      let siteURL = profile.deploymentSiteURL.flatMap(URL.init(string:)),
      let leftHost = url.host?.lowercased(),
      let rightHost = siteURL.host?.lowercased()
    else { return false }
    return leftHost == rightHost
      && (url.port ?? defaultPort(url)) == (siteURL.port ?? defaultPort(siteURL))
  }

  private func defaultPort(_ url: URL) -> Int {
    url.scheme?.lowercased() == "http" ? 80 : 443
  }

  private func knownAssetPaths(drafts: [ArticleDraft]) -> Set<String> {
    Set(
      drafts.flatMap { draft in
        draft.attachments.flatMap { attachment in
          [
            attachment.relativePublishPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            attachment.repositoryPath.normalizedRelativePath(),
          ]
        }
      }.filter { !$0.isEmpty })
  }

  private func repositoryFileExists(at repositoryPath: String, profile: SiteProfile) -> Bool {
    guard let rootURL = profile.localRepositoryRootURL else { return false }
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate =
      root
      .appendingPathComponent(repositoryPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    guard candidate.path.hasPrefix(rootPath + "/") else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

  private func referenceOrdering(_ lhs: SiteLinkReference, _ rhs: SiteLinkReference) -> Bool {
    if lhs.sourceTitle == rhs.sourceTitle {
      return lhs.targetUTF16Range.location < rhs.targetUTF16Range.location
    }
    return lhs.sourceTitle.localizedStandardCompare(rhs.sourceTitle) == .orderedAscending
  }

  private func itemOrdering(_ lhs: SiteLinkAuditItem, _ rhs: SiteLinkAuditItem) -> Bool {
    let ranks: [SiteLinkAuditSeverity: Int] = [.error: 0, .warning: 1, .info: 2]
    if ranks[lhs.severity] == ranks[rhs.severity] {
      if lhs.draftTitle == rhs.draftTitle { return lhs.target < rhs.target }
      return lhs.draftTitle.localizedStandardCompare(rhs.draftTitle) == .orderedAscending
    }
    return ranks[lhs.severity, default: 3] < ranks[rhs.severity, default: 3]
  }
}
