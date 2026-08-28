import Foundation


public enum ReleaseLedgerStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case localOnly
  case previewOnly
  case pendingReview
  case reviewWithdrawn
  case pendingDeployment
  case pendingRemoteRecovery
  case pendingRetry
  case deploying
  case succeeded
  case failed
  case unknown

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .localOnly:
      return CoreL10n.text("本地待处理")
    case .previewOnly:
      return CoreL10n.text("仅预览分支")
    case .pendingReview:
      return CoreL10n.text("等待合并")
    case .reviewWithdrawn:
      return CoreL10n.text("审核已撤回")
    case .pendingDeployment:
      return CoreL10n.text("等待部署检查")
    case .pendingRemoteRecovery:
      return CoreL10n.text("远端待确认")
    case .pendingRetry:
      return CoreL10n.text("待重试")
    case .deploying:
      return CoreL10n.text("部署中")
    case .succeeded:
      return CoreL10n.text("已上线")
    case .failed:
      return CoreL10n.text("失败")
    case .unknown:
      return CoreL10n.text("未知")
    }
  }

  public var systemImage: String {
    switch self {
    case .localOnly:
      return "externaldrive.badge.clock"
    case .previewOnly:
      return "eye.circle"
    case .pendingReview:
      return "arrow.triangle.pull"
    case .reviewWithdrawn:
      return "arrow.uturn.backward.circle"
    case .pendingDeployment:
      return "clock.badge.questionmark"
    case .pendingRemoteRecovery:
      return "icloud.and.arrow.up"
    case .pendingRetry:
      return "wifi.exclamationmark"
    case .deploying:
      return "hourglass"
    case .succeeded:
      return "checkmark.seal"
    case .failed:
      return "xmark.octagon"
    case .unknown:
      return "questionmark.circle"
    }
  }
}

public struct ReleaseRollbackDraft: Codable, Hashable, Sendable {
  public var title: String
  public var summary: String
  public var commandLines: [String]
  public var changedPaths: [String]
  public var reviewBranchName: String?
  public var reviewTitle: String?
  public var reviewBody: String?
  public var reviewURL: String?
  public var remoteURL: String?

  public init(
    title: String,
    summary: String,
    commandLines: [String],
    changedPaths: [String],
    reviewBranchName: String? = nil,
    reviewTitle: String? = nil,
    reviewBody: String? = nil,
    reviewURL: String? = nil,
    remoteURL: String? = nil
  ) {
    self.title = title
    self.summary = summary
    self.commandLines = commandLines
    self.changedPaths = changedPaths
    self.reviewBranchName = reviewBranchName
    self.reviewTitle = reviewTitle
    self.reviewBody = reviewBody
    self.reviewURL = reviewURL
    self.remoteURL = remoteURL
  }
}

public struct ReleaseLedgerEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var record: ReleaseRecord
  public var status: ReleaseLedgerStatus
  public var statusMessage: String
  public var deploymentStatus: DeploymentStatusSnapshot?
  public var rollbackDraft: ReleaseRollbackDraft?

  public init(
    id: UUID,
    record: ReleaseRecord,
    status: ReleaseLedgerStatus,
    statusMessage: String,
    deploymentStatus: DeploymentStatusSnapshot?,
    rollbackDraft: ReleaseRollbackDraft?
  ) {
    self.id = id
    self.record = record
    self.status = status
    self.statusMessage = statusMessage
    self.deploymentStatus = deploymentStatus
    self.rollbackDraft = rollbackDraft
  }
}

public struct ReleaseRecoveryPackage: Codable, Hashable, Sendable {
  public var title: String
  public var status: ReleaseLedgerStatus
  public var summary: String
  public var remoteURL: String?
  public var rollbackReviewURL: String?
  public var nextActions: [String]
  public var commandLines: [String]
  public var reviewTitle: String?
  public var reviewBody: String?
  public var changedPaths: [String]
  public var clipboardMarkdown: String

  public init(
    title: String,
    status: ReleaseLedgerStatus,
    summary: String,
    remoteURL: String?,
    rollbackReviewURL: String? = nil,
    nextActions: [String] = [],
    commandLines: [String],
    reviewTitle: String?,
    reviewBody: String?,
    changedPaths: [String],
    clipboardMarkdown: String
  ) {
    self.title = title
    self.status = status
    self.summary = summary
    self.remoteURL = remoteURL
    self.rollbackReviewURL = rollbackReviewURL
    self.nextActions = nextActions
    self.commandLines = commandLines
    self.reviewTitle = reviewTitle
    self.reviewBody = reviewBody
    self.changedPaths = changedPaths
    self.clipboardMarkdown = clipboardMarkdown
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case status
    case summary
    case remoteURL
    case rollbackReviewURL
    case nextActions
    case commandLines
    case reviewTitle
    case reviewBody
    case changedPaths
    case clipboardMarkdown
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    status = try container.decode(ReleaseLedgerStatus.self, forKey: .status)
    summary = try container.decode(String.self, forKey: .summary)
    remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
    rollbackReviewURL = try container.decodeIfPresent(String.self, forKey: .rollbackReviewURL)
    nextActions = try container.decodeIfPresent([String].self, forKey: .nextActions) ?? []
    commandLines = try container.decode([String].self, forKey: .commandLines)
    reviewTitle = try container.decodeIfPresent(String.self, forKey: .reviewTitle)
    reviewBody = try container.decodeIfPresent(String.self, forKey: .reviewBody)
    changedPaths = try container.decode([String].self, forKey: .changedPaths)
    clipboardMarkdown = try container.decode(String.self, forKey: .clipboardMarkdown)
  }
}
