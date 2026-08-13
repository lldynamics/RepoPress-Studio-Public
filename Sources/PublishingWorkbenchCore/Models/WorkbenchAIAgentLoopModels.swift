import Foundation

public struct WorkbenchAIAgentLoopLimits: Hashable, Sendable {
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
  case invalidJSON(toolCallID: String)
  case argumentMismatch(toolCallID: String, toolName: String)
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

  public init(content: String, isError: Bool = false) {
    self.content = content
    self.isError = isError
  }
}

public struct WorkbenchAIAgentLoopResult: Hashable, Sendable {
  public var termination: WorkbenchAIAgentLoopTermination
  public var transcript: [AIChatMessage]
  public var assistantText: [String]
  public var pendingPlan: WorkbenchAutomationPlan?
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

public typealias WorkbenchAIAgentReadOnlyExecutor =
  @MainActor @Sendable (
    WorkbenchAIAgentToolInvocation
  ) async throws -> WorkbenchAIAgentToolResult
