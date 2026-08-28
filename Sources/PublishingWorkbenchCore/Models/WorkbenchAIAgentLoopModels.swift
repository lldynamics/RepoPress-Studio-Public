import Foundation

public struct WorkbenchAIAgentLoopLimits: Codable, Hashable, Sendable {
  public let maximumModelRoundCount: Int
  public let maximumToolCallCountPerRound: Int
  public let maximumTotalToolCallCount: Int
  public let maximumArgumentByteCountPerCall: Int
  public let maximumTotalArgumentByteCount: Int
  public let maximumToolResultByteCountPerCall: Int
  public let maximumTotalToolResultByteCount: Int
  public let maximumTotalAssistantByteCount: Int
  public let maximumTotalTranscriptByteCount: Int

  public init(
    maximumModelRoundCount: Int = 6,
    maximumToolCallCountPerRound: Int = 4,
    maximumTotalToolCallCount: Int = 12,
    maximumArgumentByteCountPerCall: Int = 16 * 1_024,
    maximumTotalArgumentByteCount: Int = 64 * 1_024,
    maximumToolResultByteCountPerCall: Int = 64 * 1_024,
    maximumTotalToolResultByteCount: Int = 256 * 1_024,
    maximumTotalAssistantByteCount: Int = 256 * 1_024,
    maximumTotalTranscriptByteCount: Int = 1_024 * 1_024
  ) {
    self.maximumModelRoundCount = max(0, maximumModelRoundCount)
    self.maximumToolCallCountPerRound = max(0, maximumToolCallCountPerRound)
    self.maximumTotalToolCallCount = max(0, maximumTotalToolCallCount)
    self.maximumArgumentByteCountPerCall = max(0, maximumArgumentByteCountPerCall)
    self.maximumTotalArgumentByteCount = max(0, maximumTotalArgumentByteCount)
    self.maximumToolResultByteCountPerCall = max(0, maximumToolResultByteCountPerCall)
    self.maximumTotalToolResultByteCount = max(0, maximumTotalToolResultByteCount)
    self.maximumTotalAssistantByteCount = max(0, maximumTotalAssistantByteCount)
    self.maximumTotalTranscriptByteCount = max(0, maximumTotalTranscriptByteCount)
  }

  public static let `default` = WorkbenchAIAgentLoopLimits()
}

public struct WorkbenchAIAgentContext: Hashable, Sendable {
  public var goal: String
  public var draftVersions: [UUID: Date]

  public init(
    goal: String,
    currentDraft: ArticleDraft? = nil,
    draftVersions: [UUID: Date] = [:]
  ) {
    self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    self.draftVersions = draftVersions
    if let currentDraft {
      self.draftVersions[currentDraft.id] = currentDraft.updatedAt
    }
  }
}

public enum WorkbenchAIAgentLoopLimit: Hashable, Sendable {
  case modelRounds(maximum: Int)
  case toolCallsPerRound(maximum: Int, received: Int)
  case totalToolCalls(maximum: Int, received: Int)
  case argumentBytesPerCall(toolCallID: String, maximum: Int, received: Int)
  case totalArgumentBytes(maximum: Int, received: Int)
  case toolResultBytesPerCall(toolCallID: String, maximum: Int, received: Int)
  case totalToolResultBytes(maximum: Int, received: Int)
  case totalAssistantBytes(maximum: Int, received: Int)
  case totalTranscriptBytes(maximum: Int, received: Int)
}

public enum WorkbenchAIAgentLoopRejection: Hashable, Sendable {
  case emptyModelResponse
  case malformedToolCall(toolCallID: String)
  case duplicateToolCallID(String)
  case unknownTool(String)
  case toolNotAllowed(String)
  case invalidJSON(toolCallID: String)
  case argumentMismatch(toolCallID: String, toolName: String)
  /// The persisted transcript or reviewed-call envelope failed validation.
  /// No model transport or application executor is entered for this result.
  case invalidContinuation
  /// The checkpoint still has unresolved calls, so a partial reviewed round
  /// cannot be appended to the model transcript.
  case incompleteReviewedRound
}

public enum WorkbenchAIAgentLoopTermination: Hashable, Sendable {
  case completed
  case awaitingReview
  case capabilityUnavailable(AIProviderCapabilitySupport)
  case rejected(WorkbenchAIAgentLoopRejection)
  case limitReached(WorkbenchAIAgentLoopLimit)
  case cancelled
  case modelTransportFailed
}

