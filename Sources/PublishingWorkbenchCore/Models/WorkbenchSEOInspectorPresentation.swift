import Foundation

/// Immutable, draft-scoped data consumed by the SEO Inspector. Expensive body
/// scans and cover metadata inspection are prepared away from SwiftUI's body.
public struct WorkbenchSEOInspectorPresentation: Sendable {
  public let draftID: UUID
  public let report: SEOAuditReport
  public let socialPreviewSnapshot: SEOSocialPreviewSnapshot?
  public let cachePresentation: SEOSocialPreviewCachePresentation
  public let relatedArticleSuggestions: [SiteRelationSuggestion]
  public let actionMessage: String?

  public init(
    draftID: UUID,
    report: SEOAuditReport,
    socialPreviewSnapshot: SEOSocialPreviewSnapshot?,
    cachePresentation: SEOSocialPreviewCachePresentation,
    relatedArticleSuggestions: [SiteRelationSuggestion],
    actionMessage: String?
  ) {
    self.draftID = draftID
    self.report = report
    self.socialPreviewSnapshot = socialPreviewSnapshot
    self.cachePresentation = cachePresentation
    self.relatedArticleSuggestions = relatedArticleSuggestions
    self.actionMessage = actionMessage
  }
}
