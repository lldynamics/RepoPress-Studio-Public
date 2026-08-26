import Foundation

public enum PreflightSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
  case error
  case warning
  case info

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .error:
      return CoreL10n.text("错误")
    case .warning:
      return CoreL10n.text("警告")
    case .info:
      return CoreL10n.text("提示")
    }
  }

  public var sortRank: Int {
    switch self {
    case .error:
      return 0
    case .warning:
      return 1
    case .info:
      return 2
    }
  }
}

public enum PreflightIssueCategory: String, Codable, Hashable, Sendable {
  case publicRisk
  case missingMediaAlt
  case missingMediaPublishPath
  case unsafeMediaRepositoryPath
  case unregisteredBodyImage
  case brokenInternalLink
  case unreachableExternalLink
  case slugRedirectCandidate
}

public enum PreflightIssueField: String, Codable, Hashable, Sendable {
  case scope
  case title
  case slug
  case summary
  case tags
  case cover
  case coverAlt
  case date
  case draft
  case body
  case attachments
  case repository
  case repositoryPath
  case repositoryToken
  case contentRoot
  case assetRoot
  case markdownPathPattern
  case siteKind
  case jsonLD
}

public struct PreflightIssue: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var severity: PreflightSeverity
  public var title: String
  public var message: String
  public var field: String?
  public var category: PreflightIssueCategory?
  public var relatedValue: String?

  public init(
    id: UUID = UUID(),
    severity: PreflightSeverity,
    title: String,
    message: String,
    field: String? = nil,
    category: PreflightIssueCategory? = nil,
    relatedValue: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.field = field
    self.category = category
    self.relatedValue = relatedValue
  }
}

public struct PublicRiskSummary: Codable, Hashable, Sendable {
  public var issues: [PreflightIssue]

  public init(issues: [PreflightIssue]) {
    var seenKeys = Set<String>()
    self.issues = issues
      .filter(\.isPublicRiskIssue)
      .sorted {
        if $0.severity.sortRank == $1.severity.sortRank {
          return $0.title < $1.title
        }
        return $0.severity.sortRank < $1.severity.sortRank
      }
      .filter { issue in
        let key = "\(issue.severity.rawValue)|\(issue.title)|\(issue.field ?? "")"
        return seenKeys.insert(key).inserted
      }
  }

  public var issueCount: Int {
    issues.count
  }

  public var errorCount: Int {
    issues.filter { $0.severity == .error }.count
  }

  public var warningCount: Int {
    issues.filter { $0.severity == .warning }.count
  }

  public var isClear: Bool {
    issues.isEmpty
  }

  public var statusTitle: String {
    if errorCount > 0 {
      return CoreL10n.text("公开风险阻塞")
    }
    if warningCount > 0 {
      return CoreL10n.text("公开风险待确认")
    }
    return CoreL10n.text("未发现公开风险")
  }

  public var statusMessage: String {
    if errorCount > 0 {
      return CoreL10n.text("发现疑似密钥、私钥或高风险公开内容，发布前需要移除。")
    }
    if warningCount > 0 {
      return CoreL10n.text("发现内网地址、本机路径等信息，公开前建议脱敏或确认。")
    }
    return CoreL10n.text("密钥、私钥、内网地址和本机路径规则没有命中。")
  }
}

public extension PreflightIssue {
  var structuredField: PreflightIssueField? {
    field.flatMap(PreflightIssueField.init(rawValue:))
  }

  var isPublicRiskIssue: Bool {
    category == .publicRisk
  }
}

public struct DraftPreflightSummary: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }

  public var draftID: UUID
  public var draftTitle: String
  public var markdownPath: String
  public var issues: [PreflightIssue]

  public init(
    draftID: UUID,
    draftTitle: String,
    markdownPath: String,
    issues: [PreflightIssue]
  ) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.issues = issues
  }

  public var blockingIssues: [PreflightIssue] {
    issues.filter { $0.severity != .info }
  }

  public var publicRiskSummary: PublicRiskSummary {
    PublicRiskSummary(issues: issues)
  }

  public var publicRiskIssues: [PreflightIssue] {
    publicRiskSummary.issues
  }

  public var publicRiskErrorCount: Int {
    publicRiskSummary.errorCount
  }

  public var publicRiskWarningCount: Int {
    publicRiskSummary.warningCount
  }

  public var errorCount: Int {
    issues.filter { $0.severity == .error }.count
  }

  public var warningCount: Int {
    issues.filter { $0.severity == .warning }.count
  }

  public var isPassing: Bool {
    errorCount == 0 && warningCount == 0
  }
}

public struct ContentHealthReport: Sendable {
  public var sitePreflightIssues: [PreflightIssue]
  public var draftSummaries: [DraftPreflightSummary]
  public var publicRiskSummary: PublicRiskSummary
  public var publicRiskDraftSummaries: [DraftPreflightSummary]
  public var aiFixQueueItems: [AIPublishingFixQueueItem]

  public init(
    sitePreflightIssues: [PreflightIssue],
    draftSummaries: [DraftPreflightSummary],
    publicRiskSummary: PublicRiskSummary,
    publicRiskDraftSummaries: [DraftPreflightSummary],
    aiFixQueueItems: [AIPublishingFixQueueItem]
  ) {
    self.sitePreflightIssues = sitePreflightIssues
    self.draftSummaries = draftSummaries
    self.publicRiskSummary = publicRiskSummary
    self.publicRiskDraftSummaries = publicRiskDraftSummaries
    self.aiFixQueueItems = aiFixQueueItems
  }
}

public struct ContentHealthDraftPresentation: Hashable, Sendable {
  public var title: String
  public var markdownPath: String

  public init(title: String, markdownPath: String) {
    self.title = title
    self.markdownPath = markdownPath
  }
}
