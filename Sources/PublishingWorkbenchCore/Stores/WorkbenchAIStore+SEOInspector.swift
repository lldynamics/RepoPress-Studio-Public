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
      if profile.warnsWhenBodyH1DuplicatesTitle == nil {
        _ = ThemeTitleH1Detector().cachedOrDetect(
          profile: profile, repositoryRevision: repositoryRevision)
      }
      try Task.checkCancellation()
      let report = auditService.report(draft: draft, profile: profile)
      try Task.checkCancellation()
      let currentSnapshot = previewService.snapshot(draft: draft, profile: profile)
      try Task.checkCancellation()
      return WorkbenchSEOInspectorPresentation(
        draftID: draft.id,
        report: report,
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