/// A provider-neutral tool call which may, but does not have to, be backed by
/// a Workbench automation step. `toolID` is the authority-bearing identity;
/// the model-visible name is retained only for transcript correlation.
public struct WorkbenchAIAgentToolInvocation: Codable, Hashable, Sendable {
  public var toolCallID: String
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var executionPolicy: AIAgentToolExecutionPolicy
  public var catalogRevision: String
  public var correlationID: UUID
  public var targetDraftID: UUID?
  public var targetDraftVersion: Date?
  public var externalToolBinding: AIAgentExternalToolBinding?
  public var automationStep: WorkbenchAutomationStep?

  public init(
    toolCallID: String,
    toolID: AIAgentToolID,
    modelToolName: String,
    executionPolicy: AIAgentToolExecutionPolicy,
    catalogRevision: String,
    correlationID: UUID = UUID(),
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    externalToolBinding: AIAgentExternalToolBinding? = nil,
    automationStep: WorkbenchAutomationStep? = nil
  ) {
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.executionPolicy = executionPolicy
    self.catalogRevision = catalogRevision
    self.correlationID = correlationID
    self.targetDraftID = targetDraftID
    self.targetDraftVersion = targetDraftVersion
    self.externalToolBinding = externalToolBinding
    self.automationStep = automationStep
  }

  /// Legacy built-in adapter entry point. External tools must use the
  /// generic initializer so they cannot be misrepresented as automation
  /// commands.
  @available(
    *, deprecated,
    message:
      "Use init(toolCallID:toolID:modelToolName:executionPolicy:catalogRevision:correlationID:targetDraftID:targetDraftVersion:automationStep:)"
  )
  public init(toolCallID: String, step: WorkbenchAutomationStep) {
    self.init(
      toolCallID: toolCallID,
      toolID: Self.toolID(for: step.command),
      modelToolName: step.command.rawValue,
      executionPolicy: Self.executionPolicy(for: step.command),
      catalogRevision: WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision,
      correlationID: step.id,
      targetDraftID: step.arguments.draftID,
      targetDraftVersion: step.arguments.expectedDraftUpdatedAt,
      automationStep: step
    )
  }

  /// Returns an automation command only when this invocation originated from
  /// the built-in Workbench adapter. Unknown IDs deliberately remain nil.
  public var command: WorkbenchAutomationCommandID? {
    Self.command(for: toolID)
  }

  public var step: WorkbenchAutomationStep? { automationStep }

  /// A fixed legacy namespace prevents collisions with a future external
  /// catalog. The adapter is responsible for assigning current revisions.
  static let legacyCatalogRevision = "workbench-legacy-v1"
  static let legacyExecutionPolicy: AIAgentToolExecutionPolicy = .requiresConfirmation

  static func toolID(for command: WorkbenchAutomationCommandID) -> AIAgentToolID {
    WorkbenchAutomationRegistry.agentToolID(for: command)
  }

  static func command(for toolID: AIAgentToolID) -> WorkbenchAutomationCommandID? {
    WorkbenchAutomationRegistry.agentCommand(for: toolID)
  }

  static func executionPolicy(
    for command: WorkbenchAutomationCommandID
  ) -> AIAgentToolExecutionPolicy {
    WorkbenchAutomationRegistry.descriptor(for: command)?.allowsAgentAutomaticExecution == true
      ? .automatic : .requiresConfirmation
  }
}

extension AIAgentToolID {
  public static let showInspector = AIAgentToolID("workbench/showInspector")
  public static let createDraft = AIAgentToolID("workbench/createDraft")
  public static let updateMetadata = AIAgentToolID("workbench/updateMetadata")
  public static let replaceBody = AIAgentToolID("workbench/replaceBody")
  public static let knowledgeSearch = AIAgentToolID("workbench/knowledgeSearch")
  public static let knowledgeRead = AIAgentToolID("workbench/knowledgeRead")
}

public struct WorkbenchAIAgentToolResult: Hashable, Sendable {
  public var content: String
  public var isError: Bool
  public var targetDraftID: UUID?

  public init(content: String, isError: Bool = false, targetDraftID: UUID? = nil) {
    self.content = content
    self.isError = isError
    self.targetDraftID = targetDraftID
  }
}

/// The externally visible outcome of one tool call accepted by the agent
/// loop. Calls are only recorded after the command has passed the allowlist
/// and argument validation gates; rejected model payloads never become a
/// successful-looking history entry.
public enum WorkbenchAIAgentToolRunStatus: String, Codable, Hashable, Sendable {
  case awaitingConfirmation
  case succeeded
  case failed
  case cancelled
  case rejected
}

