import Foundation

public enum WorkbenchAutomationRisk: String, Codable, CaseIterable, Sendable {
  case readOnly
  case reversible
  case contentChange
  case externalEffect

  public var displayName: String {
    switch self {
    case .readOnly:
      return CoreL10n.text("只读")
    case .reversible:
      return CoreL10n.text("可撤销")
    case .contentChange:
      return CoreL10n.text("修改内容")
    case .externalEffect:
      return CoreL10n.text("外部操作")
    }
  }

  public var requiresExplicitConfirmation: Bool {
    self == .contentChange || self == .externalEffect
  }

  /// Agent-proposed commands use a stricter boundary than legacy/manual
  /// automation: only genuinely read-only work may run without a user action.
  public var requiresAgentConfirmation: Bool {
    self != .readOnly
  }
}

public enum WorkbenchAutomationCommandID: String, Codable, CaseIterable, Identifiable, Sendable {
  case openSection
  case selectDraft
  case createDraft
  case focusEditor
  case showInspector
  case runPreflight
  case refreshPublishPreview
  case saveWorkbench
  case updateMetadata
  case appendToBody
  case replaceBody
  case deleteDraft
  case writeLocalRepository
  case publishOnline

  public var id: String { rawValue }
}

public struct WorkbenchAutomationArguments: Codable, Hashable, Sendable {
  public var section: WorkspaceSection?
  public var draftID: UUID?
  public var expectedDraftUpdatedAt: Date?
  public var editorField: String?
  public var metadataField: AIPublishingMetadataField?
  public var value: String?
  public var values: [String]
  public var content: String?

  public init(
    section: WorkspaceSection? = nil,
    draftID: UUID? = nil,
    expectedDraftUpdatedAt: Date? = nil,
    editorField: String? = nil,
    metadataField: AIPublishingMetadataField? = nil,
    value: String? = nil,
    values: [String] = [],
    content: String? = nil
  ) {
    self.section = section
    self.draftID = draftID
    self.expectedDraftUpdatedAt = expectedDraftUpdatedAt
    self.editorField = editorField
    self.metadataField = metadataField
    self.value = value
    self.values = values
    self.content = content
  }
}

public enum WorkbenchAutomationStepStatus: String, Codable, Hashable, Sendable {
  case proposed
  case running
  case awaitingConfirmation
  case succeeded
  case failed
  case cancelled

  public var isTerminal: Bool {
    self == .succeeded || self == .failed || self == .cancelled
  }
}

public struct WorkbenchAutomationStep: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var command: WorkbenchAutomationCommandID
  public var arguments: WorkbenchAutomationArguments
  public var publishAuthorization: AIPublishAuthorizationSnapshot?
  public var status: WorkbenchAutomationStepStatus
  public var resultMessage: String?

  public init(
    id: UUID = UUID(),
    command: WorkbenchAutomationCommandID,
    arguments: WorkbenchAutomationArguments = WorkbenchAutomationArguments(),
    publishAuthorization: AIPublishAuthorizationSnapshot? = nil,
    status: WorkbenchAutomationStepStatus = .proposed,
    resultMessage: String? = nil
  ) {
    self.id = id
    self.command = command
    self.arguments = arguments
    self.publishAuthorization = publishAuthorization
    self.status = status
    self.resultMessage = resultMessage
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case command
    case arguments
    case status
    case resultMessage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
    arguments = try container.decode(WorkbenchAutomationArguments.self, forKey: .arguments)
    publishAuthorization = nil
    status = try container.decode(WorkbenchAutomationStepStatus.self, forKey: .status)
    resultMessage = try container.decodeIfPresent(String.self, forKey: .resultMessage)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(command, forKey: .command)
    try container.encode(arguments, forKey: .arguments)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(resultMessage, forKey: .resultMessage)
  }
}

public enum WorkbenchAutomationPlanStatus: String, Codable, Hashable, Sendable {
  case proposed
  case running
  case awaitingConfirmation
  case succeeded
  case partiallySucceeded
  case failed
  case cancelled
}

public enum WorkbenchAutomationPlanSource: String, Codable, Hashable, Sendable {
  case legacy
  case agentLoop
}

public struct WorkbenchAutomationPlan: Identifiable, Codable, Hashable, Sendable {
  public static let maximumStepCount = 12

  public var id: UUID
  public var goal: String
  public var steps: [WorkbenchAutomationStep]
  public var createdAt: Date
  public var source: WorkbenchAutomationPlanSource

  public init(
    id: UUID = UUID(),
    goal: String,
    steps: [WorkbenchAutomationStep],
    createdAt: Date = Date(),
    source: WorkbenchAutomationPlanSource = .legacy
  ) {
    self.id = id
    self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    self.steps = steps
    self.createdAt = createdAt
    self.source = source
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case goal
    case steps
    case createdAt
    case source
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    goal = try container.decode(String.self, forKey: .goal)
    steps = try container.decode([WorkbenchAutomationStep].self, forKey: .steps)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    source =
      try container.decodeIfPresent(
        WorkbenchAutomationPlanSource.self,
        forKey: .source
      ) ?? .legacy
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(goal, forKey: .goal)
    try container.encode(steps, forKey: .steps)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(source, forKey: .source)
  }

