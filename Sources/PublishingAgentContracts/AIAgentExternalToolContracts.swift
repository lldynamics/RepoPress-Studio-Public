import Foundation
import PublishingAICore

/// The host-neutral context available while an external tool call is prepared.
/// Draft state and other Workbench-owned data deliberately stay out of this
/// contract so transport modules cannot acquire application-layer authority.
public struct AIAgentToolContext: Hashable, Sendable {
  public var goal: String

  public init(goal: String) {
    self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// An authority-bearing external tool invocation. Unlike the Workbench
/// persistence envelope, this type cannot represent automation or a missing
/// external binding.
public struct AIAgentExternalToolInvocation: Codable, Hashable, Sendable {
  public var toolCallID: String
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var executionPolicy: AIAgentToolExecutionPolicy
  public var catalogRevision: String
  public var correlationID: UUID
  public var externalToolBinding: AIAgentExternalToolBinding

  public init(
    toolCallID: String,
    toolID: AIAgentToolID,
    modelToolName: String,
    executionPolicy: AIAgentToolExecutionPolicy,
    catalogRevision: String,
    correlationID: UUID = UUID(),
    externalToolBinding: AIAgentExternalToolBinding
  ) {
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.executionPolicy = executionPolicy
    self.catalogRevision = catalogRevision
    self.correlationID = correlationID
    self.externalToolBinding = externalToolBinding
  }
}

public struct AIAgentToolResult: Hashable, Sendable {
  public var content: String
  public var isError: Bool

  public init(content: String, isError: Bool = false) {
    self.content = content
    self.isError = isError
  }
}

/// Errors separate malformed model input from authority or catalog drift.
public enum AIAgentToolRegistryError: Error, Equatable, Sendable {
  case unknownTool(String)
  case toolNotAllowed(AIAgentToolID)
  case invalidJSON(toolCallID: String)
  case argumentMismatch(toolCallID: String, toolName: String)
  case catalogDrift
}

/// The application-neutral boundary between a model tool call and an external
/// executable capability. A later discovery snapshot must create a new
/// registry instance rather than silently mutating reviewed calls.
public protocol AIAgentExternalToolRegistry: Sendable {
  var catalog: AIAgentToolCatalogSnapshot { get }

  func prepare(
    call: AIToolCall,
    context: AIAgentToolContext
  ) throws -> AIAgentExternalToolInvocation

  func revalidate(
    invocation: AIAgentExternalToolInvocation,
    matching call: AIToolCall,
    context: AIAgentToolContext
  ) throws -> AIAgentExternalToolInvocation
}
