import Foundation

public struct ContentHealthReportService: Sendable {
  private let preflightService: PreflightCheckService
  private let aiFixQueueService: AIPublishingFixQueueService

  public init(
    preflightService: PreflightCheckService = PreflightCheckService(),
    aiFixQueueService: AIPublishingFixQueueService = AIPublishingFixQueueService()
  ) {
    self.preflightService = preflightService
    self.aiFixQueueService = aiFixQueueService
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
      cancellationCheck: {}
    )
  }

  private func makeReport(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation],
    cancellationCheck: () throws -> Void
  ) rethrows -> ContentHealthReport {
    try cancellationCheck()
    let duplicateIndex = PreflightDuplicateIndex(drafts: drafts, profile: profile)
    var draftSummaries: [DraftPreflightSummary] = []
    draftSummaries.reserveCapacity(drafts.count)
    for draft in drafts {
      try cancellationCheck()
      let presentation = presentations[draft.id] ?? ContentHealthDraftPresentation(
        title: draft.title,
        markdownPath: profile.markdownPath(for: draft)
      )
      draftSummaries.append(DraftPreflightSummary(
        draftID: draft.id,
        draftTitle: presentation.title,
        markdownPath: presentation.markdownPath,
        issues: preflightService.run(
          draft: draft,
          allDrafts: drafts,
          profile: profile,
          includeRepositoryReadiness: false,
          duplicateIndex: duplicateIndex
        )
      ))
    }
    try cancellationCheck()
    let publicRiskSummary = PublicRiskSummary(issues: draftSummaries.flatMap(\.issues))
    let aiFixQueueItems = aiFixQueueService.items(drafts: drafts, profile: profile, summaries: draftSummaries)
    try cancellationCheck()

    return ContentHealthReport(
      sitePreflightIssues: sitePreflightIssues,
      draftSummaries: draftSummaries,
      publicRiskSummary: publicRiskSummary,
      publicRiskDraftSummaries: draftSummaries.filter { !$0.publicRiskIssues.isEmpty },
      aiFixQueueItems: aiFixQueueItems
    )
  }

  public func reportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation]
  ) async throws -> ContentHealthReport {
    let task = Task.detached(priority: .utility) {
      try makeReport(
        drafts: drafts,
        profile: profile,
        sitePreflightIssues: sitePreflightIssues,
        presentations: presentations,
        cancellationCheck: { try Task.checkCancellation() }
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