  public var status: WorkbenchAutomationPlanStatus {
    if steps.contains(where: { $0.status == .running }) {
      return .running
    }
    if steps.contains(where: { $0.status == .awaitingConfirmation }) {
      return .awaitingConfirmation
    }
    if steps.allSatisfy({ $0.status == .cancelled }) {
      return .cancelled
    }
    if steps.contains(where: { $0.status == .failed }) {
      return steps.contains(where: { $0.status == .succeeded }) ? .partiallySucceeded : .failed
    }
    if !steps.isEmpty, steps.allSatisfy({ $0.status == .succeeded }) {
      return .succeeded
    }
    if steps.contains(where: { $0.status == .succeeded }) {
      return .partiallySucceeded
    }
    return .proposed
  }
}

public struct WorkbenchAutomationCommandDescriptor: Identifiable, Hashable, Sendable {
  public var id: WorkbenchAutomationCommandID
  public var title: String
  public var detail: String
  public var systemImage: String
  public var risk: WorkbenchAutomationRisk
  public var requiresDraft: Bool

  public init(
    id: WorkbenchAutomationCommandID,
    title: String,
    detail: String,
    systemImage: String,
    risk: WorkbenchAutomationRisk,
    requiresDraft: Bool = false
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.risk = risk
    self.requiresDraft = requiresDraft
  }
}

public struct WorkbenchAutomationStepRecord: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var command: WorkbenchAutomationCommandID
  public var status: WorkbenchAutomationStepStatus
  public var message: String
  public var targetDraftID: UUID?
  public var rollbackVersionID: UUID?
  public var completedAt: Date

  public init(
    id: UUID = UUID(),
    command: WorkbenchAutomationCommandID,
    status: WorkbenchAutomationStepStatus,
    message: String,
    targetDraftID: UUID? = nil,
    rollbackVersionID: UUID? = nil,
    completedAt: Date = Date()
  ) {
    self.id = id
    self.command = command
    self.status = status
    self.message = message
    self.targetDraftID = targetDraftID
    self.rollbackVersionID = rollbackVersionID
    self.completedAt = completedAt
  }
}

public struct WorkbenchAutomationRunRecord: Identifiable, Codable, Hashable, Sendable {
  public static let maximumHistoryCount = 50

  public var id: UUID
  public var planID: UUID
  public var goal: String
  public var startedAt: Date
  public var completedAt: Date
  public var steps: [WorkbenchAutomationStepRecord]
  public var rolledBackAt: Date?

  public init(
    id: UUID = UUID(),
    planID: UUID,
    goal: String,
    startedAt: Date,
    completedAt: Date = Date(),
    steps: [WorkbenchAutomationStepRecord],
    rolledBackAt: Date? = nil
  ) {
    self.id = id
    self.planID = planID
    self.goal = goal
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.steps = steps
    self.rolledBackAt = rolledBackAt
  }

  public var hasRollback: Bool {
    rolledBackAt == nil
      && steps.contains {
        $0.rollbackVersionID != nil || $0.command == .createDraft || $0.command == .deleteDraft
      }
  }
}

public struct WorkbenchAutomationExecutionResult: Hashable, Sendable {
  public var plan: WorkbenchAutomationPlan
  public var record: WorkbenchAutomationRunRecord

  public init(plan: WorkbenchAutomationPlan, record: WorkbenchAutomationRunRecord) {
    self.plan = plan
    self.record = record
  }
}

public struct WorkbenchAutomationDraftPreview: Identifiable, Hashable, Sendable {
  public var id: UUID { stepID }
  public var stepID: UUID
  public var originalDraft: ArticleDraft
  public var updatedDraft: ArticleDraft

  public init(stepID: UUID, originalDraft: ArticleDraft, updatedDraft: ArticleDraft) {
    self.stepID = stepID
    self.originalDraft = originalDraft
    self.updatedDraft = updatedDraft
  }
}

public enum WorkbenchAutomationValidationError: Error, Equatable, LocalizedError, Sendable {
  case emptyPlan
  case tooManySteps(Int)
  case missingArgument(String)
  case draftNotFound
  case staleDraft
  case unsupportedCommand
  case confirmationRequired
  case operationInProgress

  public var errorDescription: String? {
    switch self {
    case .emptyPlan:
      return CoreL10n.text("自动化计划没有可执行步骤。")
    case .tooManySteps(let count):
      return CoreL10n.format("自动化计划包含 %lld 个步骤，超过安全上限。", count)
    case .missingArgument(let name):
      return CoreL10n.format("自动化命令缺少参数：%@。", name)
    case .draftNotFound:
      return CoreL10n.text("目标文章不存在或已被删除。")
    case .staleDraft:
      return CoreL10n.text("文章在计划生成后已发生变化，请重新生成或预览计划。")
    case .unsupportedCommand:
      return CoreL10n.text("该命令不在应用允许的自动化白名单中。")
    case .confirmationRequired:
      return CoreL10n.text("该操作需要用户明确确认。")
    case .operationInProgress:
      return CoreL10n.text("已有自动化计划正在执行。")
    }
  }
}
