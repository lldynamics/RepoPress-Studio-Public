import Foundation

public enum PreflightSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
  case error
  case warning
  case info

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .error:
      return "错误"
    case .warning:
      return "警告"
    case .info:
      return "提示"
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

public struct PreflightIssue: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var severity: PreflightSeverity
  public var title: String
  public var message: String
  public var field: String?

  public init(
    id: UUID = UUID(),
    severity: PreflightSeverity,
    title: String,
    message: String,
    field: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.field = field
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
      return "公开风险阻塞"
    }
    if warningCount > 0 {
      return "公开风险待确认"
    }
    return "未发现公开风险"
  }

  public var statusMessage: String {
    if errorCount > 0 {
      return "发现疑似密钥、私钥或高风险公开内容，发布前需要移除。"
    }
    if warningCount > 0 {
      return "发现内网地址、本机路径等信息，公开前建议脱敏或确认。"
    }
    return "密钥、私钥、内网地址和本机路径规则没有命中。"
  }
}

public extension PreflightIssue {
  var isPublicRiskIssue: Bool {
    title.contains("疑似泄露")
      || title.contains("密钥泄露")
      || title.contains("私钥")
      || title.contains("公开风险")
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
