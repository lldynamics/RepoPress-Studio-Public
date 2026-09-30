import Foundation

extension PublishingStore {
  func markRemotePublishReviewSuccess(
    packages: [PublishPackage],
    profile: SiteProfile,
    submittedPackage: PublishPackage? = nil
  ) {
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    let updatedDrafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id],
        let submittedContent = submittedMarkdownContent(
          for: package, in: submittedPackage),
        draftStillMatchesPublishedTarget(draft, package: package, profile: profile)
      else {
        return draft
      }
      var updatedDraft = draft
      updatedDraft.markRepositoryAwaitingReview(
        profile: profile,
        submittedContentDigest: ArticleDraft.repositoryDocumentDigest(submittedContent)
      )
      guard updatedDraft != draft else { return draft }
      updatedDraft.markUpdated(at: draft.updatedAt, replacing: draft)
      return updatedDraft
    }
    if updatedDrafts != drafts {
      drafts = updatedDrafts
    }
    for draftID in packagesByDraftID.keys {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  /// Aggregate conflict packages retain submitted bytes but not each draft's
  /// identity. Match those bytes back to the original per-draft Markdown path.
  private func submittedMarkdownContent(
    for sourcePackage: PublishPackage,
    in submittedPackage: PublishPackage?
  ) -> String? {
    guard let submittedPackage else { return sourcePackage.markdownFile?.content }
    let path = sourcePackage.markdownPath.normalizedRelativePath()
    let matchingFiles = submittedPackage.files.filter {
      $0.kind == .markdown && $0.operation == .upsert
        && $0.repositoryPath.normalizedRelativePath() == path
    }
    guard matchingFiles.count == 1 else { return nil }
    return matchingFiles[0].content
  }

  func confirmDirectRemotePublishLifecycle(
    packages: [PublishPackage],
    profile: SiteProfile,
    result: RemoteRepositoryPublishResult
  ) {
    guard result.mode == .directCommit else { return }
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    let now = Date()
    let updatedDrafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id],
        draftStillMatchesPublishedTarget(draft, package: package, profile: profile)
      else {
        return draft
      }
      var updated = draft
      updated.attachments = updated.attachments.map { attachment in
        guard let remoteVersion = result.remoteVersion(for: attachment.repositoryPath) else {
          return attachment
        }
        var confirmedAttachment = attachment
        confirmedAttachment.repositorySHA = remoteVersion
        return confirmedAttachment
      }
      let confirmedPath = package.markdownPath.normalizedRelativePath()
      if let publishedContent = package.markdownFile?.content,
        let remoteVersion = result.remoteVersion(for: package.markdownPath)
      {
        updated.confirmRepositoryBinding(
          profile: profile,
          repositoryPath: confirmedPath,
          remoteRevision: remoteVersion,
          renderedContentDigest: ArticleDraft.repositoryDocumentDigest(publishedContent),
          verifiedAt: now
        )
      }
      guard updated != draft else { return draft }
      updated.markUpdated(at: draft.updatedAt, replacing: draft)
      return updated
    }
    if updatedDrafts != drafts {
      drafts = updatedDrafts
    }
    for draftID in packagesByDraftID.keys {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  /// Content edits may continue during upload, but a draft moved to another
  /// site or the general library must never receive the old site's revisions.
  /// First-time remote publishes legitimately have no local binding yet.
  private func draftStillMatchesPublishedTarget(
    _ draft: ArticleDraft,
    package: PublishPackage,
    profile: SiteProfile
  ) -> Bool {
    guard draft.belongs(toSiteProfileID: profile.id) else { return false }
    let publishedPath = package.markdownPath.normalizedRelativePath()
    if let currentPath = draft.repositoryPath?.normalizedRelativePath(),
      currentPath != publishedPath
    {
      return false
    }
    if let binding = draft.repositoryBinding {
      return binding.identity == DraftRepositoryIdentity(profile: profile)
        && binding.repositoryPath.normalizedRelativePath() == publishedPath
    }
    return true
  }

}