/// Durable audit metadata for a tool run. Raw external arguments deliberately
/// live only in pending invocation state and are not copied into run history.
public struct WorkbenchAIAgentToolRunRecord: Codable, Identifiable, Hashable, Sendable {
  public static let maximumSummaryLength = 512

  public var toolCallID: String
  public var id: String { toolCallID }
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var executionPolicy: AIAgentToolExecutionPolicy
  public var catalogRevision: String
  public var correlationID: UUID
  public var status: WorkbenchAIAgentToolRunStatus
  public var summary: String
  public var automationStepID: UUID?
  public var targetDraftID: UUID?
  public var targetDraftVersion: Date?
  public var startedAt: Date
  public var completedAt: Date?

  public init(
    toolCallID: String,
    toolID: AIAgentToolID,
    modelToolName: String,
    executionPolicy: AIAgentToolExecutionPolicy,
    catalogRevision: String,
    status: WorkbenchAIAgentToolRunStatus,
    summary: String,
    correlationID: UUID = UUID(),
    automationStepID: UUID? = nil,
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    startedAt: Date,
    completedAt: Date? = nil
  ) {
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.executionPolicy = executionPolicy
    self.catalogRevision = catalogRevision
    self.correlationID = correlationID
    self.status = status
    self.summary = Self.boundedSummary(summary)
    self.automationStepID = automationStepID
    self.targetDraftID = targetDraftID
    self.targetDraftVersion = targetDraftVersion
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public init(
    toolCallID: String,
    command: WorkbenchAutomationCommandID,
    status: WorkbenchAIAgentToolRunStatus,
    summary: String,
    automationStepID: UUID? = nil,
    targetDraftID: UUID? = nil,
    startedAt: Date,
    completedAt: Date? = nil
  ) {
    self.init(
      toolCallID: toolCallID,
      toolID: WorkbenchAIAgentToolInvocation.toolID(for: command),
      modelToolName: command.rawValue,
      executionPolicy: WorkbenchAIAgentToolInvocation.executionPolicy(for: command),
      catalogRevision: WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision,
      status: status,
      summary: summary,
      correlationID: automationStepID
        ?? Self.stableLegacyCorrelationID(toolCallID: toolCallID),
      automationStepID: automationStepID,
      targetDraftID: targetDraftID,
      startedAt: startedAt,
      completedAt: completedAt
    )
  }

  /// This is intentionally optional: a persisted external tool must never be
  /// coerced into a Workbench command.
  public var command: WorkbenchAutomationCommandID? {
    WorkbenchAIAgentToolInvocation.command(for: toolID)
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID
    case toolID
    case modelToolName
    case executionPolicy
    case catalogRevision
    case correlationID
    case command
    case status
    case summary
    case automationStepID
    case targetDraftID
    case targetDraftVersion
    case startedAt
    case completedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    automationStepID = try container.decodeIfPresent(UUID.self, forKey: .automationStepID)
    if let toolID = try container.decodeIfPresent(AIAgentToolID.self, forKey: .toolID) {
      self.toolID = toolID
      modelToolName =
        try container.decodeIfPresent(String.self, forKey: .modelToolName) ?? toolID.rawValue
      executionPolicy =
        try container.decodeIfPresent(
          AIAgentToolExecutionPolicy.self,
          forKey: .executionPolicy
        ) ?? .requiresConfirmation
      catalogRevision =
        try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        ?? WorkbenchAIAgentToolInvocation.legacyCatalogRevision
      correlationID =
        try container.decodeIfPresent(UUID.self, forKey: .correlationID)
        ?? automationStepID
        ?? Self.stableLegacyCorrelationID(toolCallID: toolCallID)
    } else {
      let command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
      toolID = WorkbenchAIAgentToolInvocation.toolID(for: command)
      modelToolName = command.rawValue
      executionPolicy = WorkbenchAIAgentToolInvocation.legacyExecutionPolicy
      catalogRevision = WorkbenchAIAgentToolInvocation.legacyCatalogRevision
      correlationID =
        automationStepID
        ?? Self.stableLegacyCorrelationID(toolCallID: toolCallID)
    }
    status = try container.decode(WorkbenchAIAgentToolRunStatus.self, forKey: .status)
    summary = Self.boundedSummary(try container.decode(String.self, forKey: .summary))
    targetDraftID = try container.decodeIfPresent(UUID.self, forKey: .targetDraftID)
    targetDraftVersion = try container.decodeIfPresent(Date.self, forKey: .targetDraftVersion)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(toolID, forKey: .toolID)
    try container.encode(modelToolName, forKey: .modelToolName)
    try container.encode(executionPolicy, forKey: .executionPolicy)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(status, forKey: .status)
    try container.encode(summary, forKey: .summary)
    try container.encodeIfPresent(automationStepID, forKey: .automationStepID)
    try container.encodeIfPresent(targetDraftID, forKey: .targetDraftID)
    try container.encodeIfPresent(targetDraftVersion, forKey: .targetDraftVersion)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
  }

  private static func boundedSummary(_ summary: String) -> String {
    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maximumSummaryLength else { return normalized }
    return String(normalized.prefix(maximumSummaryLength - 3)) + "..."
  }

  fileprivate static func stableLegacyCorrelationID(toolCallID: String) -> UUID {
    let bytes = Array(toolCallID.utf8)
    var uuidBytes = [UInt8](repeating: 0, count: 16)
    for (index, byte) in bytes.enumerated() {
      uuidBytes[index % uuidBytes.count] &+= byte &+ UInt8(truncatingIfNeeded: index)
    }
    uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
    uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
        uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
        uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
        uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
      ))
  }
}

