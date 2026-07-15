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
    let duplicateIndex = PreflightDuplicateIndex(drafts: drafts, profile: profile)
    let draftSummaries = drafts.map { draft in
      let presentation = presentations[draft.id] ?? ContentHealthDraftPresentation(
        title: draft.title,
        markdownPath: profile.markdownPath(for: draft)
      )
      return DraftPreflightSummary(
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
      )
    }
    let publicRiskSummary = PublicRiskSummary(issues: draftSummaries.flatMap(\.issues))

    return ContentHealthReport(
      sitePreflightIssues: sitePreflightIssues,
      draftSummaries: draftSummaries,
      publicRiskSummary: publicRiskSummary,
      publicRiskDraftSummaries: draftSummaries.filter { !$0.publicRiskIssues.isEmpty },
      aiFixQueueItems: aiFixQueueService.items(drafts: drafts, profile: profile, summaries: draftSummaries)
    )
  }

  public func reportAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sitePreflightIssues: [PreflightIssue],
    presentations: [UUID: ContentHealthDraftPresentation]
  ) async -> ContentHealthReport {
    await Task.detached(priority: .utility) {
      report(
        drafts: drafts,
        profile: profile,
        sitePreflightIssues: sitePreflightIssues,
        presentations: presentations
      )
    }.value
  }
}
