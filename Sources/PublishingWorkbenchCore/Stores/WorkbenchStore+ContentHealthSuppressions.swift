import Foundation

extension WorkbenchStore {
  /// Applies 站点检查 suppressions to one article's publish checklist so both
  /// places count the same findings. Only optional warnings can match; errors
  /// and public-risk findings never do, so nothing that blocks publishing is
  /// hidden.
  public func isSuppressedInContentHealth(_ issue: PreflightIssue, draft: ArticleDraft) -> Bool {
    let profile = profile(for: draft)
    guard !(profile.contentHealthSuppressions ?? []).isEmpty else { return false }
    var candidate = issue
    // The health report tags link findings with their rule and evidence; the
    // publish preflight merges the same findings untagged. Use the cached
    // audit only: without it the finding simply stays visible.
    if candidate.ruleID == nil,
      candidate.category == .brokenInternalLink || candidate.category == .unreachableExternalLink
    {
      let siteDrafts =
        drafts
        .filter { $0.belongs(toSiteProfileID: draft.siteProfileID) }
        .sorted { $0.id.uuidString < $1.id.uuidString }
      guard let report = cachedSiteLinkAuditReport(drafts: siteDrafts, profile: profile) else {
        return false
      }
      candidate = ContentHealthSuppressionPolicy.linkIssue(
        candidate, draftID: draft.id, report: report)
    }
    return ContentHealthSuppressionPolicy.isSuppressed(candidate, draft: draft, profile: profile)
  }

  public func isSuppressedInContentHealth(
    _ issue: ImageWorkbenchIssue, report: ImageWorkbenchReport, draft: ArticleDraft
  ) -> Bool {
    guard let preflight = ContentHealthSuppressionPolicy.imageIssue(issue, report: report) else {
      return false
    }
    return isSuppressedInContentHealth(preflight, draft: draft)
  }

  public var contentHealthSuppressions: [ContentHealthSuppression] {
    (activeProfile.contentHealthSuppressions ?? []).filter { $0.profileID == activeProfileID }
  }

  /// Resolve from the current report rather than trusting UI-provided fields or scan IDs.
  @discardableResult
  public func suppressContentHealthIssue(
    _ issue: PreflightIssue, draftID: UUID, profileID: UUID,
    mode: ContentHealthSuppressionMode, expectedVersion: Int
  ) -> Bool {
    guard profileID == activeProfileID, expectedVersion == contentHealthSnapshotVersion,
      issue.canSuppressInContentHealth,
      let occurrence = currentContentHealthOccurrences().first(where: {
        $0.draftID == draftID && $0.issue.ruleID == issue.ruleID
          && $0.issue.relatedValue == issue.relatedValue
      }), let rule = occurrence.suppression(profileID: profileID, mode: mode)
    else { return false }
    return commitContentHealthSuppressions(contentHealthSuppressions + [rule])
  }

  /// Freeze all current optional findings. New or changed fingerprints remain visible.
  @discardableResult
  public func saveContentHealthBaseline(profileID: UUID, expectedVersion: Int) -> Bool {
    guard profileID == activeProfileID, expectedVersion == contentHealthSnapshotVersion else {
      return false
    }
    let baseline = currentContentHealthOccurrences().compactMap {
      $0.suppression(profileID: profileID, mode: .baseline)
    }
    guard !baseline.isEmpty else { return false }
    return commitContentHealthSuppressions(contentHealthSuppressions + baseline)
  }

  @discardableResult
  public func restoreContentHealthSuppression(_ suppression: ContentHealthSuppression) -> Bool {
    guard suppression.profileID == activeProfileID,
      contentHealthSuppressions.contains(suppression)
    else { return false }
    return commitContentHealthSuppressions(
      contentHealthSuppressions.filter { $0.id != suppression.id })
  }

  @discardableResult
  public func restoreAllContentHealthSuppressions(profileID: UUID) -> Bool {
    guard profileID == activeProfileID, !contentHealthSuppressions.isEmpty else { return false }
    return commitContentHealthSuppressions([])
  }

  private func currentContentHealthOccurrences() -> [ContentHealthIssueOccurrence] {
    let report = contentHealthReport
    let draftsByID = Dictionary(
      visibleDrafts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    return report.draftSummaries.flatMap { summary in
      guard let draft = draftsByID[summary.draftID], draft.siteProfileID == activeProfileID else {
        return [] as [ContentHealthIssueOccurrence]
      }
      return summary.issues.filter(\.canSuppressInContentHealth).map {
        ContentHealthIssueOccurrence(issue: $0, draft: draft, draftTitle: summary.draftTitle)
      }
    }
  }

  private func commitContentHealthSuppressions(_ suppressions: [ContentHealthSuppression]) -> Bool {
    var profile = activeProfile
    var seen = Set<String>()
    profile.contentHealthSuppressions = suppressions.filter { seen.insert($0.id).inserted }
    if profile.contentHealthSuppressions?.isEmpty == true {
      profile.contentHealthSuppressions = nil
    }
    return commitActiveProfileSynchronously(profile)
  }
}