/// A tool call paused at the review boundary. The full step is persisted so a
/// resumed loop can validate the call again instead of trusting a mutable UI
/// plan or a caller-supplied command name.
public struct WorkbenchAIAgentLoopPendingCall: Codable, Hashable, Sendable {
  public var toolCallID: String
  public var correlationID: UUID
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var executionPolicy: AIAgentToolExecutionPolicy
  public var catalogRevision: String
  public var automationStepID: UUID?
  public var targetDraftID: UUID?
  public var targetDraftVersion: Date?
  public var externalToolBinding: AIAgentExternalToolBinding?
  public var automationStep: WorkbenchAutomationStep?

  public init(
    toolCallID: String,
    correlationID: UUID = UUID(),
    toolID: AIAgentToolID,
    modelToolName: String,
    executionPolicy: AIAgentToolExecutionPolicy,
    catalogRevision: String,
    automationStepID: UUID? = nil,
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    externalToolBinding: AIAgentExternalToolBinding? = nil,
    automationStep: WorkbenchAutomationStep? = nil
  ) {
    self.toolCallID = toolCallID
    self.correlationID = correlationID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.executionPolicy = executionPolicy
    self.catalogRevision = catalogRevision
    self.automationStepID = automationStepID
    self.targetDraftID = targetDraftID
    self.targetDraftVersion = targetDraftVersion
    self.externalToolBinding = externalToolBinding
    self.automationStep = automationStep
  }

  public init(
    toolCallID: String,
    automationStepID: UUID,
    command: WorkbenchAutomationCommandID,
    targetDraftID: UUID?,
    step: WorkbenchAutomationStep
  ) {
    self.init(
      toolCallID: toolCallID,
      correlationID: automationStepID,
      toolID: WorkbenchAIAgentToolInvocation.toolID(for: command),
      modelToolName: command.rawValue,
      executionPolicy: WorkbenchAIAgentToolInvocation.executionPolicy(for: command),
      catalogRevision: WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision,
      automationStepID: automationStepID,
      targetDraftID: targetDraftID,
      targetDraftVersion: step.arguments.expectedDraftUpdatedAt,
      automationStep: step
    )
  }

  public var command: WorkbenchAutomationCommandID? {
    WorkbenchAIAgentToolInvocation.command(for: toolID)
  }

  public var step: WorkbenchAutomationStep? { automationStep }

