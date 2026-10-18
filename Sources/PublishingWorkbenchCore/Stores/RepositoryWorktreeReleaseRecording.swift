import Foundation
import PublishingGitCore

extension ReleaseRecord {
  static func confirmedWorktreePush(
    result: RepositoryWorktreePublishResult,
    profile: SiteProfile,
    article: RepositoryWorktreeArticleVerificationTarget?,
    trackingRequested: Bool = false,
    trackingRequest: ArticlePublishTrackingRequest? = nil
  ) -> ReleaseRecord? {
    guard result.pushed, result.remoteCommitSHA == result.commitSHA else { return nil }
    let target = article.flatMap { result.committedPaths.contains($0.markdownPath) ? $0 : nil }
    let request = target.flatMap { _ in
      trackingRequest ?? (trackingRequested ? ArticlePublishTrackingRequest(profile: profile) : nil)
    }
    return ReleaseRecord(
      kind: .remoteDirectCommit,
      title: CoreL10n.text("仓库推送已确认"),
      summary: CoreL10n.text("Git 推送已确认；网站部署与文章页面尚待验证。"),
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: target?.draftID,
      draftTitle: target?.title,
      draftSummary: target?.summary,
      draftCoverAltText: target?.coverAltText,
      publicPath: target?.publicPath,
      publicURLText: target?.publicURLText,
      sourceDocumentDigest: target?.sourceDocumentDigest,
      markdownPath: target?.markdownPath,
      changedPaths: result.committedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branch,
      targetBranch: result.branch,
      commitSHA: result.commitSHA,
      articlePublishTrackingRequest: request,
      localWriteResolutionCutoff: request?.startedAt
    )
  }
}

extension WorkbenchStore {
  func recordConfirmedWorktreePush(
    _ result: RepositoryWorktreePublishResult,
    profile: SiteProfile,
    article: RepositoryWorktreeArticleVerificationTarget?,
    trackingRequested: Bool = false,
    trackingRequest: ArticlePublishTrackingRequest? = nil
  ) {
    guard
      let record = ReleaseRecord.confirmedWorktreePush(
        result: result, profile: profile, article: article, trackingRequested: trackingRequested,
        trackingRequest: trackingRequest)
    else {
      return
    }
    if let article, let blobOID = article.repositoryBlobOID,
      let digest = article.sourceDocumentDigest,
      result.committedPaths.contains(article.markdownPath),
      let index = publishingStore.drafts.firstIndex(where: {
        $0.id == article.draftID && $0.belongs(toSiteProfileID: profile.id)
          && $0.repositoryPath?.normalizedRelativePath() == article.markdownPath
          && ($0.repositoryBinding?.identity == nil
            || $0.repositoryBinding?.identity == DraftRepositoryIdentity(profile: profile))
      })
    {
      publishingStore.drafts[index].confirmRepositoryBinding(
        profile: profile, repositoryPath: article.markdownPath,
        remoteRevision: blobOID, renderedContentDigest: digest)
    }
    guard
      !releaseRecords.contains(where: {
        $0.siteProfileID == profile.id && $0.commitSHA == result.commitSHA
          && $0.kind == .remoteDirectCommit
      })
    else { return }
    publishingStore.prependReleaseRecord(record)
    save()
    resumeArticlePublishTracking()
  }
}

extension RepositoryWorktreeArticleVerificationTarget {
  static func capture(
    draft: ArticleDraft?, profile: SiteProfile, snapshot: RepositoryWorktreePublishSnapshot
  ) -> Self? {
    guard let draft, draft.belongs(toSiteProfileID: profile.id), !draft.draft,
      draft.visibility == .public,
      let path = draft.repositoryPath?.normalizedRelativePath(),
      let entry = snapshot.entries.first(where: { $0.path == path && $0.kind != .deleted }),
      let data = try? Data(
        contentsOf: URL(fileURLWithPath: snapshot.repositoryRoot).appendingPathComponent(path)),
      let document = String(data: data, encoding: .utf8),
      RepositoryWorktreeReviewService.frozenDataMatches(
        data, entry: entry, root: URL(fileURLWithPath: snapshot.repositoryRoot),
        git: GitCommandRunner()),
      ArticleDraft.repositoryDocumentDigest(document)
        == draft.renderedRepositoryContentDigest(profile: profile)
    else { return nil }
    let publicPath = SiteArticleURLResolver().relativeWebPath(
      from: path, profile: profile, permalink: draft.permalink)
    return Self(
      draftID: draft.id, title: draft.title, summary: draft.summary,
      coverAltText: draft.attachments.first(where: { $0.id == draft.coverAttachmentID })?.altText,
      markdownPath: path,
      publicPath: publicPath,
      publicURLText: DeploymentStatusService().publicArticleURL(
        profile: profile, publicPath: publicPath),
      sourceDocumentDigest: ArticleDraft.repositoryDocumentDigest(document),
      repositoryBlobOID: entry.blobOID
    )
  }
}
