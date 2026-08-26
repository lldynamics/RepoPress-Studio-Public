import Foundation

public struct ContentHealthReportService: Sendable {
  private let preflightService: PreflightCheckService
  private let imageWorkbenchService: SiteImageWorkbenchService
  private let aiFixQueueService: AIPublishingFixQueueService
  private let linkAuditService: SiteLinkAuditService
  private let cache: ContentHealthReportCache
  private let cacheNamespace: UUID

  public init(
    preflightService: PreflightCheckService = PreflightCheckService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    aiFixQueueService: AIPublishingFixQueueService = AIPublishingFixQueueService(),
    linkAuditService: SiteLinkAuditService = SiteLinkAuditService()
  ) {
    self.init(
      preflightService: preflightService,
      imageWorkbenchService: imageWorkbenchService,
      aiFixQueueService: aiFixQueueService,
      linkAuditService: linkAuditService,
      cache: ContentHealthReportCache()
    )
  }

  init(
    preflightService: PreflightCheckService = PreflightCheckService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    aiFixQueueService: AIPublishingFixQueueService = AIPublishingFixQueueService(),
    linkAuditService: SiteLinkAuditService = SiteLinkAuditService(),
    cache: ContentHealthReportCache
  ) {
    self.preflightService = preflightService
    self.imageWorkbenchService = imageWorkbenchService
    self.aiFixQueueService = aiFixQueueService
    self.linkAuditService = linkAuditService
    self.cache = cache
    self.cacheNamespace = UUID()
  }

  /// Internal counters keep focused cache tests from relying on result equality
  /// alone. The report result itself never depends on the cache being available.
  var cacheStatistics: ContentHealthReportCacheStatistics {
    cache.statistics
  }

  public func report(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation]
  ) -> ContentHealthReport {
    makeReport(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: sitePreflightIssues,
      presentations: presentations,
      linkAuditReport: linkAuditService.report(drafts: drafts, profile: profile),
      cancellationCheck: {}
    )
  }

  private func makeReport(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation],
    linkAuditReport: SiteLinkAuditReport,
    cancellationCheck: () throws -> Void
  ) rethrows -> ContentHealthReport {
    try cancellationCheck()
    let duplicateIndex = PreflightDuplicateIndex(drafts: drafts, profile: profile)
    let linkIssuesByDraftID = linkPreflightIssues(
      report: linkAuditReport,
      drafts: drafts
    )
    cache.prune(keepingDraftIDs: Set(drafts.map(\.id)))
    var draftSummaries: [DraftPreflightSummary] = []
    draftSummaries.reserveCapacity(drafts.count)
    for draft in drafts {
      try cancellationCheck()
      let presentation = presentations[draft.id] ?? ContentHealthDraftPresentation(
        title: draft.title,
        markdownPath: profile.markdownPath(for: draft)
      )
      let cacheKey = ContentHealthReportCacheKey.make(
        draft: draft,
        profile: profile,
        presentation: presentation,
        hasDuplicateTitle: duplicateIndex.hasDuplicateTitle(for: draft.id) ?? false,
        hasDuplicatePath: duplicateIndex.hasDuplicatePath(for: draft.id) ?? false,
        serviceNamespace: cacheNamespace
      )
      if let cachedSummary = cache.lookup(cacheKey) {
        draftSummaries.append(
          addingLinkIssues(linkIssuesByDraftID[draft.id] ?? [], to: cachedSummary)
        )
        continue
      }

      let preflightIssues = preflightService.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        includeRepositoryReadiness: false,
        duplicateIndex: duplicateIndex
      )
      let imageReport = imageWorkbenchService.report(draft: draft, profile: profile)
      let imageIssues = imageReport.issues
        .filter { !$0.isCovered(by: preflightIssues) }
        .compactMap(\.preflightIssue)
      let summary = DraftPreflightSummary(
        draftID: draft.id,
        draftTitle: presentation.title,
        markdownPath: presentation.markdownPath,
        issues: merge(preflightIssues: preflightIssues, imageIssues: imageIssues)
      )
      draftSummaries.append(
        addingLinkIssues(linkIssuesByDraftID[draft.id] ?? [], to: summary)
      )
      if let cacheKey {
        cache.insert(summary, for: cacheKey)
      }
    }
    try cancellationCheck()
    let publicRiskSummary = ContentHealthProjection.publicRiskSummary(from: draftSummaries)
    let aiFixQueueItems = aiFixQueueService.items(drafts: drafts, profile: profile, summaries: draftSummaries)
    try cancellationCheck()

    return ContentHealthReport(
      sitePreflightIssues: sitePreflightIssues,
      draftSummaries: draftSummaries,
      publicRiskSummary: publicRiskSummary,
      publicRiskDraftSummaries: ContentHealthProjection.publicRiskDraftSummaries(from: draftSummaries),
      aiFixQueueItems: aiFixQueueItems
    )
  }

  public func reportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation]
  ) async throws -> ContentHealthReport {
    let linkAuditReport = try await linkAuditService.reportAsync(
      drafts: drafts,
      profile: profile
    )
    let task = Task.detached(priority: .utility) {
      try makeReport(
        drafts: drafts,
        profile: profile,
        sitePreflightIssues: sitePreflightIssues,
        presentations: presentations,
        linkAuditReport: linkAuditReport,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func merge(
    preflightIssues: [PreflightIssue],
    imageIssues: [PreflightIssue]
  ) -> [PreflightIssue] {
    guard !imageIssues.isEmpty else { return preflightIssues }

    var merged = preflightIssues.filter { $0.title != CoreL10n.text("检查通过") }
    for imageIssue in imageIssues {
      merged.append(imageIssue)
    }
    return merged.sorted {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
  }

  private func linkPreflightIssues(
    report: SiteLinkAuditReport,
    drafts: [ArticleDraft]
  ) -> [UUID: [PreflightIssue]] {
    Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in
      let issues = report.preflightIssues(for: draft)
      return issues.isEmpty ? nil : (draft.id, issues)
    })
  }

  private func addingLinkIssues(
    _ linkIssues: [PreflightIssue],
    to summary: DraftPreflightSummary
  ) -> DraftPreflightSummary {
    guard !linkIssues.isEmpty else { return summary }
    var issues = summary.issues.filter { $0.title != CoreL10n.text("检查通过") }
    issues.append(contentsOf: linkIssues)
    issues.sort {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
    return DraftPreflightSummary(
      draftID: summary.draftID,
      draftTitle: summary.draftTitle,
      markdownPath: summary.markdownPath,
      issues: issues
    )
  }

}
