import CryptoKit
import Foundation
import PublishingDomainContracts

/// A missing entry means the article has not expressed an image preference.
/// This explicit value is kept per site and draft so an absent cover is never
/// silently interpreted as an editorial decision.
public enum SEOArticleSocialImageIntent: String, Codable, Hashable, Sendable {
  case noIndividualImage
}

public struct SEOArticleSocialImagePreference: Codable, Hashable, Identifiable, Sendable {
  public let draftID: UUID
  public var intent: SEOArticleSocialImageIntent

  public var id: UUID { draftID }

  public init(draftID: UUID, intent: SEOArticleSocialImageIntent) {
    self.draftID = draftID
    self.intent = intent
  }
}

/// Only optional editorial findings enter this allowlist. Unknown rules fail closed.
public enum ContentHealthRuleID: String, Codable, CaseIterable, Sendable {
  case shortBody = "content.body.short"
  case draftFlag = "content.publication.draft"
  case futureDate = "content.date.future"
  case slugFormat = "content.slug.format"
  case missingMediaAlt = "content.media.missing-alt"
  case unregisteredBodyImage = "content.media.unregistered"
  case missingCaption = "content.media.missing-caption"
  case largeFile = "content.media.large-file"
  case largeDimensions = "content.media.large-dimensions"
  case unreferencedAttachment = "content.media.unreferenced"
  case duplicateMarkdownReference = "content.media.duplicate-reference"
  case missingCoverAttachment = "content.media.missing-cover"
  case brokenInternalLink = "content.link.internal-unresolved"
  case unreachableExternalLink = "content.link.external-unreachable"
}

public enum ContentHealthSuppressionMode: String, Codable, Sendable {
  case articleRule
  case siteRule
  case baseline
}

/// Stored on the owning SiteProfile; identifiers never depend on UI copy or scan UUIDs.
public struct ContentHealthSuppression: Codable, Hashable, Identifiable, Sendable {
  public let profileID: UUID
  public let draftID: UUID?
  public let ruleID: String
  public let mode: ContentHealthSuppressionMode
  public let fingerprint: String?

  public var id: String {
    Self.key([
      profileID.uuidString, draftID?.uuidString ?? "", ruleID, mode.rawValue, fingerprint ?? "",
    ])
  }

  public init(
    profileID: UUID,
    draftID: UUID? = nil,
    ruleID: String,
    mode: ContentHealthSuppressionMode,
    fingerprint: String? = nil
  ) {
    self.profileID = profileID
    self.draftID = draftID
    self.ruleID = ruleID
    self.mode = mode
    self.fingerprint = fingerprint
  }

  public func matches(_ occurrence: ContentHealthIssueOccurrence, profileID: UUID) -> Bool {
    guard self.profileID == profileID,
      occurrence.issue.canSuppressInContentHealth,
      ruleID == occurrence.issue.ruleID
    else { return false }
    switch mode {
    case .siteRule:
      return draftID == nil && fingerprint == nil
    case .articleRule:
      return draftID == occurrence.draftID && draftID != nil && fingerprint == nil
    case .baseline:
      return draftID == occurrence.draftID && fingerprint == occurrence.fingerprint
        && fingerprint?.isEmpty == false
    }
  }

  static func key(_ components: [String]) -> String {
    components.map { "\($0.utf8.count):\($0)" }.joined()
  }
}

public struct ContentHealthIssueOccurrence: Hashable, Identifiable, Sendable {
  public var issue: PreflightIssue
  public var draftID: UUID
  public var draftTitle: String
  public var fingerprint: String

  public var id: String {
    ContentHealthSuppression.key([draftID.uuidString, issue.ruleID ?? "", fingerprint])
  }

  public init(issue: PreflightIssue, draft: ArticleDraft, draftTitle: String) {
    self.issue = issue
    self.draftID = draft.id
    self.draftTitle = draftTitle
    // Use structured source values, never localized titles/messages or random issue IDs.
    // A body edit conservatively reopens findings in that body rather than hiding a new occurrence.
    let context: String
    switch issue.structuredField {
    case .body:
      context = draft.bodyMarkdown
    case .draft:
      context = String(draft.draft)
    case .date:
      context = String(draft.date.timeIntervalSince1970)
    case .slug:
      context = draft.slug
    case .attachments, .cover, .coverAlt:
      context = ContentHealthSuppression.key(
        draft.attachments.map { attachment in
          ContentHealthSuppression.key([
            attachment.id.uuidString, attachment.originalFilename, attachment.relativePublishPath,
            attachment.repositoryPath, attachment.altText, attachment.caption,
            String(attachment.byteSize), attachment.sourceFilePath ?? "",
            attachment.repositorySHA ?? "",
            attachment.remoteObjectKey ?? "", attachment.remoteURL ?? "",
            attachment.remoteETag ?? "",
          ])
        } + [draft.coverAttachmentID?.uuidString ?? "", draft.bodyMarkdown])
    default:
      context = ""
    }
    let evidence = ContentHealthSuppression.key([
      "1", issue.ruleID ?? "", issue.severity.rawValue, issue.field ?? "",
      issue.category?.rawValue ?? "", issue.code?.rawValue ?? "", issue.relatedValue ?? "",
      issue.fingerprintContext ?? "", context,
    ])
    fingerprint = Data(SHA256.hash(data: Data(evidence.utf8))).base64EncodedString()
  }

  public func suppression(profileID: UUID, mode: ContentHealthSuppressionMode)
    -> ContentHealthSuppression?
  {
    guard issue.canSuppressInContentHealth, let ruleID = issue.ruleID else { return nil }
    return ContentHealthSuppression(
      profileID: profileID,
      draftID: mode == .siteRule ? nil : draftID,
      ruleID: ruleID,
      mode: mode,
      fingerprint: mode == .baseline ? fingerprint : nil
    )
  }
}

extension PreflightIssue {
  public var canSuppressInContentHealth: Bool {
    guard severity != .error, !isPublicRiskIssue, !isSiteSetupIssue, code == nil,
      let ruleID, let rule = ContentHealthRuleID(rawValue: ruleID)
    else { return false }
    // Check fields and categories too: a rule identifier alone must never opt a
    // repository, path, security, or future unknown finding into suppression.
    switch rule {
    case .shortBody, .unregisteredBodyImage, .brokenInternalLink, .unreachableExternalLink:
      guard structuredField == .body else { return false }
    case .draftFlag:
      guard structuredField == .draft else { return false }
    case .futureDate:
      guard structuredField == .date else { return false }
    case .slugFormat:
      guard structuredField == .slug else { return false }
    case .missingMediaAlt, .missingCaption, .largeFile, .largeDimensions,
      .unreferencedAttachment, .missingCoverAttachment:
      guard structuredField == .attachments else { return false }
    case .duplicateMarkdownReference:
      guard structuredField == .body || structuredField == .attachments else { return false }
    }
    switch category {
    case .publicRisk, .missingMediaPublishPath, .unsafeMediaRepositoryPath, .slugRedirectCandidate:
      return false
    default:
      return true
    }
  }
}
