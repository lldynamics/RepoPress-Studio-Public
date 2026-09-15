import Foundation

/// Read-only publishing projections. Mutation and publish completion stay in PublishActions.
extension PublishingStore {
  public func publishingPackage(for draft: ArticleDraft, store: WorkbenchStore) -> PublishPackage {
    publishPackageBuilder.build(draft: draft, profile: store.profile(for: draft))
  }

  public func localPublishPreview(for draft: ArticleDraft, store: WorkbenchStore)
    -> LocalPublishPreview
  {
    let package = publishingPackage(for: draft, store: store)
    return localPublishPreviewService.preview(package: package, profile: store.profile(for: draft))
  }

  public func remoteReviewDraft(for draft: ArticleDraft, store: WorkbenchStore) -> RemoteReviewDraft
  {
    remoteReviewDraftBuilder.build(
      package: publishingPackage(for: draft, store: store), profile: store.profile(for: draft))
  }

  public func draftComparisonContent(for draft: ArticleDraft, store: WorkbenchStore)
    -> DraftComparisonContent
  {
    let package = publishingPackage(for: draft, store: store)
    return DraftComparisonContent(
      repositoryPath: package.markdownPath,
      localContent: package.markdownFile?.content
    )
  }

  public func publishingAIPrompt(for draft: ArticleDraft, store: WorkbenchStore) -> String {
    let profile = store.profile(for: draft)
    let package = publishingPackage(for: draft, store: store)
    let issues =
      preflightIssues(for: draft, store: store)
      + remotePublishRiskService.issues(
        package: package,
        repositoryReport: store.repositoryReport(for: profile)
      )
    let localPreview = localPublishPreview(for: draft, store: store)
    let sitePreview = localSitePreviewPlan(for: draft, store: store)
    let imageReport = store.imageWorkbenchReport(for: draft)
    let reviewDraft = remoteReviewDraft(for: draft, store: store)
    return PublishingAIPromptRenderer.render(
      draft: draft,
      profile: profile,
      package: package,
      issues: issues,
      localPreview: localPreview,
      sitePreview: sitePreview,
      imageReport: imageReport,
      reviewDraft: reviewDraft
    )
  }

  func publishingAIPrompt(
    from artifacts: AIPublishingRequestArtifacts,
    store: WorkbenchStore
  ) -> String {
    let issues =
      artifacts.preflightIssues
      + remotePublishRiskService.issues(
        package: artifacts.publishPackage,
        repositoryReport: store.repositoryReport(for: artifacts.profile)
      )
    return PublishingAIPromptRenderer.render(
      draft: artifacts.draft,
      profile: artifacts.profile,
      package: artifacts.publishPackage,
      issues: issues,
      localPreview: artifacts.workflowContext.publishPreview,
      sitePreview: artifacts.workflowContext.localSitePreviewPlan,
      imageReport: artifacts.workflowContext.imageReport,
      reviewDraft: artifacts.remoteReviewDraft
    )
  }

  public func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool = true,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    if draft.isGeneralDraft {
      return [generalDraftPublishingIssue]
    }
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: draft.siteProfileID) }
    let profile = store.profile(for: draft)
    let baseIssues = preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness
    )
    return store.localSiteLinkAuditReport(
      drafts: allDrafts,
      profile: profile
    ).mergingPreflightIssues(baseIssues, for: draft)
  }

  func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool,
    allDrafts: [ArticleDraft],
    duplicateIndex: PreflightDuplicateIndex,
    linkAuditReport: SiteLinkAuditReport? = nil,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    if draft.isGeneralDraft {
      return [generalDraftPublishingIssue]
    }
    let profile = store.profile(for: draft)
    let baseIssues = preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness,
      duplicateIndex: duplicateIndex
    )
    let resolvedLinkAuditReport =
      linkAuditReport
      ?? store.localSiteLinkAuditReport(drafts: allDrafts, profile: profile)
    return resolvedLinkAuditReport.mergingPreflightIssues(baseIssues, for: draft)
  }

  public func sitePreflightIssues(store: WorkbenchStore) -> [PreflightIssue] {
    let profile = store.activeProfile
    guard profile.purpose.requiresRepositoryReadiness else { return [] }
    if profile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      return [
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("未选择本地仓库"),
          message: profile.purpose.repositoryRootMissingMessage,
          field: "repository"
        )
      ]
    }
    return store.repositoryReport(for: profile)?.preflightIssues(
      requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
    ) ?? []
  }

  public func contentHealthSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    contentHealthReport(store: store).draftSummaries
  }

  public func contentHealthReport(store: WorkbenchStore) -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    return contentHealthReportService.report(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: sitePreflightIssues(store: store),
      presentations: contentHealthPresentations(store: store),
      linkAuditReport: store.localSiteLinkAuditReport(
        drafts: drafts,
        profile: profile
      )
    )
  }

  public func contentHealthReportAsync(store: WorkbenchStore) async throws -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let siteIssues = sitePreflightIssues(store: store)
    let presentations = contentHealthPresentations(store: store)
    let linkAuditReport = try await store.localSiteLinkAuditReportAsync(
      drafts: drafts,
      profile: profile
    )
    return try await contentHealthReportService.reportAsync(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: siteIssues,
      presentations: presentations,
      linkAuditReport: linkAuditReport,
      validatesExternalLinks: false
    )
  }

  private func contentHealthPresentations(store: WorkbenchStore) -> [UUID:
    ContentHealthDraftPresentation]
  {
    Dictionary(
      uniqueKeysWithValues: store.visibleDrafts.map { draft in
        let display = store.privateContentDisplay(for: draft)
        let markdownPath =
          display.isMasked
          ? "内容已遮挡，打开文章或关闭私密遮挡后查看。"
          : store.profile(for: draft).markdownPath(for: draft)
        return (
          draft.id, ContentHealthDraftPresentation(title: display.title, markdownPath: markdownPath)
        )
      })
  }

  public func publicRiskSummary(store: WorkbenchStore) -> PublicRiskSummary {
    ContentHealthProjection.publicRiskSummary(from: publicRiskDraftSummaries(store: store))
  }

  public func publicRiskSummary(for draft: ArticleDraft, store: WorkbenchStore) -> PublicRiskSummary
  {
    let summary = DraftPreflightSummary(
      draftID: draft.id,
      draftTitle: draft.title,
      markdownPath: store.profile(for: draft).markdownPath(for: draft),
      issues: preflightIssues(for: draft, includeRepositoryReadiness: false, store: store)
    )
    return ContentHealthProjection.publicRiskSummary(from: [summary])
  }

  public func publicRiskDraftSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: profile.id) }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
    let linkAuditReport = store.localSiteLinkAuditReport(
      drafts: allDrafts,
      profile: profile
    )
    return drafts.map {
      DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: $0.title,
        markdownPath: store.profile(for: $0).markdownPath(for: $0),
        issues: preflightIssues(
          for: $0,
          includeRepositoryReadiness: false,
          allDrafts: allDrafts,
          duplicateIndex: duplicateIndex,
          linkAuditReport: linkAuditReport,
          store: store
        )
      )
    }
  }

  public func aiFixQueueItems(store: WorkbenchStore) -> [AIPublishingFixQueueItem] {
    aiFixQueueService.items(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      summaries: contentHealthSummaries(store: store)
    )
  }
}
