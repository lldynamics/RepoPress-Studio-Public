import Foundation

/// The complete publish-preview result for one immutable draft execution
/// context.  Keeping the context beside every derived value prevents a
/// preview produced for one draft or profile from being presented as another
/// draft's result while selection changes.
public struct DraftPublishPreviewSnapshot: Hashable, Sendable {
  public let context: DraftExecutionContext
  public let publishPackage: PublishPackage
  public let localPublishPreview: LocalPublishPreview
  public let localPublishReadiness: LocalPublishReadiness
  public let remotePublishPreview: RemoteRepositoryPublishPreview
  public let remoteReviewDraft: RemoteReviewDraft

  public init(
    context: DraftExecutionContext,
    publishPackage: PublishPackage,
    localPublishPreview: LocalPublishPreview,
    localPublishReadiness: LocalPublishReadiness,
    remotePublishPreview: RemoteRepositoryPublishPreview,
    remoteReviewDraft: RemoteReviewDraft
  ) {
    self.context = context
    self.publishPackage = publishPackage
    self.localPublishPreview = localPublishPreview
    self.localPublishReadiness = localPublishReadiness
    self.remotePublishPreview = remotePublishPreview
    self.remoteReviewDraft = remoteReviewDraft
  }

  /// Keeps the existing store property terminology available while the
  /// preview consumers migrate from the single-value projection.
  public var remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview {
    remotePublishPreview
  }

  /// A descriptive alias for callers that refer to the identity as an
  /// execution context rather than the shorter `context` label.
  public var executionContext: DraftExecutionContext {
    context
  }

  public init(
    context: DraftExecutionContext,
    publishPackage: PublishPackage,
    localPublishPreview: LocalPublishPreview,
    localPublishReadiness: LocalPublishReadiness,
    remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview,
    remoteReviewDraft: RemoteReviewDraft
  ) {
    self.init(
      context: context,
      publishPackage: publishPackage,
      localPublishPreview: localPublishPreview,
      localPublishReadiness: localPublishReadiness,
      remotePublishPreview: remotePublishPreviewSnapshot,
      remoteReviewDraft: remoteReviewDraft
    )
  }
}
