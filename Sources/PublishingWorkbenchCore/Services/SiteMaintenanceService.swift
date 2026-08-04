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

  public init(
    calendar: Calendar = Calendar(identifier: .gregorian),
    asyncReportOperation: AsyncReportOperation? = nil
  ) {
    self.calendar = calendar
    self.asyncReportOperation = asyncReportOperation
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
    now: Date = Date()
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

    let task = Task.detached(priority: .utility) {
      try makeReport(
        drafts: drafts,
        profile: profile,
        releaseRecords: releaseRecords,
        maintenanceOperationRecords: maintenanceOperationRecords,
        now: now,
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
    cancellationCheck: () throws -> Void
  ) rethrows -> SiteMaintenanceReport {
    try cancellationCheck()
    let calendarBuckets = calendarBuckets(drafts: drafts)
    try cancellationCheck()
    let calendarInsights = calendarInsights(drafts: drafts, buckets: calendarBuckets, now: now)
    try cancellationCheck()
    let calendarScheduleItems = calendarScheduleItems(drafts: drafts, profile: profile, now: now)
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
    let linkAuditItems = try linkAuditItems(
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
      calendarInsights: calendarInsights,
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
      calendarBuckets: calendarBuckets,
      calendarInsights: calendarInsights,
      calendarScheduleItems: calendarScheduleItems,
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
    calendarInsights: [ContentCalendarInsight],
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
      - calendarInsights.count * 5
      - (hasPublishedContentWithoutLog ? 6 : 0)
    let score = min(100, max(0, rawScore))

    let level: SiteMaintenanceHealthLevel
    if score < 45 || linkErrorCount > 0 || highActionCount >= 2 {
      level = .urgent
    } else if score < 70 || highActionCount > 0 || mediumActionCount >= 3 {
      level = .needsWork
    } else if score < 88 || !calendarInsights.isEmpty || !actionItems.isEmpty {
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
    if !calendarInsights.isEmpty {
      drivers.append("\(calendarInsights.count) 条内容节奏提示")
    }
    if hasPublishedContentWithoutLog {
      drivers.append("已发布内容缺少操作日志")
    }
    if drivers.isEmpty && draftCount > 0 {
      drivers.append("内容日历、分类和链接审计未发现阻断项")
    }
    if draftCount == 0 {
      drivers.append("当前 Profile 还没有文章")
    }

    let nextAction: String
    if let firstHigh = actionItems.first(where: { $0.priority == .high }) {
      nextAction = "\(firstHigh.kind.displayName)：\(firstHigh.title)"
    } else if let firstMedium = actionItems.first(where: { $0.priority == .medium }) {
      nextAction = "\(firstMedium.kind.displayName)：\(firstMedium.title)"
    } else if let insight = calendarInsights.first {
      nextAction = insight.summary
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
      message = "有轻量维护项或内容节奏提示，适合排入下一次整理。"
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

  private func calendarBuckets(drafts: [ArticleDraft]) -> [ContentCalendarBucket] {
    let grouped = Dictionary(grouping: drafts) { draft in
      monthKey(for: draft.date)
    }

    return grouped.keys.sorted(by: >).map { key in
      let bucketDrafts = grouped[key, default: []]
      return ContentCalendarBucket(
        monthKey: key,
        title: monthTitle(for: bucketDrafts.first?.date ?? Date()),
        articleCount: bucketDrafts.count,
        draftCount: bucketDrafts.filter { $0.status == .draft || $0.draft }.count,
        readyCount: bucketDrafts.filter { $0.status == .ready }.count,
        publishedCount: bucketDrafts.filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }.count,
        publicCount: bucketDrafts.filter { !$0.isPrivate }.count,
        privateCount: bucketDrafts.filter(\.isPrivate).count
      )
    }
  }

  private func calendarInsights(
    drafts: [ArticleDraft],
    buckets: [ContentCalendarBucket],
    now: Date
  ) -> [ContentCalendarInsight] {
    guard !drafts.isEmpty else {
      return []
    }

    let publicDrafts = drafts.filter { !$0.isPrivate }
    let readyPublicDrafts = publicDrafts.filter { $0.status == .ready }
    let currentMonthKey = monthKey(for: now)
    let currentMonthBucket = buckets.first { $0.monthKey == currentMonthKey }
    var insights: [ContentCalendarInsight] = []

    if readyPublicDrafts.count >= 2 {
      insights.append(
        ContentCalendarInsight(
          id: "ready-backlog",
          title: "待发布积压",
          summary: "\(readyPublicDrafts.count) 篇公开文章已经标记待发布。",
          detail: "建议先选 1 到 2 篇完成链接、SEO 和发布检查，避免内容长期停在待发布队列。",
          priority: readyPublicDrafts.count >= 5 ? .high : .medium,
          systemImage: "tray.full"
        )
      )
    }

    if let currentMonthBucket,
       currentMonthBucket.draftCount >= 3,
       currentMonthBucket.draftCount > currentMonthBucket.readyCount + currentMonthBucket.publishedCount {
      insights.append(
        ContentCalendarInsight(
          id: "current-month-draft-heavy",
          title: "本月草稿偏多",
          summary: "\(currentMonthBucket.title) 有 \(currentMonthBucket.draftCount) 篇草稿，高于待发布和已发布合计。",
          detail: "适合从当月草稿里挑选可以收尾的文章，先补摘要、标签、分类和首屏结构。",
          priority: .medium,
          systemImage: "square.and.pencil"
        )
      )
    }

    if (currentMonthBucket?.publishedCount ?? 0) == 0,
       !readyPublicDrafts.isEmpty {
      insights.append(
        ContentCalendarInsight(
          id: "current-month-no-published",
          title: "本月还没有公开发布",
          summary: "当前月份暂无公开发布记录，但已有 \(readyPublicDrafts.count) 篇待发布文章。",
          detail: "可以把待发布队列作为本月内容节奏的优先来源。",
          priority: .medium,
          systemImage: "calendar.badge.exclamationmark"
        )
      )
    }

    let latestPublishedDate = publicDrafts
      .filter { $0.status == .published || (!$0.draft && !$0.isPrivate) }
      .map(\.date)
      .max()
    if let latestPublishedDate {
      let inactiveMonths = monthsBetween(latestPublishedDate, and: now)
      if inactiveMonths >= 2 {
        insights.append(
          ContentCalendarInsight(
            id: "publish-gap",
            title: "公开发布断档",
            summary: "最近一次公开发布距今约 \(inactiveMonths) 个月。",
            detail: "建议复查是否有可快速更新的旧文或待发布文章，先恢复稳定更新节奏。",
            priority: inactiveMonths >= 4 ? .high : .medium,
            systemImage: "calendar.badge.clock"
          )
        )
      }
    }

    return insights.sorted {
      if $0.priority.rawValue == $1.priority.rawValue {
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      return $0.priority.rawValue < $1.priority.rawValue
    }
  }

  private func calendarScheduleItems(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    now: Date
  ) -> [ContentCalendarScheduleItem] {
    let startOfToday = calendar.startOfDay(for: now)
    let readyPublicDrafts = drafts
      .filter { !$0.isPrivate && $0.status == .ready }
      .sorted {
        if $0.date == $1.date {
          return $0.updatedAt < $1.updatedAt
        }
        return $0.date < $1.date
      }

    var nextOverflowSlot = startOfToday
    return readyPublicDrafts.map { draft in
      let draftDay = calendar.startOfDay(for: draft.date)
      let scheduledDate: Date
      let reason: String
      let systemImage: String
      if draftDay >= startOfToday {
        scheduledDate = draftDay
        reason = "沿用文章日期作为发布槽位。"
        systemImage = "calendar"
      } else {
        scheduledDate = nextOverflowSlot
        reason = "文章日期已过，建议从当前维护节奏中重新排期。"
        systemImage = "calendar.badge.clock"
      }
      if scheduledDate >= nextOverflowSlot {
        nextOverflowSlot = calendar.date(byAdding: .day, value: 3, to: scheduledDate) ?? nextOverflowSlot
      }
      return ContentCalendarScheduleItem(
        draftID: draft.id,
        title: draft.title.nilIfEmpty ?? "未命名文章",
        markdownPath: profile.markdownPath(for: draft),
        scheduledDate: scheduledDate,
        reason: reason,
        systemImage: systemImage
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

  private func monthKey(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
  }

  private func monthTitle(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month], from: date)
    return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
  }

  private func days(from start: Date, to end: Date) -> Int {
    max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
  }

  private func monthsBetween(_ start: Date, and end: Date) -> Int {
    let startComponents = calendar.dateComponents([.year, .month], from: start)
    let endComponents = calendar.dateComponents([.year, .month], from: end)
    let startMonth = (startComponents.year ?? 0) * 12 + (startComponents.month ?? 0)
    let endMonth = (endComponents.year ?? 0) * 12 + (endComponents.month ?? 0)
    return max(0, endMonth - startMonth)
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
