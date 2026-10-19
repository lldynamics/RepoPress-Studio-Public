import Foundation
import PublishingWorkbenchCore

/// A conservative projection of one article's current publication lifecycle.
/// Remote success is shown only for the exact profile, repository, path, and
/// rendered source digest that existing deployment evidence verified.
struct ArticlePublicationStatusPresentation: Equatable, Sendable {
  enum Stage: Equatable, Sendable {
    case draft
    case ready
    case pendingChanges
    case waitingForDeployment
    case verifyingArticle
    case verifiedOnline
    case needsAttention
  }

  let stage: Stage
  let title: String
  let detail: String
  let verifiedAt: Date?
  let onlineURL: URL?

  static func make(
    draft: ArticleDraft,
    profile: SiteProfile,
    currentSourceDigest: String?,
    records: [ReleaseRecord],
    snapshots: [UUID: DeploymentStatusSnapshot],
    now: Date = Date()
  ) -> Self {
    let matchingRecords = records.filter {
      matchesPublicationTarget(record: $0, draftID: draft.id, profile: profile)
    }
    guard let record = matchingRecords.max(by: { isEarlier($0, than: $1) }) else {
      return unpublished(draft: draft)
    }

    let currentPath = profile.markdownPath(for: draft)
    guard let currentSourceDigest,
      let target = record.articleVerificationTargets.first(where: {
        $0.draftID == draft.id
          && $0.markdownPath == currentPath
          && $0.sourceDocumentDigest?.caseInsensitiveCompare(currentSourceDigest)
            == .orderedSame
      })
    else {
      return Self(
        stage: .pendingChanges,
        title: String(localized: "有更新待发布"),
        detail: draft.title,
        verifiedAt: nil,
        onlineURL: nil
      )
    }

    guard
      let progress = ArticlePublishProgress.make(
        record: record,
        snapshot: snapshots[record.id],
        profile: profile,
        now: now
      )
    else {
      return Self(
        stage: .needsAttention,
        title: String(localized: "已推送，尚未确认上线"),
        detail: String(localized: "这次发布尚无文章版本核验记录，可在发布历史中重新检查。"),
        verifiedAt: nil, onlineURL: nil)
    }

    switch progress.phase {
    case .waitingForDeployment:
      return progressPresentation(
        stage: .waitingForDeployment,
        progress: progress
      )
    case .verifyingArticle:
      return progressPresentation(
        stage: .verifyingArticle,
        progress: progress
      )
    case .needsAttention:
      return progressPresentation(
        stage: .needsAttention,
        progress: progress
      )
    case .online:
      let snapshot = record.articlePublishTrackingRequest?.completedSnapshot ?? snapshots[record.id]
      guard let result = snapshot?.articleResults?.first(where: { $0.target == target }),
        snapshot?.verifiesArticle(target, in: record) == true
      else {
        return Self(
          stage: .needsAttention,
          title: String(localized: "已推送，尚未确认上线"),
          detail: progress.message,
          verifiedAt: nil,
          onlineURL: nil
        )
      }
      return Self(
        stage: .verifiedOnline,
        title: progress.title,
        detail: progress.message,
        verifiedAt: result.checkedAt,
        onlineURL: verifiedArticleURL(target.publicURLText)
      )
    }
  }

  private static func unpublished(draft: ArticleDraft) -> Self {
    let stage: Stage =
      draft.articleState == .draft || draft.articleState == .localOnly
      ? .draft : .ready
    return Self(
      stage: stage,
      title: stage == .draft ? String(localized: "草稿") : String(localized: "待发布"),
      detail: draft.title,
      verifiedAt: nil,
      onlineURL: nil
    )
  }

  private static func progressPresentation(
    stage: Stage,
    progress: ArticlePublishProgress
  ) -> Self {
    Self(
      stage: stage,
      title: progress.title,
      detail: progress.message,
      verifiedAt: nil,
      onlineURL: nil
    )
  }

  private static func matchesPublicationTarget(
    record: ReleaseRecord,
    draftID: UUID,
    profile: SiteProfile
  ) -> Bool {
    guard record.siteProfileID == profile.id,
      canChangePublishedArticle(record, targetBranch: profile.branch),
      record.draftID == draftID
        || record.articleVerificationTargets.contains(where: { $0.draftID == draftID }),
      let provider = record.repositoryProvider,
      let baseURL = record.repositoryBaseURL,
      let owner = record.repoOwner,
      let repository = record.repoName,
      let branch = record.targetBranch ?? record.branchName
    else { return false }
    return DraftRepositoryIdentity(
      provider: provider,
      baseURL: baseURL,
      owner: owner,
      repository: repository,
      branch: branch
    ) == DraftRepositoryIdentity(profile: profile)
  }

  private static func canChangePublishedArticle(_ record: ReleaseRecord, targetBranch: String)
    -> Bool
  {
    switch record.kind {
    case .remoteDirectCommit, .remoteRollback:
      return true
    case .remotePublishFailure:
      return record.deploymentCommitSHA != nil && record.branchName == targetBranch
        && (record.targetBranch == nil || record.targetBranch == targetBranch)
    case .remoteReviewRequest:
      return record.reviewStatus?.state == .merged && record.deploymentCommitSHA != nil
        && record.reviewStatus?.targetBranch == targetBranch
    default:
      return false
    }
  }

  private static func isEarlier(_ lhs: ReleaseRecord, than rhs: ReleaseRecord) -> Bool {
    let leftDate = publicationObservationDate(lhs)
    let rightDate = publicationObservationDate(rhs)
    return leftDate == rightDate
      ? lhs.id.uuidString < rhs.id.uuidString
      : leftDate < rightDate
  }

  private static func publicationObservationDate(_ record: ReleaseRecord) -> Date {
    // A review can merge long after it was opened. Without a merge timestamp,
    // conservatively use when the accepted merge was observed, not creation.
    guard record.kind == .remoteReviewRequest, let review = record.reviewStatus,
      review.state == .merged
    else { return record.createdAt }
    return max(record.createdAt, review.checkedAt)
  }

  private static func verifiedArticleURL(_ text: String?) -> URL? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil
    else { return nil }
    return url
  }
}
