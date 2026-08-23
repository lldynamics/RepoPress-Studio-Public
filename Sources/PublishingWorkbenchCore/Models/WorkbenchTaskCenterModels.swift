import Foundation

public enum WorkbenchTaskKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case aiRequest
  case knowledgeImport
  case imageProcessing
  case siteScan
  case gitPush
  case deployment

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .aiRequest:
      return CoreL10n.text("AI 请求")
    case .knowledgeImport:
      return CoreL10n.text("资料导入")
    case .imageProcessing:
      return CoreL10n.text("图片处理")
    case .siteScan:
      return CoreL10n.text("站点扫描")
    case .gitPush:
      return CoreL10n.text("Git 推送")
    case .deployment:
      return CoreL10n.text("部署")
    }
  }

  public var systemImage: String {
    switch self {
    case .aiRequest:
      return "sparkles"
    case .knowledgeImport:
      return "books.vertical"
    case .imageProcessing:
      return "photo.on.rectangle.angled"
    case .siteScan:
      return "magnifyingglass.circle"
    case .gitPush:
      return "arrow.up.circle"
    case .deployment:
      return "shippingbox"
    }
  }

  public var sortRank: Int {
    switch self {
    case .aiRequest: return 0
    case .knowledgeImport: return 1
    case .imageProcessing: return 2
    case .siteScan: return 3
    case .gitPush: return 4
    case .deployment: return 5
    }
  }
}

public enum WorkbenchTaskState: String, Codable, Hashable, Sendable {
  case running
  case failed
  case completed
  case cancelled

  public var title: String {
    switch self {
    case .running:
      return CoreL10n.text("进行中")
    case .failed:
      return CoreL10n.text("失败")
    case .completed:
      return CoreL10n.text("已完成")
    case .cancelled:
      return CoreL10n.text("已停止")
    }
  }

  public var systemImage: String {
    switch self {
    case .running:
      return "progress.indicator"
    case .failed:
      return "exclamationmark.triangle.fill"
    case .completed:
      return "checkmark.circle.fill"
    case .cancelled:
      return "stop.circle"
    }
  }
}

/// The exact operation that a task-center retry is allowed to repeat.
///
/// A retry must carry its original target.  In particular, it must never infer
/// a target from the article that happens to be selected when the user opens
/// the task center.  Batch intents are intentionally represented by their
/// complete draft ID set so callers can fail closed if the queue has changed.
public enum WorkbenchTaskRetryIntent: Codable, Equatable, Hashable, Sendable {
  case aiChat(
    draftID: UUID,
    conversationID: UUID,
    requiresDuplicateChargeConfirmation: Bool
  )
  case generalAIChat(
    conversationID: UUID,
    operationID: UUID,
    requiresDuplicateChargeConfirmation: Bool
  )
  case knowledgeImport
  case imageProcessing
  case imageSummary(profileID: UUID)
  case siteScan(profileID: UUID)
  case gitDraft(profileID: UUID, draftID: UUID)
  case gitRemoteDraft(profileID: UUID, draftID: UUID)
  case gitRemoteBatch(profileID: UUID, draftIDs: [UUID])
  case deployment(recordID: UUID)