  private enum CodingKeys: String, CodingKey {
    case toolCallID, correlationID, toolID, modelToolName, executionPolicy, catalogRevision
    case automationStepID, command, targetDraftID, targetDraftVersion, externalToolBinding
    case automationStep, step
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    if let toolID = try container.decodeIfPresent(AIAgentToolID.self, forKey: .toolID) {
      self.toolID = toolID
      modelToolName =
        try container.decodeIfPresent(String.self, forKey: .modelToolName) ?? toolID.rawValue
      executionPolicy =
        try container.decodeIfPresent(AIAgentToolExecutionPolicy.self, forKey: .executionPolicy)
        ?? .requiresConfirmation
      catalogRevision =
        try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        ?? WorkbenchAIAgentToolInvocation.legacyCatalogRevision
    } else {
      let command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
      toolID = WorkbenchAIAgentToolInvocation.toolID(for: command)
      modelToolName = command.rawValue
      executionPolicy = WorkbenchAIAgentToolInvocation.legacyExecutionPolicy
      catalogRevision = WorkbenchAIAgentToolInvocation.legacyCatalogRevision
    }
    automationStepID = try container.decodeIfPresent(UUID.self, forKey: .automationStepID)
    targetDraftID = try container.decodeIfPresent(UUID.self, forKey: .targetDraftID)
    automationStep =
      try container.decodeIfPresent(WorkbenchAutomationStep.self, forKey: .automationStep)
      ?? container.decodeIfPresent(WorkbenchAutomationStep.self, forKey: .step)
    targetDraftVersion =
      try container.decodeIfPresent(Date.self, forKey: .targetDraftVersion)
      ?? automationStep?.arguments.expectedDraftUpdatedAt
    externalToolBinding = try container.decodeIfPresent(
      AIAgentExternalToolBinding.self,
      forKey: .externalToolBinding
    )
    correlationID =
      try container.decodeIfPresent(UUID.self, forKey: .correlationID)
      ?? automationStepID
      ?? automationStep?.id
      ?? WorkbenchAIAgentToolRunRecord.stableLegacyCorrelationID(toolCallID: toolCallID)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(toolID, forKey: .toolID)
    try container.encode(modelToolName, forKey: .modelToolName)
    try container.encode(executionPolicy, forKey: .executionPolicy)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encodeIfPresent(automationStepID, forKey: .automationStepID)
    try container.encodeIfPresent(targetDraftID, forKey: .targetDraftID)
    try container.encodeIfPresent(targetDraftVersion, forKey: .targetDraftVersion)
    try container.encodeIfPresent(externalToolBinding, forKey: .externalToolBinding)
    try container.encodeIfPresent(automationStep, forKey: .automationStep)
  }

  public var invocation: WorkbenchAIAgentToolInvocation {
    WorkbenchAIAgentToolInvocation(
      toolCallID: toolCallID,
      toolID: toolID,
      modelToolName: modelToolName,
      executionPolicy: executionPolicy,
      catalogRevision: catalogRevision,
      correlationID: correlationID,
      targetDraftID: targetDraftID,
      targetDraftVersion: targetDraftVersion,
      externalToolBinding: externalToolBinding,
      automationStep: automationStep
    )
  }
}

public enum WorkbenchAIAgentToolResolutionStatus: String, Codable, Hashable, Sendable {
  case succeeded
  case failed
  case rejected
  case cancelled

  public var isTerminal: Bool { true }
}

/// The complete, bounded result of one user-resolved pending tool call. Raw
/// external arguments deliberately remain in the pending checkpoint and are
/// not copied into this durable terminal record. This is deliberately separate
/// from `WorkbenchAIAgentToolRunRecord.summary`:
/// summaries are for local UI history, while this content is the exact,
/// bounded payload appended to the next model request.
public struct WorkbenchAIAgentToolResolution: Codable, Hashable, Sendable {
  public static let maximumContentByteCount = 64 * 1_024

  public var toolCallID: String
  public var correlationID: UUID
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var catalogRevision: String
  public var automationStepID: UUID?
  public var status: WorkbenchAIAgentToolResolutionStatus
  public var content: String
  public var targetDraftID: UUID?
  public var targetDraftVersion: Date?
  public var resolvedAt: Date

  public init(
    toolCallID: String,
    correlationID: UUID = UUID(),
    toolID: AIAgentToolID,
    modelToolName: String,
    catalogRevision: String,
    automationStepID: UUID? = nil,
    status: WorkbenchAIAgentToolResolutionStatus,
    content: String,
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    resolvedAt: Date = Date()
  ) {
    self.toolCallID = toolCallID
    self.correlationID = correlationID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.catalogRevision = catalogRevision
    self.automationStepID = automationStepID
    self.status = status
    self.content = content
    self.targetDraftID = targetDraftID
    self.targetDraftVersion = targetDraftVersion
    self.resolvedAt = resolvedAt
  }

  /// Creates a resolution whose authority-bearing identity is copied from
  /// the persisted pending call. UI and host adapters should prefer this over
  /// reconstructing identity from a model-visible function name.
  public init(
    resolving pendingCall: WorkbenchAIAgentLoopPendingCall,
    status: WorkbenchAIAgentToolResolutionStatus,
    content: String,
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    resolvedAt: Date = Date()
  ) {
    self.init(
      toolCallID: pendingCall.toolCallID,
      correlationID: pendingCall.correlationID,
      toolID: pendingCall.toolID,
      modelToolName: pendingCall.modelToolName,
      catalogRevision: pendingCall.catalogRevision,
      automationStepID: pendingCall.automationStepID,
      status: status,
      content: content,
      targetDraftID: targetDraftID ?? pendingCall.targetDraftID,
      targetDraftVersion: targetDraftVersion ?? pendingCall.targetDraftVersion,
      resolvedAt: resolvedAt
    )
  }

