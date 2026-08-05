import Foundation

public enum ReleaseLedgerActionPriority: Int, Codable, CaseIterable, Hashable, Sendable {
  case high
  case medium
  case low

  public var displayName: String {
    switch self {
    case .high:
      return CoreL10n.text("高")
    case .medium:
      return CoreL10n.text("中")
    case .low:
      return CoreL10n.text("低")
    }
  }
}

public enum ReleaseLedgerActionKind: String, Codable, Hashable, Sendable {
  case failedRelease
  case retryDeploymentCheck
  case observeDeployment
  case completeReview
  case publishLocalChanges
  case recoverPartialRemotePublish
  case keepRollbackReady

  public var displayName: String {
    switch self {
    case .failedRelease:
      return CoreL10n.text("失败处理")
    case .retryDeploymentCheck:
      return CoreL10n.text("重试检查")
    case .observeDeployment:
      return CoreL10n.text("部署观察")
    case .completeReview:
      return CoreL10n.text("合并 Review")
    case .publishLocalChanges:
      return CoreL10n.text("提交本地")
    case .recoverPartialRemotePublish:
      return CoreL10n.text("远端恢复")
    case .keepRollbackReady:
      return CoreL10n.text("回滚预案")
    }
  }
}

public extension ReleaseLedgerActionKind {
  var supportsDeploymentRecheck: Bool {
    switch self {
    case .failedRelease, .retryDeploymentCheck, .observeDeployment, .recoverPartialRemotePublish:
      return true
    case .completeReview, .publishLocalChanges, .keepRollbackReady:
      return false
    }
  }
}

public struct ReleaseLedgerActionItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var recordID: UUID
  public var kind: ReleaseLedgerActionKind
  public var priority: ReleaseLedgerActionPriority
  public var title: String
  public var summary: String
  public var detail: String
  public var systemImage: String
  public var remoteURL: String?
  public var commandLines: [String]
  public var createdAt: Date
}

public struct ReleaseDeploymentOverview: Codable, Hashable, Sendable {
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var checkedRecordCount: Int
  public var uncheckedDeploymentCount: Int
  public var failedDeploymentCount: Int
  public var runningDeploymentCount: Int
  public var lastCheckedAt: Date?
  public var nextActionTitle: String
  public var nextActionMessage: String
  public var highlightedSignals: [DeploymentStatusSignal]

  public init(
    level: DeploymentStatusLevel,
    title: String,
    message: String,
    checkedRecordCount: Int,
    uncheckedDeploymentCount: Int,
    failedDeploymentCount: Int,
    runningDeploymentCount: Int,
    lastCheckedAt: Date?,
    nextActionTitle: String,
    nextActionMessage: String,
    highlightedSignals: [DeploymentStatusSignal]
  ) {
    self.level = level
    self.title = title
    self.message = message
    self.checkedRecordCount = checkedRecordCount
    self.uncheckedDeploymentCount = uncheckedDeploymentCount
    self.failedDeploymentCount = failedDeploymentCount
    self.runningDeploymentCount = runningDeploymentCount
    self.lastCheckedAt = lastCheckedAt
    self.nextActionTitle = nextActionTitle
    self.nextActionMessage = nextActionMessage
    self.highlightedSignals = highlightedSignals
  }
}
