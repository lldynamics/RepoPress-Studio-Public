import Foundation

/// The publishing preflight remains untouched. This policy only projects the health report.
enum ContentHealthSuppressionPolicy {
  static func apply(
    summaries: [DraftPreflightSummary], draftsByID: [UUID: ArticleDraft], profile: SiteProfile
  ) -> (summaries: [DraftPreflightSummary], suppressedIssues: [ContentHealthIssueOccurrence]) {
    var suppressed: [ContentHealthIssueOccurrence] = []
    let rules = profile.contentHealthSuppressions ?? []
    // Fingerprints hash article bodies; skip all of it for sites without rules.
    guard !rules.isEmpty else { return (summaries, []) }
    let visible = summaries.map { summary in
      guard let draft = draftsByID[summary.draftID], draft.siteProfileID == profile.id else {
        return summary
      }
      var result = summary
      result.issues = summary.issues.filter { issue in
        guard issue.canSuppressInContentHealth else { return true }
        let occurrence = ContentHealthIssueOccurrence(
          issue: issue, draft: draft, draftTitle: summary.draftTitle
        )
        guard rules.contains(where: { $0.matches(occurrence, profileID: profile.id) }) else {
          return true
        }
        suppressed.append(occurrence)
        return false
      }
      return result
    }
    return (visible, suppressed)
  }

  /// Whether one finding of `draft` matches a site rule, using the same
  /// occurrence fingerprint as the health report.
  static func isSuppressed(
    _ issue: PreflightIssue, draft: ArticleDraft, profile: SiteProfile
  ) -> Bool {
    let rules = profile.contentHealthSuppressions ?? []
    guard !rules.isEmpty, draft.siteProfileID == profile.id,
      issue.canSuppressInContentHealth
    else { return false }
    let occurrence = ContentHealthIssueOccurrence(
      issue: issue, draft: draft, draftTitle: draft.title)
    return rules.contains { $0.matches(occurrence, profileID: profile.id) }
  }

  static func imageIssue(_ imageIssue: ImageWorkbenchIssue, report: ImageWorkbenchReport)
    -> PreflightIssue?
  {
    guard var issue = imageIssue.preflightIssue else { return nil }
    let rule: ContentHealthRuleID?
    switch imageIssue.kind {
    case .missingAltText: rule = .missingMediaAlt
    case .missingCaption: rule = .missingCaption
    case .largeFile: rule = .largeFile
    case .largeDimensions: rule = .largeDimensions
    case .unreferencedAttachment: rule = .unreferencedAttachment
    case .duplicateMarkdownReference: rule = .duplicateMarkdownReference
    case .missingCoverAttachment: rule = .missingCoverAttachment
    case .unregisteredMarkdownImage: rule = .unregisteredBodyImage
    default: rule = nil
    }
    issue.ruleID = rule?.rawValue
    let item = report.items.first { $0.attachmentID == imageIssue.attachmentID }
    issue.fingerprintContext = ContentHealthSuppression.key([
      imageIssue.kind.rawValue, imageIssue.attachmentID?.uuidString ?? "",
      String(item?.byteSize ?? 0), String(item?.dimensions?.width ?? 0),
      String(item?.dimensions?.height ?? 0), String(item?.duplicateReferenceCount ?? 0),
    ])
    return issue
  }

  static func linkIssue(_ original: PreflightIssue, draftID: UUID, report: SiteLinkAuditReport)
    -> PreflightIssue
  {
    var issue = original
    switch issue.category {
    case .brokenInternalLink: issue.ruleID = ContentHealthRuleID.brokenInternalLink.rawValue
    case .unreachableExternalLink:
      issue.ruleID = ContentHealthRuleID.unreachableExternalLink.rawValue
    default: return issue
    }
    let items = report.items.filter { $0.draftID == draftID && $0.target == issue.relatedValue }
    issue.fingerprintContext = ContentHealthSuppression.key(
      items.map { item in
        ContentHealthSuppression.key([
          item.kind.rawValue, item.target, String(item.statusCode ?? 0), item.finalTarget ?? "",
        ])
      }.sorted())
    return issue
  }
}
