import Foundation

public struct SiteMaintenanceService: Sendable {
  public typealias AsyncReportOperation = @Sendable (
    [ArticleDraft],
    SiteProfile,
    [ReleaseRecord],
    [MaintenanceOperationRecord],
    Date
  ) async throws -> SiteMaintenanceReport

  private let calendar: Calendar
  private let asyncReportOperation: AsyncReportOperation?
  private let linkAuditService: SiteLinkAuditService

  public init(
    calendar: Calendar = Calendar(identifier: .gregorian),
    asyncReportOperation: AsyncReportOperation? = nil,
    linkAuditService: SiteLinkAuditService = SiteLinkAuditService()
  ) {
    self.calendar = calendar
    self.asyncReportOperation = asyncReportOperation
    self.linkAuditService = linkAuditService
  }

  public func report(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    now: Date = Date()
  ) -> SiteMaintenanceReport {
    makeReport(
      drafts: drafts,
      profile: profile,
      releaseRecords: releaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      now: now,
      linkAuditItemsOverride: linkAuditService.report(drafts: drafts, profile: profile).items,
      cancellationCheck: {}
    )
  }

  /// Generates the report away from the caller's actor. Cancellation checks
  /// are applied between stages and inside the quadratic relation scan so a
  /// superseded refresh does not continue consuming CPU unnecessarily.
  public func reportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    now: Date = Date(),
    linkAuditReport: SiteLinkAuditReport? = nil,
    validatesExternalLinks: Bool = true
  ) async throws -> SiteMaintenanceReport {
    if let asyncReportOperation {
      return try await asyncReportOperation(
        drafts,
        profile,
        releaseRecords,
        maintenanceOperationRecords,
        now
      )
    }

    let linkAuditItems: [SiteLinkAuditItem]
    if let linkAuditReport {
      linkAuditItems = linkAuditReport.items
    } else if validatesExternalLinks {
      linkAuditItems = try await linkAuditService.reportAsync(
        drafts: drafts,
        profile: profile
      ).items
    } else {
      let service = linkAuditService
      linkAuditItems = await Task.detached(priority: .utility) {
        service.report(drafts: drafts, profile: profile).items
      }.value
    }
    let task = Task.detached(priority: .utility) {
      try makeReport(
        drafts: drafts,
        profile: profile,
        releaseRecords: releaseRecords,
        maintenanceOperationRecords: maintenanceOperationRecords,
        now: now,
        linkAuditItemsOverride: linkAuditItems,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func makeReport(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord],
    now: Date,
    linkAuditItemsOverride: [SiteLinkAuditItem]? = nil,
    cancellationCheck: () throws -> Void
  ) rethrows -> SiteMaintenanceReport {
    try cancellationCheck()
    let tagSummary = taxonomySummary(title: "标签", drafts: drafts, values: \.tags)
    try cancellationCheck()
    let categorySummary = taxonomySummary(title: "分类", drafts: drafts, values: \.categories)
    try cancellationCheck()
    let staleArticles = staleArticles(drafts: drafts, profile: profile, now: now)
    try cancellationCheck()
    let relationSuggestions = try relationSuggestions(
      drafts: drafts,
      profile: profile,
      cancellationCheck: cancellationCheck
    )
    try cancellationCheck()
    let linkAuditItems = try linkAuditItemsOverride ?? linkAuditItems(
      drafts: drafts,
      profile: profile,
      cancellationCheck: cancellationCheck
    )
    try cancellationCheck()
    let operationLogEntries = operationEntries(
      releaseRecords: releaseRecords,
      maintenanceOperationRecords: maintenanceOperationRecords,
      profileID: profile.id
    )
    try cancellationCheck()
    let actionItems = maintenanceActionItems(
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      relationSuggestions: relationSuggestions,
      linkAuditItems: linkAuditItems
    )
    try cancellationCheck()
    let healthSummary = healthSummary(
      draftCount: drafts.count,
      publishedCount: drafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      linkAuditItems: linkAuditItems,
      actionItems: actionItems,
      operationLogEntries: operationLogEntries
    )

    return SiteMaintenanceReport(
      profileID: profile.id,
      generatedAt: now,
      draftCount: drafts.count,
      publicDraftCount: drafts.filter { !$0.isPrivate }.count,
      privateDraftCount: drafts.filter(\.isPrivate).count,
      readyCount: drafts.filter { $0.status == .ready }.count,
      publishedCount: drafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
      tagSummary: tagSummary,
      categorySummary: categorySummary,
      staleArticles: staleArticles,
      relationSuggestions: relationSuggestions,
      linkAuditItems: linkAuditItems,
      actionItems: actionItems,
      operationLogEntries: operationLogEntries,
      healthSummary: healthSummary
    )
  }

  private func healthSummary(
    draftCount: Int,
    publishedCount: Int,
    tagSummary: TaxonomyGovernanceSummary,
    categorySummary: TaxonomyGovernanceSummary,
    staleArticles: [StaleArticleCandidate],
    linkAuditItems: [SiteLinkAuditItem],
    actionItems: [MaintenanceActionItem],
    operationLogEntries: [MaintenanceOperationLogEntry]
  ) -> SiteMaintenanceHealthSummary {
    let highActionCount = actionItems.filter { $0.priority == .high }.count
    let mediumActionCount = actionItems.filter { $0.priority == .medium }.count
    let lowActionCount = actionItems.filter { $0.priority == .low }.count
    let linkErrorCount = linkAuditItems.filter { $0.severity == .error }.count
    let linkWarningCount = linkAuditItems.filter { $0.severity == .warning }.count
    let missingTaxonomyCount = tagSummary.missingCount + categorySummary.missingCount
    let hasPublishedContentWithoutLog = publishedCount > 0 && operationLogEntries.isEmpty

    let rawScore = 100
      - highActionCount * 18
      - mediumActionCount * 10
      - lowActionCount * 4
      - linkErrorCount * 18
      - linkWarningCount * 8
      - staleArticles.count * 8
      - missingTaxonomyCount * 3
      - (hasPublishedContentWithoutLog ? 6 : 0)
    let score = min(100, max(0, rawScore))

    let level: SiteMaintenanceHealthLevel
    if score < 45 || linkErrorCount > 0 || highActionCount >= 2 {
      level = .urgent
    } else if score < 70 || highActionCount > 0 || mediumActionCount >= 3 {
      level = .needsWork
    } else if score < 88 || !actionItems.isEmpty {
      level = .watch
    } else {
      level = .stable
    }

    var drivers: [String] = []
    if highActionCount > 0 {
      drivers.append("\(highActionCount) 个高优先级维护项")
    }
    if linkErrorCount > 0 || linkWarningCount > 0 {
      drivers.append("\(linkErrorCount + linkWarningCount) 个链接风险")
    }
    if !staleArticles.isEmpty {
      drivers.append("\(staleArticles.count) 篇旧文候选")
    }
    if missingTaxonomyCount > 0 {
      drivers.append("\(missingTaxonomyCount) 篇缺少标签或分类")
    }
    if hasPublishedContentWithoutLog {
      drivers.append("已发布内容缺少操作日志")
    }
    if drivers.isEmpty && draftCount > 0 {
      drivers.append(CoreL10n.text("分类和链接审计未发现阻断项"))
    }
    if draftCount == 0 {
      drivers.append("当前 Profile 还没有文章")
    }

    let nextAction: String
    if let firstHigh = actionItems.first(where: { $0.priority == .high }) {
      nextAction = "\(firstHigh.kind.displayName)：\(firstHigh.title)"
    } else if let firstMedium = actionItems.first(where: { $0.priority == .medium }) {
      nextAction = "\(firstMedium.kind.displayName)：\(firstMedium.title)"
    } else if draftCount == 0 {
      nextAction = "先创建或导入文章，再生成维护清单。"
    } else {
      nextAction = "保持当前维护节奏，发布后继续记录操作日志。"
    }

    let title: String
    let message: String
    switch level {
    case .stable:
      title = "站点维护状态稳定"
      message = "主要维护入口没有发现需要立即处理的阻断项。"
    case .watch:
      title = "站点维护需要关注"
      message = CoreL10n.text("有轻量维护项，适合排入下一次整理。")
    case .needsWork:
      title = "站点维护需要整理"
      message = "存在旧文、分类或链接风险，建议先处理行动队列前几项。"
    case .urgent:
      title = "站点维护需要优先处理"
      message = "存在高优先级维护项或链接错误，发布前应先处理。"
    }

    return SiteMaintenanceHealthSummary(
      level: level,
      score: score,
      title: title,
      message: message,
      nextAction: nextAction,
      drivers: drivers
    )
  }

  private func maintenanceActionItems(
    tagSummary: TaxonomyGovernanceSummary,
    categorySummary: TaxonomyGovernanceSummary,
    staleArticles: [StaleArticleCandidate],
    relationSuggestions: [SiteRelationSuggestion],
    linkAuditItems: [SiteLinkAuditItem]
  ) -> [MaintenanceActionItem] {
    var items: [MaintenanceActionItem] = []

    for item in linkAuditItems where item.severity == .warning || item.severity == .error {
      let priority: MaintenanceActionPriority = item.severity == .error ? .high : .medium
      items.append(
        MaintenanceActionItem(
          id: "link-\(item.id.uuidString)",
          kind: .linkAudit,
          priority: priority,
          title: item.severity == .error ? "修复空链接：\(item.draftTitle)" : "确认内链路径：\(item.draftTitle)",
          summary: item.message,
          detail: item.target,
          draftID: item.draftID,
          targetPath: item.target,
          systemImage: item.severity.systemImage
        )
      )
    }

    for item in staleArticles {
      let priority: MaintenanceActionPriority = item.reasons.count >= 2 || item.daysSinceUpdate >= 180 ? .high : .medium
      items.append(
        MaintenanceActionItem(
          id: "stale-\(item.draftID.uuidString)",
          kind: .staleArticle,
          priority: priority,
          title: "复查旧文：\(item.title)",
          summary: item.reasons.joined(separator: "；"),
          detail: item.markdownPath,
          draftID: item.draftID,
          targetPath: item.markdownPath,
          systemImage: "clock.badge.exclamationmark"
        )
      )
    }

    appendTaxonomyActions(
      summary: tagSummary,
      missingSystemImage: "tag",
      into: &items
    )
    appendTaxonomyActions(
      summary: categorySummary,
      missingSystemImage: "folder",
      into: &items
    )

    for item in relationSuggestions.prefix(6) {
      let priority: MaintenanceActionPriority = item.sharedLabels.count >= 2 ? .medium : .low
      items.append(
        MaintenanceActionItem(
          id: "relation-\(item.id)",
          kind: .relationSuggestion,
          priority: priority,
          title: "补内链：\(item.sourceTitle) -> \(item.targetTitle)",
          summary: item.reason,
          detail: item.targetPath,
          draftID: item.sourceDraftID,
          targetPath: item.targetPath,
          systemImage: "point.3.connected.trianglepath.dotted"
        )
      )
    }

    return items.sorted {
      if $0.priority.rawValue == $1.priority.rawValue {
        if $0.kind.rawValue == $1.kind.rawValue {
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return $0.kind.rawValue < $1.kind.rawValue
      }
      return $0.priority.rawValue < $1.priority.rawValue
    }
    .prefix(14)
    .map { $0 }
  }

  private func appendTaxonomyActions(
    summary: TaxonomyGovernanceSummary,
    missingSystemImage: String,
    into items: inout [MaintenanceActionItem]
  ) {
    if summary.missingCount > 0 {
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-missing",
          kind: .taxonomy,
          priority: .medium,
          title: "补齐缺失\(summary.title)",
          summary: "\(summary.missingCount) 篇文章还没有\(summary.title)，影响归档、相关推荐和站内导航。",
          detail: "优先处理待发布和公开文章。",
          draftID: nil,
          targetPath: nil,
          systemImage: missingSystemImage
        )
      )
    }

    if !summary.overloadedEntries.isEmpty {
      let names = summary.overloadedEntries.prefix(3).map(\.name).joined(separator: "、")
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-overloaded",
          kind: .taxonomy,
          priority: .medium,
          title: "拆分高频\(summary.title)",
          summary: "\(names) 覆盖文章过多，建议拆成更具体的专题。",
          detail: "高频\(summary.title)会削弱读者筛选和相关文章推荐。",
          draftID: nil,
          targetPath: nil,
          systemImage: "rectangle.3.group"
        )
      )
    }

    if summary.singletonCount > 0 {
      items.append(
        MaintenanceActionItem(
          id: "taxonomy-\(summary.title)-singleton",
          kind: .taxonomy,
          priority: .low,
          title: "合并孤立\(summary.title)",
          summary: "\(summary.singletonCount) 个\(summary.title)只关联 1 篇文章。",
          detail: "可以合并到已有\(summary.title)，或补充同主题文章形成系列。",
          draftID: nil,
          targetPath: nil,
          systemImage: "square.stack.3d.up"
        )
      )
    }
  }

  private func relationSuggestions(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> [SiteRelationSuggestion] {
    try relationSuggestionScan(
      drafts: drafts,
      profile: profile,
      cancellationCheck: cancellationCheck
    ).suggestions
  }

  func relationSuggestionScan(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SiteRelationScanResult {
    relationSuggestionScan(
      drafts: drafts,
      profile: profile,
      cancellationCheck: {}
    )
  }

  func relationSuggestionScan(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> SiteRelationScanResult {
    let sourceDrafts = drafts.filter { !$0.isPrivate && !$0.draft }
    let targetDrafts = drafts.filter { !$0.isPrivate && !$0.draft && $0.status == .published }
    var targetsByID: [UUID: RelationTargetIndexEntry] = [:]
    var targetIDsByLabel: [String: [UUID]] = [:]
    var targetIndexEntryCount = 0

    for (ordinal, target) in targetDrafts.enumerated() {
      try cancellationCheck()
      let labels = taxonomyLabels(for: target)
      guard !labels.isEmpty else {
        continue
      }

      let targetPath = canonicalWebPath(from: profile.markdownPath(for: target))
      let slugPath = "/" + (target.slug.nilIfEmpty ?? SlugService.fallbackSlug(date: target.date)) + "/"
      targetsByID[target.id] = RelationTargetIndexEntry(
        draft: target,
        targetPath: targetPath,
        foldedTargetPath: targetPath.lowercased(),
        foldedSlugPath: slugPath.lowercased(),
        ordinal: ordinal
      )
      for label in labels {
        targetIDsByLabel[label.normalizedName, default: []].append(target.id)
        targetIndexEntryCount += 1
      }
    }

    var suggestions: [SiteRelationSuggestion] = []
    var metrics = SiteRelationScanMetrics(
      sourceDraftCount: sourceDrafts.count,
      publishedTargetDraftCount: targetDrafts.count,
      indexedTargetDraftCount: targetsByID.count,
      indexedLabelCount: targetIDsByLabel.count,
      targetIndexEntryCount: targetIndexEntryCount,
      candidateEvaluationCount: 0,
      suggestionCount: 0
    )

    for source in sourceDrafts {
      try cancellationCheck()
      let sourceLabels = taxonomyLabels(for: source)
      guard !sourceLabels.isEmpty else {
        continue
      }
      let sourceBody = source.bodyMarkdown.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      var sharedLabelsByTargetID: [UUID: [TaxonomyLabel]] = [:]

      for label in sourceLabels {
        for targetID in targetIDsByLabel[label.normalizedName] ?? [] where targetID != source.id {
          try cancellationCheck()
          sharedLabelsByTargetID[targetID, default: []].append(label)
        }
      }

      let targets = sharedLabelsByTargetID.keys
        .compactMap { targetsByID[$0] }
        .sorted { $0.ordinal < $1.ordinal }

      for target in targets {
        try cancellationCheck()
        metrics.candidateEvaluationCount += 1
        guard !sourceBody.contains(target.foldedTargetPath),
              !sourceBody.contains(target.foldedSlugPath),
              let shared = sharedLabelsByTargetID[target.draft.id] else {
          continue
        }

        suggestions.append(
          SiteRelationSuggestion(
            sourceDraftID: source.id,
            sourceTitle: source.title.nilIfEmpty ?? "未命名文章",
            targetDraftID: target.draft.id,
            targetTitle: target.draft.title.nilIfEmpty ?? "未命名文章",
            targetPath: target.targetPath,
            sharedLabels: shared.map(\.displayName),
            reason: "共享 \(shared.map(\.displayName).joined(separator: "、"))，但正文还没有链接到目标文章。"
          )
        )
      }
    }

    let sortedSuggestions = suggestions.sorted {
      if $0.sharedLabels.count == $1.sharedLabels.count {
        return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
      }
      return $0.sharedLabels.count > $1.sharedLabels.count
    }
    metrics.suggestionCount = sortedSuggestions.count
    return SiteRelationScanResult(
      suggestions: sortedSuggestions,
      metrics: metrics
    )
  }

  private func taxonomySummary(
    title: String,
    drafts: [ArticleDraft],
    values: KeyPath<ArticleDraft, [String]>
  ) -> TaxonomyGovernanceSummary {
    var entriesByName: [String: (name: String, titles: [String])] = [:]
    var missingCount = 0

    for draft in drafts {
      let names = draft[keyPath: values]
        .map { $0.trimmedForPublishing }
        .filter { !$0.isEmpty }

      if names.isEmpty {
        missingCount += 1
      }

      for name in names {
        let key = normalizedTaxonomyName(name)
        var bucket = entriesByName[key] ?? (name: name, titles: [])
        bucket.titles.append(draft.title.nilIfEmpty ?? "未命名文章")
        entriesByName[key] = bucket
      }
    }

    let entries = entriesByName.values.map { bucket in
      TaxonomyGovernanceEntry(
        name: bucket.name,
        normalizedName: normalizedTaxonomyName(bucket.name),
        count: bucket.titles.count,
        draftTitles: bucket.titles.sorted()
      )
    }
    .sorted {
      if $0.count == $1.count {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.count > $1.count
    }

    return TaxonomyGovernanceSummary(
      title: title,
      entries: entries,
      missingCount: missingCount,
      singletonCount: entries.filter { $0.count == 1 }.count,
      overloadedEntries: entries.filter { $0.count >= 8 }
    )
  }

  private func staleArticles(drafts: [ArticleDraft], profile: SiteProfile, now: Date) -> [StaleArticleCandidate] {
    drafts.compactMap { draft in
      guard !draft.isPrivate, !draft.draft || draft.status == .published else {
        return nil
      }

      let articleDays = days(from: draft.date, to: now)
      let updateDays = days(from: draft.updatedAt, to: now)
      var reasons: [String] = []
      if articleDays >= 180 {
        reasons.append("文章日期已超过 \(articleDays) 天")
      }
      if updateDays >= 90 {
        reasons.append("最近更新已超过 \(updateDays) 天")
      }
      if draft.bodyMarkdown.localizedCaseInsensitiveContains("TODO")
        || draft.bodyMarkdown.localizedCaseInsensitiveContains("待确认") {
        reasons.append("正文仍有待确认标记")
      }

      guard !reasons.isEmpty else {
        return nil
      }

      return StaleArticleCandidate(
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名文章",
        markdownPath: profile.markdownPath(for: draft),
        daysSinceArticleDate: articleDays,
        daysSinceUpdate: updateDays,
        reasons: reasons
      )
    }
    .sorted {
      if $0.reasons.count == $1.reasons.count {
        return $0.daysSinceUpdate > $1.daysSinceUpdate
      }
      return $0.reasons.count > $1.reasons.count
    }
  }

  private func linkAuditItems(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    cancellationCheck: () throws -> Void
  ) rethrows -> [SiteLinkAuditItem] {
    let knownInternalPaths = Set(drafts.flatMap { draft in
      [
        canonicalWebPath(from: profile.markdownPath(for: draft)),
        "/" + (draft.slug.nilIfEmpty ?? SlugService.fallbackSlug(date: draft.date)) + "/",
      ]
    })

    var items: [SiteLinkAuditItem] = []
    for draft in drafts {
      try cancellationCheck()
      for link in markdownLinks(in: draft.bodyMarkdown) {
        let target = normalizedLinkTarget(link.target)
        guard !target.isEmpty else {
          items.append(SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .error,
            message: "链接目标为空。"
          ))
          continue
        }

        if target.hasPrefix("http://") || target.hasPrefix("https://") {
          if let item = externalLinkAuditItem(draft: draft, link: link, target: target) {
            items.append(item)
          }
          continue
        }

        guard target.hasPrefix("/") else {
          items.append(SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .info,
            message: "相对链接需要发布前确认路径基准。"
          ))
          continue
        }

        let pathOnly = pathWithoutQueryOrFragment(target)
        guard !isAssetPath(pathOnly) else {
          continue
        }
        guard knownInternalPaths.contains(pathOnly) else {
          items.append(SiteLinkAuditItem(
            draftID: draft.id,
            draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
            target: link.target,
            anchorText: link.anchor,
            severity: .warning,
            message: "没有匹配到当前 Profile 的文章路径。"
          ))
          continue
        }
      }
    }
    return items
  }

  private func externalLinkAuditItem(
    draft: ArticleDraft,
    link: MarkdownLink,
    target: String
  ) -> SiteLinkAuditItem? {
    guard link.anchor.trimmedForPublishing.count <= 4 || link.anchor == target else {
      return nil
    }
    return SiteLinkAuditItem(
      draftID: draft.id,
      draftTitle: draft.title.nilIfEmpty ?? "未命名文章",
      target: target,
      anchorText: link.anchor,
      severity: .info,
      message: "外部链接锚文本过短或直接裸露 URL，建议补充上下文。"
    )
  }

  private func operationEntries(
    releaseRecords: [ReleaseRecord],
    maintenanceOperationRecords: [MaintenanceOperationRecord],
    profileID: UUID
  ) -> [MaintenanceOperationLogEntry] {
    let releaseEntries = releaseRecords
      .filter { record in
        record.siteProfileID == nil || record.siteProfileID == profileID
      }
      .map { record in
        MaintenanceOperationLogEntry(
          id: record.id,
          title: record.title,
          summary: record.summary,
          createdAt: record.createdAt,
          systemImage: record.kind.systemImage
        )
      }

    let maintenanceEntries = maintenanceOperationRecords
      .filter { $0.profileID == profileID }
      .map { record in
        MaintenanceOperationLogEntry(
          id: record.id,
          title: "维护处理：\(record.actionTitle)",
          summary: record.summary,
          createdAt: record.createdAt,
          systemImage: record.actionKind.systemImage
        )
      }

    return (releaseEntries + maintenanceEntries)
      .sorted { lhs, rhs in
        lhs.createdAt > rhs.createdAt
      }
      .prefix(12)
      .map { $0 }
  }

  private func markdownLinks(in markdown: String) -> [MarkdownLink] {
    let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return regex.matches(in: markdown, range: range).compactMap { match in
      guard let anchorRange = Range(match.range(at: 1), in: markdown),
            let targetRange = Range(match.range(at: 2), in: markdown) else {
        return nil
      }
      return MarkdownLink(anchor: String(markdown[anchorRange]), target: String(markdown[targetRange]))
    }
  }

  private func days(from start: Date, to end: Date) -> Int {
    max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
  }

  private func normalizedTaxonomyName(_ name: String) -> String {
    name.trimmedForPublishing.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private func taxonomyLabels(for draft: ArticleDraft) -> [TaxonomyLabel] {
    var seen: Set<String> = []
    return (draft.tags + draft.categories).compactMap { name in
      let displayName = name.trimmedForPublishing
      let label = TaxonomyLabel(
        displayName: displayName,
        normalizedName: normalizedTaxonomyName(displayName)
      )
      guard !label.normalizedName.isEmpty,
            seen.insert(label.normalizedName).inserted else {
        return nil
      }
      return label
    }
  }

  private func canonicalWebPath(from markdownPath: String) -> String {
    var path = markdownPath.normalizedRelativePath()
    for prefix in ["content/posts/", "content/", "src/content/blog/", "source/_posts/", "_posts/"] where path.hasPrefix(prefix) {
      path = String(path.dropFirst(prefix.count))
      break
    }
    for suffix in [".mdx", ".markdown", ".md"] where path.hasSuffix(suffix) {
      path = String(path.dropLast(suffix.count))
      break
    }
    return "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
  }

  private func normalizedLinkTarget(_ target: String) -> String {
    target.trimmedForPublishing.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private func pathWithoutQueryOrFragment(_ target: String) -> String {
    let trimmed = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
    let path = trimmed.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
    if path.hasSuffix("/") {
      return path
    }
    guard !path.contains(".") else {
      return path
    }
    return path + "/"
  }

  private func isAssetPath(_ path: String) -> Bool {
    ["/images/", "/assets/", "/static/"].contains { path.hasPrefix($0) }
  }
}

private struct MarkdownLink {
  var anchor: String
  var target: String
}

private struct RelationTargetIndexEntry {
  var draft: ArticleDraft
  var targetPath: String
  var foldedTargetPath: String
  var foldedSlugPath: String
  var ordinal: Int
}

private struct TaxonomyLabel: Hashable {
  var displayName: String
  var normalizedName: String
}
