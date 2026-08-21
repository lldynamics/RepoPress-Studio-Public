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

public struct WorkbenchAIAgentToolInvocation: Hashable, Sendable {
  public var toolCallID: String
  public var step: WorkbenchAutomationStep

  public init(toolCallID: String, step: WorkbenchAutomationStep) {
    self.toolCallID = toolCallID
    self.step = step
  }
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

public struct WorkbenchAIAgentToolRunRecord: Codable, Identifiable, Hashable, Sendable {
  public static let maximumSummaryLength = 512

  public var toolCallID: String
  public var id: String { toolCallID }
  public var command: WorkbenchAutomationCommandID
  public var status: WorkbenchAIAgentToolRunStatus
  public var summary: String
  public var automationStepID: UUID?
  public var targetDraftID: UUID?
  public var startedAt: Date
  public var completedAt: Date?

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
    self.toolCallID = toolCallID
    self.command = command
    self.status = status
    self.summary = Self.boundedSummary(summary)
    self.automationStepID = automationStepID
    self.targetDraftID = targetDraftID
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID
    case command
    case status
    case summary
    case automationStepID
    case targetDraftID
    case startedAt
    case completedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
    status = try container.decode(WorkbenchAIAgentToolRunStatus.self, forKey: .status)
    summary = Self.boundedSummary(try container.decode(String.self, forKey: .summary))
    automationStepID = try container.decodeIfPresent(UUID.self, forKey: .automationStepID)
    targetDraftID = try container.decodeIfPresent(UUID.self, forKey: .targetDraftID)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
  }

  private static func boundedSummary(_ summary: String) -> String {
    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maximumSummaryLength else { return normalized }
    return String(normalized.prefix(maximumSummaryLength - 3)) + "..."
  }
}

/// A tool call paused at the review boundary. The full step is persisted so a
/// resumed loop can validate the call again instead of trusting a mutable UI
/// plan or a caller-supplied command name.
public struct WorkbenchAIAgentLoopPendingCall: Codable, Hashable, Sendable {
  public var toolCallID: String
  public var automationStepID: UUID
  public var command: WorkbenchAutomationCommandID
  public var targetDraftID: UUID?
  public var step: WorkbenchAutomationStep

  public init(
    toolCallID: String,
    automationStepID: UUID,
    command: WorkbenchAutomationCommandID,
    targetDraftID: UUID?,
    step: WorkbenchAutomationStep
  ) {
    self.toolCallID = toolCallID
    self.automationStepID = automationStepID
    self.command = command
    self.targetDraftID = targetDraftID
    self.step = step
  }
}

public enum WorkbenchAIAgentToolResolutionStatus: String, Codable, Hashable, Sendable {
  case succeeded
  case failed
  case rejected
  case cancelled

  public var isTerminal: Bool { true }
}

/// The complete, bounded result of one user-resolved pending tool call. This
/// is deliberately separate from `WorkbenchAIAgentToolRunRecord.summary`:
/// summaries are for local UI history, while this content is the exact,
/// bounded payload appended to the next model request.
public struct WorkbenchAIAgentToolResolution: Codable, Hashable, Sendable {
  public static let maximumContentByteCount = 64 * 1_024

  public var toolCallID: String
  public var automationStepID: UUID
  public var command: WorkbenchAutomationCommandID
  public var status: WorkbenchAIAgentToolResolutionStatus
  public var content: String
  public var targetDraftID: UUID?
  public var resolvedAt: Date

  public init(
    toolCallID: String,
    automationStepID: UUID,
    command: WorkbenchAutomationCommandID,
    status: WorkbenchAIAgentToolResolutionStatus,
    content: String,
    targetDraftID: UUID? = nil,
    resolvedAt: Date = Date()
  ) {
    self.toolCallID = toolCallID
    self.automationStepID = automationStepID
    self.command = command
    self.status = status
    self.content = content
    self.targetDraftID = targetDraftID
    self.resolvedAt = resolvedAt
  }
}

/// A crash-safe snapshot of an Agent round waiting for user decisions. The
/// counters are persisted for diagnostics and migration, but resume always
/// recomputes them from the transcript after `trustedBoundaryIndex`.
public struct WorkbenchAIAgentLoopCheckpoint: Codable, Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var transcript: [AIChatMessage]
  /// Zero-based index of the exact trusted tool-result system message.
  public var trustedBoundaryIndex: Int
  /// Zero-based index where assistant/tool messages produced by this Agent
  /// run begin. Earlier chat history remains part of the transcript byte
  /// budget, but must not be counted as Agent rounds or tool calls.
  public var agentTranscriptStartIndex: Int
  public var limits: WorkbenchAIAgentLoopLimits
  public var allowedCommands: Set<WorkbenchAutomationCommandID>
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
    self.schemaVersion = schemaVersion
    self.transcript = transcript
    self.trustedBoundaryIndex = trustedBoundaryIndex
    self.agentTranscriptStartIndex = agentTranscriptStartIndex
    self.limits = limits
    self.allowedCommands = allowedCommands
    self.pendingCalls = pendingCalls
    self.toolRuns = toolRuns
    self.modelRoundCount = modelRoundCount
    self.toolCallCount = toolCallCount
    self.totalArgumentByteCount = totalArgumentByteCount
    self.totalToolResultByteCount = totalToolResultByteCount
    self.totalAssistantByteCount = totalAssistantByteCount
    self.totalTranscriptByteCount = totalTranscriptByteCount
  }
}

public struct WorkbenchAIAgentLoopResult: Hashable, Sendable {
  public var termination: WorkbenchAIAgentLoopTermination
  public var transcript: [AIChatMessage]
  public var assistantText: [String]
  public var pendingPlan: WorkbenchAutomationPlan?
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