  public init(
    toolCallID: String,
    automationStepID: UUID,
    command: WorkbenchAutomationCommandID,
    status: WorkbenchAIAgentToolResolutionStatus,
    content: String,
    targetDraftID: UUID? = nil,
    resolvedAt: Date = Date()
  ) {
    self.init(
      toolCallID: toolCallID,
      correlationID: automationStepID,
      toolID: WorkbenchAIAgentToolInvocation.toolID(for: command),
      modelToolName: command.rawValue,
      catalogRevision: WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision,
      automationStepID: automationStepID,
      status: status,
      content: content,
      targetDraftID: targetDraftID,
      resolvedAt: resolvedAt
    )
  }

  public var command: WorkbenchAutomationCommandID? {
    WorkbenchAIAgentToolInvocation.command(for: toolID)
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID, correlationID, toolID, modelToolName, catalogRevision
    case automationStepID, command, status, content, targetDraftID, targetDraftVersion
    case resolvedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    automationStepID = try container.decodeIfPresent(UUID.self, forKey: .automationStepID)
    if let toolID = try container.decodeIfPresent(AIAgentToolID.self, forKey: .toolID) {
      self.toolID = toolID
      modelToolName =
        try container.decodeIfPresent(String.self, forKey: .modelToolName) ?? toolID.rawValue
      catalogRevision =
        try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        ?? WorkbenchAIAgentToolInvocation.legacyCatalogRevision
    } else {
      let command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
      toolID = WorkbenchAIAgentToolInvocation.toolID(for: command)
      modelToolName = command.rawValue
      catalogRevision = WorkbenchAIAgentToolInvocation.legacyCatalogRevision
    }
    correlationID =
      try container.decodeIfPresent(UUID.self, forKey: .correlationID)
      ?? automationStepID
      ?? WorkbenchAIAgentToolRunRecord.stableLegacyCorrelationID(toolCallID: toolCallID)
    status = try container.decode(WorkbenchAIAgentToolResolutionStatus.self, forKey: .status)
    content = try container.decode(String.self, forKey: .content)
    targetDraftID = try container.decodeIfPresent(UUID.self, forKey: .targetDraftID)
    targetDraftVersion = try container.decodeIfPresent(Date.self, forKey: .targetDraftVersion)
    resolvedAt = try container.decode(Date.self, forKey: .resolvedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(toolID, forKey: .toolID)
    try container.encode(modelToolName, forKey: .modelToolName)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encodeIfPresent(automationStepID, forKey: .automationStepID)
    try container.encode(status, forKey: .status)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(targetDraftID, forKey: .targetDraftID)
    try container.encodeIfPresent(targetDraftVersion, forKey: .targetDraftVersion)
    try container.encode(resolvedAt, forKey: .resolvedAt)
  }
}

/// A crash-safe snapshot of an Agent round waiting for user decisions. The
/// counters are persisted for diagnostics and migration, but resume always
/// recomputes them from the transcript after `trustedBoundaryIndex`.
public struct WorkbenchAIAgentLoopCheckpoint: Codable, Hashable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var transcript: [AIChatMessage]
  /// Zero-based index of the exact trusted tool-result system message.
  public var trustedBoundaryIndex: Int
  /// Zero-based index where assistant/tool messages produced by this Agent
  /// run begin. Earlier chat history remains part of the transcript byte
  /// budget, but must not be counted as Agent rounds or tool calls.
  public var agentTranscriptStartIndex: Int
  public var limits: WorkbenchAIAgentLoopLimits
  public var catalogRevision: String
  public var allowedToolIDs: Set<AIAgentToolID>
  public var pendingCalls: [WorkbenchAIAgentLoopPendingCall]
  public var toolRuns: [WorkbenchAIAgentToolRunRecord]
  public var modelRoundCount: Int
  public var toolCallCount: Int
  public var totalArgumentByteCount: Int
  public var totalToolResultByteCount: Int
  public var totalAssistantByteCount: Int
  public var totalTranscriptByteCount: Int

