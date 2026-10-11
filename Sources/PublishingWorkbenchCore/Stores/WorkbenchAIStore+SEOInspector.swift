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
      var resolvedProfile = profile
      if resolvedProfile.warnsWhenBodyH1DuplicatesTitle == nil {
        resolvedProfile.warnsWhenBodyH1DuplicatesTitle =
          ThemeTitleH1Detector().cachedOrDetect(
            profile: profile, repositoryRevision: repositoryRevision) ?? true
      }
      try Task.checkCancellation()
      let report = auditService.report(draft: draft, profile: resolvedProfile)
      try Task.checkCancellation()
      let currentSnapshot = previewService.snapshot(draft: draft, profile: resolvedProfile)
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
