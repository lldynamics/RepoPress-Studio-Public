import Foundation

/// The atomic destination named by a publish-readiness finding. This remains
/// independent of SwiftUI so every caller can make the same routing decision.
public enum PublishReadinessTarget: Equatable, Sendable {
  case body(query: String?)
  case metadata(field: String?)
  case images(attachmentID: UUID?)
  case seo
  case repository

  public static func preflight(_ issue: PreflightIssue) -> Self {
    let bodyQuery =
      issue.structuredField == .body && issue.category == .unregisteredBodyImage
      ? issue.relatedValue
      : nil
    return field(issue.field, bodyQuery: bodyQuery)
  }

  public static func image(_ issue: ImageWorkbenchIssue) -> Self {
    if let id = issue.attachmentID { return .images(attachmentID: id) }
    if issue.preflightIssue?.structuredField == .body {
      return .body(query: issue.relatedValue)
    }
    return .images(attachmentID: nil)
  }

  public static func seo(_ finding: SEOAuditFinding) -> Self {
    guard finding.field != nil else { return .seo }
    return field(finding.field)
  }

  private static func field(_ field: String?, bodyQuery: String? = nil) -> Self {
    switch field.flatMap(PreflightIssueField.init(rawValue:)) {
    case .body: return .body(query: bodyQuery)
    case .attachments, .cover, .coverAlt: return .images(attachmentID: nil)
    case .repository, .repositoryPath, .repositoryToken, .contentRoot,
      .assetRoot, .markdownPathPattern, .siteKind:
      return .repository
    case .jsonLD: return .seo
    default: return .metadata(field: field)
    }
  }
}

/// The workspace-level consequence of a readiness target. Article repair
/// always keeps the selected draft in Writing; only repository configuration
/// belongs in the Site workspace.
public enum ArticlePublishRepairRoute: Equatable, Sendable {
  case article(PublishReadinessTarget)
  case repository

  public var workspaceSection: WorkspaceSection {
    switch self {
    case .article:
      return .writing
    case .repository:
      return .sync
    }
  }

  public var keepsArticleContext: Bool {
    if case .article = self { return true }
    return false
  }
}

public enum ArticlePublishRepairRoutePolicy {
  public static func route(for target: PublishReadinessTarget) -> ArticlePublishRepairRoute {
    switch target {
    case .repository:
      return .repository
    case .body, .metadata, .images, .seo:
      return .article(target)
    }
  }
}