  public init(
    schemaVersion: Int = WorkbenchAIAgentLoopCheckpoint.currentSchemaVersion,
    transcript: [AIChatMessage],
    trustedBoundaryIndex: Int,
    agentTranscriptStartIndex: Int,
    limits: WorkbenchAIAgentLoopLimits,
    catalogRevision: String,
    allowedToolIDs: Set<AIAgentToolID>,
    pendingCalls: [WorkbenchAIAgentLoopPendingCall],
    toolRuns: [WorkbenchAIAgentToolRunRecord],
    modelRoundCount: Int,
    toolCallCount: Int,
    totalArgumentByteCount: Int,
    totalToolResultByteCount: Int,
    totalAssistantByteCount: Int,
    totalTranscriptByteCount: Int
  ) {
    self.schemaVersion = schemaVersion
    self.transcript = transcript
    self.trustedBoundaryIndex = trustedBoundaryIndex
    self.agentTranscriptStartIndex = agentTranscriptStartIndex
    self.limits = limits
    self.catalogRevision = catalogRevision
    self.allowedToolIDs = allowedToolIDs
    self.pendingCalls = pendingCalls
    self.toolRuns = toolRuns
    self.modelRoundCount = modelRoundCount
    self.toolCallCount = toolCallCount
    self.totalArgumentByteCount = totalArgumentByteCount
    self.totalToolResultByteCount = totalToolResultByteCount
    self.totalAssistantByteCount = totalAssistantByteCount
    self.totalTranscriptByteCount = totalTranscriptByteCount
  }

  public init(
    schemaVersion: Int = WorkbenchAIAgentLoopCheckpoint.currentSchemaVersion,
    transcript: [AIChatMessage],
    trustedBoundaryIndex: Int,
    agentTranscriptStartIndex: Int,
    limits: WorkbenchAIAgentLoopLimits,
    allowedCommands: Set<WorkbenchAutomationCommandID>,
    pendingCalls: [WorkbenchAIAgentLoopPendingCall],
    toolRuns: [WorkbenchAIAgentToolRunRecord],
    modelRoundCount: Int,
    toolCallCount: Int,
    totalArgumentByteCount: Int,
    totalToolResultByteCount: Int,
    totalAssistantByteCount: Int,
    totalTranscriptByteCount: Int
  ) {
    self.init(
      schemaVersion: schemaVersion,
      transcript: transcript,
      trustedBoundaryIndex: trustedBoundaryIndex,
      agentTranscriptStartIndex: agentTranscriptStartIndex,
      limits: limits,
      catalogRevision: WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision,
      allowedToolIDs: Set(allowedCommands.map(WorkbenchAIAgentToolInvocation.toolID)),
      pendingCalls: pendingCalls,
      toolRuns: toolRuns,
      modelRoundCount: modelRoundCount,
      toolCallCount: toolCallCount,
      totalArgumentByteCount: totalArgumentByteCount,
      totalToolResultByteCount: totalToolResultByteCount,
      totalAssistantByteCount: totalAssistantByteCount,
      totalTranscriptByteCount: totalTranscriptByteCount
    )
  }

  /// Legacy built-in view. External IDs are excluded rather than converted.
  public var allowedCommands: Set<WorkbenchAutomationCommandID> {
    Set(allowedToolIDs.compactMap(WorkbenchAIAgentToolInvocation.command))
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, transcript, trustedBoundaryIndex, agentTranscriptStartIndex, limits
    case catalogRevision, allowedToolIDs, allowedCommands, pendingCalls, toolRuns
    case modelRoundCount, toolCallCount, totalArgumentByteCount, totalToolResultByteCount
    case totalAssistantByteCount, totalTranscriptByteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    transcript = try container.decode([AIChatMessage].self, forKey: .transcript)
    trustedBoundaryIndex = try container.decode(Int.self, forKey: .trustedBoundaryIndex)
    agentTranscriptStartIndex = try container.decode(Int.self, forKey: .agentTranscriptStartIndex)
    limits = try container.decode(WorkbenchAIAgentLoopLimits.self, forKey: .limits)
    if schemaVersion == 1 {
      let commands = try container.decode(
        Set<WorkbenchAutomationCommandID>.self, forKey: .allowedCommands)
      allowedToolIDs = Set(commands.map(WorkbenchAIAgentToolInvocation.toolID))
      catalogRevision = WorkbenchAIAgentToolInvocation.legacyCatalogRevision
    } else {
      catalogRevision = try container.decode(String.self, forKey: .catalogRevision)
      allowedToolIDs = try container.decode(Set<AIAgentToolID>.self, forKey: .allowedToolIDs)
    }
    pendingCalls = try container.decode(
      [WorkbenchAIAgentLoopPendingCall].self, forKey: .pendingCalls)
    toolRuns = try container.decode([WorkbenchAIAgentToolRunRecord].self, forKey: .toolRuns)
    modelRoundCount = try container.decode(Int.self, forKey: .modelRoundCount)
    toolCallCount = try container.decode(Int.self, forKey: .toolCallCount)
    totalArgumentByteCount = try container.decode(Int.self, forKey: .totalArgumentByteCount)
    totalToolResultByteCount = try container.decode(Int.self, forKey: .totalToolResultByteCount)
    totalAssistantByteCount = try container.decode(Int.self, forKey: .totalAssistantByteCount)
    totalTranscriptByteCount = try container.decode(Int.self, forKey: .totalTranscriptByteCount)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(transcript, forKey: .transcript)
    try container.encode(trustedBoundaryIndex, forKey: .trustedBoundaryIndex)
    try container.encode(agentTranscriptStartIndex, forKey: .agentTranscriptStartIndex)
    try container.encode(limits, forKey: .limits)
    if schemaVersion == 1 {
      let commands = allowedToolIDs.compactMap(WorkbenchAIAgentToolInvocation.command)
      guard commands.count == allowedToolIDs.count else {
        throw EncodingError.invalidValue(
          allowedToolIDs,
          EncodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "A schema-v1 checkpoint cannot encode external tool IDs."
          )
        )
      }
      try container.encode(Set(commands), forKey: .allowedCommands)
    } else {
      try container.encode(catalogRevision, forKey: .catalogRevision)
      try container.encode(allowedToolIDs, forKey: .allowedToolIDs)
    }
    try container.encode(pendingCalls, forKey: .pendingCalls)
    try container.encode(toolRuns, forKey: .toolRuns)
    try container.encode(modelRoundCount, forKey: .modelRoundCount)
    try container.encode(toolCallCount, forKey: .toolCallCount)
    try container.encode(totalArgumentByteCount, forKey: .totalArgumentByteCount)
    try container.encode(totalToolResultByteCount, forKey: .totalToolResultByteCount)
    try container.encode(totalAssistantByteCount, forKey: .totalAssistantByteCount)
    try container.encode(totalTranscriptByteCount, forKey: .totalTranscriptByteCount)
  }
}

