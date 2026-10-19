import Foundation

/// A presentation and readiness classification layered over the persisted
/// three-level `PreflightSeverity`. The severity remains backward compatible;
/// this classification only identifies known, non-blocking optimizations.
public enum PublishCheckClassification: String, Codable, Hashable, Sendable {
  case blocking
  case warning
  case optionalOptimization
  case informational

  public static func classify(_ issue: PreflightIssue) -> Self {
    if issue.severity == .info { return .informational }
    if issue.isOptionalOptimization { return .optionalOptimization }
    return issue.severity == .error ? .blocking : .warning
  }

  public static func classify(_ issue: ImageWorkbenchIssue) -> Self {
    if issue.severity == .info { return .informational }
    if issue.isOptionalOptimization { return .optionalOptimization }
    return issue.severity == .error ? .blocking : .warning
  }

  public static func classify(_ finding: SEOAuditFinding) -> Self {
    if finding.severity == .info { return .informational }
    return finding.isOptionalOptimization ? .optionalOptimization : .blocking
  }
}

extension PreflightIssue {
  /// Only stable, explicitly reviewed rule IDs may be treated as optional.
  /// Unknown rules, errors, and public-risk findings remain actionable.
  public var isOptionalOptimization: Bool {
    guard severity != .error, category != .publicRisk, let ruleID else { return false }
    return Self.optionalOptimizationRuleIDs.contains(ruleID)
  }

  public static let optionalOptimizationRuleIDs: Set<String> = [
    ContentHealthRuleID.shortBody.rawValue,
    ContentHealthRuleID.slugFormat.rawValue,
    ContentHealthRuleID.missingCaption.rawValue,
    ContentHealthRuleID.largeFile.rawValue,
    ContentHealthRuleID.largeDimensions.rawValue,
    ContentHealthRuleID.unreferencedAttachment.rawValue,
    ContentHealthRuleID.duplicateMarkdownReference.rawValue,
    "content.title.duplicate",
    "content.title.missing",
    ContentHealthRuleID.missingMediaAlt.rawValue,
  ]
}

extension ImageWorkbenchIssue {
  public var isOptionalOptimization: Bool {
    guard severity != .error else { return false }
    switch kind {
    case .missingCaption, .largeFile, .largeDimensions, .unreferencedAttachment,
      .duplicateSource, .duplicateMarkdownReference:
      return true
    default:
      return false
    }
  }

  /// Converts an image finding while retaining its stable optimization rule
  /// identity for suppression and readiness counts.
  public var classifiedPreflightIssue: PreflightIssue? {
    guard var issue = preflightIssue else { return nil }
    issue.ruleID = imageRuleID
    return issue
  }

  private var imageRuleID: String? {
    switch kind {
    case .missingCaption: ContentHealthRuleID.missingCaption.rawValue
    case .largeFile: ContentHealthRuleID.largeFile.rawValue
    case .largeDimensions: ContentHealthRuleID.largeDimensions.rawValue
    case .unreferencedAttachment: ContentHealthRuleID.unreferencedAttachment.rawValue
    case .duplicateMarkdownReference: ContentHealthRuleID.duplicateMarkdownReference.rawValue
    default: nil
    }
  }
}

extension SEOAuditFinding {
  public var isOptionalOptimization: Bool {
    severity == .warning
  }
}
