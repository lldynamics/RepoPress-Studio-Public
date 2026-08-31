import Foundation

public enum WorkbenchOperationLogCategory: String, CaseIterable, Codable, Hashable, Identifiable,
  Sendable
{
  case publishing
  case maintenance
  case automation
  case ai
  case deployment
  case importing
  case images
  case backup

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .publishing:
      return CoreL10n.text("发布")
    case .maintenance:
      return CoreL10n.text("维护")
    case .automation:
      return CoreL10n.text("自动化")
    case .ai:
      return CoreL10n.text("AI")
    case .deployment:
      return CoreL10n.text("部署")
    case .importing:
      return CoreL10n.text("导入")
    case .images:
      return CoreL10n.text("图片")
    case .backup:
      return CoreL10n.text("备份")
    }
  }

  public var systemImage: String {
    switch self {
    case .publishing:
      return "square.and.arrow.up"
    case .maintenance:
      return "wrench.and.screwdriver"
    case .automation:
      return "bolt.circle"
    case .ai:
      return "sparkles"
    case .deployment:
      return "cloud"
    case .importing:
      return "square.and.arrow.down"
    case .images:
      return "photo.stack"
    case .backup:
      return "externaldrive.badge.timemachine"
    }
  }
}

public enum WorkbenchOperationLogOutcome: String, CaseIterable, Codable, Hashable, Identifiable,
  Sendable
{
  case succeeded
  case partial
  case failed
  case cancelled
  case recorded
  case observed

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .succeeded:
      return CoreL10n.text("成功")
    case .partial:
      return CoreL10n.text("活动记录结果：部分完成")
    case .failed:
      return CoreL10n.text("失败")
    case .cancelled:
      return CoreL10n.text("已取消")
    case .recorded:
      return CoreL10n.text("已记录")
    case .observed:
      return CoreL10n.text("已观察")
    }
  }
}

public enum WorkbenchOperationLogActor: String, CaseIterable, Codable, Hashable, Identifiable,
  Sendable
{
  case user
  case automation
  case background

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .user:
      return CoreL10n.text("用户")
    case .automation:
      return CoreL10n.text("自动化")
    case .background:
      return CoreL10n.text("后台")
    }
  }
}

public enum WorkbenchOperationLogSourceKind: String, CaseIterable, Codable, Hashable, Sendable {
  case releaseRecord
  case maintenanceOperation
  case automationRun
  case aiMetadataApplication
  case deploymentStatus
  case operationEvent
}

public struct WorkbenchOperationLogSourceReference: Hashable, Sendable {
  public let kind: WorkbenchOperationLogSourceKind
  public let id: UUID

  public init(kind: WorkbenchOperationLogSourceKind, id: UUID) {
    self.kind = kind
    self.id = id
  }

  public var stableIdentifier: String {
    "\(kind.rawValue):\(id.uuidString.lowercased())"
  }
}

public struct WorkbenchOperationLogEntry: Identifiable, Hashable, Sendable {
  public var id: String { sourceReference.stableIdentifier }
  public let sourceReference: WorkbenchOperationLogSourceReference
  public let category: WorkbenchOperationLogCategory
  public let outcome: WorkbenchOperationLogOutcome
  public let actor: WorkbenchOperationLogActor
  public let title: String
  public let summary: String
  public let profileID: UUID?
  public let draftID: UUID?
  public let targetLabel: String?
  public let occurredAt: Date
  public let systemImage: String

  public init(
    sourceReference: WorkbenchOperationLogSourceReference,
    category: WorkbenchOperationLogCategory,
    outcome: WorkbenchOperationLogOutcome,
    actor: WorkbenchOperationLogActor,
    title: String,
    summary: String,
    profileID: UUID? = nil,
    draftID: UUID? = nil,
    targetLabel: String? = nil,
    occurredAt: Date,
    systemImage: String? = nil
  ) {
    self.sourceReference = sourceReference
    self.category = category
    self.outcome = outcome
    self.actor = actor
    self.title = title
    self.summary = summary
    self.profileID = profileID
    self.draftID = draftID
    self.targetLabel = targetLabel
    self.occurredAt = occurredAt
    self.systemImage = systemImage ?? category.systemImage
  }
}
