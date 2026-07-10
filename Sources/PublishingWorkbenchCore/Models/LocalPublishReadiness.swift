import Foundation

public enum LocalPublishActionReadiness: String, Codable, Sendable {
  case ready
  case needsReview
  case blocked
  case unchanged

  public var displayName: String {
    switch self {
    case .ready:
      return "可执行"
    case .needsReview:
      return "需确认"
    case .blocked:
      return "已阻塞"
    case .unchanged:
      return "无变化"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle"
    case .needsReview:
      return "exclamationmark.triangle"
    case .blocked:
      return "xmark.octagon"
    case .unchanged:
      return "equal.circle"
    }
  }

  public var allowsAction: Bool {
    self == .ready || self == .needsReview
  }
}

public struct LocalPublishReadiness: Codable, Hashable, Sendable {
  public var writeReadiness: LocalPublishActionReadiness
  public var commitReadiness: LocalPublishActionReadiness
  public var changedFileCount: Int
  public var fileCount: Int
  public var writeBlockingIssues: [PreflightIssue]
  public var commitBlockingIssues: [PreflightIssue]
  public var warningIssues: [PreflightIssue]

  public init(
    writeReadiness: LocalPublishActionReadiness,
    commitReadiness: LocalPublishActionReadiness,
    changedFileCount: Int,
    fileCount: Int,
    writeBlockingIssues: [PreflightIssue],
    commitBlockingIssues: [PreflightIssue],
    warningIssues: [PreflightIssue]
  ) {
    self.writeReadiness = writeReadiness
    self.commitReadiness = commitReadiness
    self.changedFileCount = changedFileCount
    self.fileCount = fileCount
    self.writeBlockingIssues = writeBlockingIssues
    self.commitBlockingIssues = commitBlockingIssues
    self.warningIssues = warningIssues
  }

  public var canWrite: Bool {
    writeReadiness.allowsAction
  }

  public var canCommit: Bool {
    commitReadiness.allowsAction
  }

  public var blockingIssueCount: Int {
    var seenKeys: Set<String> = []
    for issue in writeBlockingIssues + commitBlockingIssues {
      let key = [
        issue.severity.rawValue,
        issue.title,
        issue.message,
        issue.field ?? "",
      ].joined(separator: "|")
      seenKeys.insert(key)
    }
    return seenKeys.count
  }
}