  public var requiresDuplicateChargeConfirmation: Bool {
    switch self {
    case .aiChat(_, _, let required), .generalAIChat(_, _, let required):
      return required
    default:
      return false
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case draftID
    case conversationID
    case operationID
    case requiresDuplicateChargeConfirmation
    case profileID
    case draftIDs
    case recordID
  }

  private enum Kind: String, Codable {
    case aiChat
    case generalAIChat
    case knowledgeImport
    case imageProcessing
    case imageSummary
    case siteScan
    case gitDraft
    case gitRemoteDraft
    case gitRemoteBatch
    case deployment
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .aiChat:
      self = .aiChat(
        draftID: try container.decode(UUID.self, forKey: .draftID),
        conversationID: try container.decode(UUID.self, forKey: .conversationID),
        requiresDuplicateChargeConfirmation: try container.decode(
          Bool.self,
          forKey: .requiresDuplicateChargeConfirmation
        )
      )
    case .generalAIChat:
      self = .generalAIChat(
        conversationID: try container.decode(UUID.self, forKey: .conversationID),
        operationID: try container.decode(UUID.self, forKey: .operationID),
        requiresDuplicateChargeConfirmation: try container.decode(
          Bool.self,
          forKey: .requiresDuplicateChargeConfirmation
        )
      )
    case .knowledgeImport:
      self = .knowledgeImport
    case .imageProcessing:
      self = .imageProcessing
    case .imageSummary:
      self = .imageSummary(profileID: try container.decode(UUID.self, forKey: .profileID))
    case .siteScan:
      self = .siteScan(profileID: try container.decode(UUID.self, forKey: .profileID))
    case .gitDraft:
      self = .gitDraft(
        profileID: try container.decode(UUID.self, forKey: .profileID),
        draftID: try container.decode(UUID.self, forKey: .draftID)
      )
    case .gitRemoteDraft:
      self = .gitRemoteDraft(
        profileID: try container.decode(UUID.self, forKey: .profileID),
        draftID: try container.decode(UUID.self, forKey: .draftID)
      )
    case .gitRemoteBatch:
      self = .gitRemoteBatch(
        profileID: try container.decode(UUID.self, forKey: .profileID),
        draftIDs: try container.decode([UUID].self, forKey: .draftIDs)
      )
    case .deployment:
      self = .deployment(recordID: try container.decode(UUID.self, forKey: .recordID))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .aiChat(let draftID, let conversationID, let requiresConfirmation):
      try container.encode(Kind.aiChat, forKey: .kind)
      try container.encode(draftID, forKey: .draftID)
      try container.encode(conversationID, forKey: .conversationID)
      try container.encode(
        requiresConfirmation,
        forKey: .requiresDuplicateChargeConfirmation
      )
    case .generalAIChat(let conversationID, let operationID, let requiresConfirmation):
      try container.encode(Kind.generalAIChat, forKey: .kind)
      try container.encode(conversationID, forKey: .conversationID)
      try container.encode(operationID, forKey: .operationID)
      try container.encode(
        requiresConfirmation,
        forKey: .requiresDuplicateChargeConfirmation
      )
    case .knowledgeImport:
      try container.encode(Kind.knowledgeImport, forKey: .kind)
    case .imageProcessing:
      try container.encode(Kind.imageProcessing, forKey: .kind)
    case .imageSummary(let profileID):
      try container.encode(Kind.imageSummary, forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
    case .siteScan(let profileID):
      try container.encode(Kind.siteScan, forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
    case .gitDraft(let profileID, let draftID):
      try container.encode(Kind.gitDraft, forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
      try container.encode(draftID, forKey: .draftID)
    case .gitRemoteDraft(let profileID, let draftID):
      try container.encode(Kind.gitRemoteDraft, forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
      try container.encode(draftID, forKey: .draftID)
    case .gitRemoteBatch(let profileID, let draftIDs):
      try container.encode(Kind.gitRemoteBatch, forKey: .kind)
      try container.encode(profileID, forKey: .profileID)
      try container.encode(draftIDs, forKey: .draftIDs)
    case .deployment(let recordID):
      try container.encode(Kind.deployment, forKey: .kind)
      try container.encode(recordID, forKey: .recordID)
    }
  }
}

public struct WorkbenchTaskItem: Identifiable, Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let kind: WorkbenchTaskKind
  public let title: String
  public let detail: String
  public let progress: Double?
  public let state: WorkbenchTaskState
  public let failureReason: String?
  public let targetID: UUID?
  public let retryIntent: WorkbenchTaskRetryIntent?

  public init(
    id: String,
    kind: WorkbenchTaskKind,
    title: String? = nil,
    detail: String,
    progress: Double? = nil,
    state: WorkbenchTaskState,
    failureReason: String? = nil,
    canRetry: Bool = false,
    targetID: UUID? = nil,
    retryIntent: WorkbenchTaskRetryIntent? = nil
  ) {
    // Keep the parameter for source compatibility with older task producers;
    // retryability is derived solely from the typed intent below.
    _ = canRetry
    self.id = id
    self.kind = kind
    self.title = title ?? kind.title
    self.detail = detail
    self.progress = progress.map { min(1, max(0, $0)) }
    self.state = state
    self.failureReason = failureReason
    self.targetID = targetID
    self.retryIntent = retryIntent
  }

  public var canRetry: Bool {
    guard let retryIntent else { return false }
    switch retryIntent {
    case .knowledgeImport, .imageProcessing:
      // These legacy intents do not carry an operation identifier. Keep them
      // fail-closed instead of repeating whichever operation happens to be
      // last in the store.
      return false
    default:
      return true
    }
  }

  public var isActive: Bool {
    state == .running
  }

  public var isFailure: Bool {
    state == .failed
  }

  public var requiresDuplicateChargeConfirmation: Bool {
    retryIntent?.requiresDuplicateChargeConfirmation ?? false
  }
}