public struct WorkbenchAIAgentLoopResult: Hashable, Sendable {
  public var termination: WorkbenchAIAgentLoopTermination
  public var transcript: [AIChatMessage]
  public var assistantText: [String]
  public var pendingPlan: WorkbenchAutomationPlan?
  public var pendingInvocations: [WorkbenchAIAgentToolInvocation]
  public var checkpoint: WorkbenchAIAgentLoopCheckpoint?
  public var toolRuns: [WorkbenchAIAgentToolRunRecord]
  public var modelRoundCount: Int
  public var toolCallCount: Int
  public var totalArgumentByteCount: Int
  public var totalToolResultByteCount: Int
  public var totalAssistantByteCount: Int
  public var totalTranscriptByteCount: Int

  public init(
    termination: WorkbenchAIAgentLoopTermination,
    transcript: [AIChatMessage],
    assistantText: [String],
    pendingPlan: WorkbenchAutomationPlan? = nil,
    pendingInvocations: [WorkbenchAIAgentToolInvocation] = [],
    checkpoint: WorkbenchAIAgentLoopCheckpoint? = nil,
    toolRuns: [WorkbenchAIAgentToolRunRecord] = [],
    modelRoundCount: Int,
    toolCallCount: Int,
    totalArgumentByteCount: Int,
    totalToolResultByteCount: Int,
    totalAssistantByteCount: Int,
    totalTranscriptByteCount: Int
  ) {
    self.termination = termination
    self.transcript = transcript
    self.assistantText = assistantText
    self.pendingPlan = pendingPlan
    self.pendingInvocations = pendingInvocations
    self.checkpoint = checkpoint
    self.toolRuns = toolRuns
    self.modelRoundCount = modelRoundCount
    self.toolCallCount = toolCallCount
    self.totalArgumentByteCount = totalArgumentByteCount
    self.totalToolResultByteCount = totalToolResultByteCount
    self.totalAssistantByteCount = totalAssistantByteCount
    self.totalTranscriptByteCount = totalTranscriptByteCount
  }
}

public typealias WorkbenchAIAgentModelTransport =
  @MainActor @Sendable (
    AIChatCompletionRequest
  ) async throws -> AIChatCompletionResult

public typealias WorkbenchAIAgentDateProvider = @Sendable () -> Date

public typealias WorkbenchAIAgentAutomaticExecutor =
  @MainActor @Sendable (
    WorkbenchAIAgentToolInvocation
  ) async throws -> WorkbenchAIAgentToolResult

@available(*, deprecated, renamed: "WorkbenchAIAgentAutomaticExecutor")
public typealias WorkbenchAIAgentReadOnlyExecutor = WorkbenchAIAgentAutomaticExecutor
