import Foundation

extension WorkbenchAIStore {
  public func seoInspectorPresentation(
    for draft: ArticleDraft
  ) async throws -> WorkbenchSEOInspectorPresentation {
    let profile = store.profile(for: draft)
    let repositoryRevision = store.repositoryReportRevision
    let cachedSnapshot = seoSocialPreviewSnapshots[draft.id]
    let relatedSuggestions = store.relatedArticleSuggestions(for: draft, limit: 3)
    let actionMessage = seoSocialPreviewMessage
    let auditService = seoAuditService
    let previewService = seoSocialPreviewService
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let themeTitleH1Resolution = await profile.resolveThemeTitleH1(
        repositoryRevision: repositoryRevision
      )
      var resolvedProfile = profile
      // Pass the resolved fact into this immutable audit snapshot without
      // changing the user's independent duplicate-warning preference.
      resolvedProfile.themeProvidesTitleH1 = themeTitleH1Resolution.providesTitleH1
      try Task.checkCancellation()
      let report = auditService.report(draft: draft, profile: resolvedProfile)
      try Task.checkCancellation()
      let currentSnapshot = previewService.snapshot(draft: draft, profile: profile)
      try Task.checkCancellation()
      return WorkbenchSEOInspectorPresentation(
        draftID: draft.id,
        report: report,
        themeTitleH1Resolution: themeTitleH1Resolution,
        socialPreviewSnapshot: cachedSnapshot,
        cachePresentation: SEOSocialPreviewCachePresentation(
          snapshot: cachedSnapshot,
          isStale: cachedSnapshot?.signature != currentSnapshot.signature
        ),
        relatedArticleSuggestions: relatedSuggestions,
        actionMessage: actionMessage
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
