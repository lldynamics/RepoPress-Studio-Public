import PublishingAgentContracts

/// Projects an application-neutral external registry into the durable
/// Workbench invocation envelope used by the Agent loop and checkpoints.
public struct WorkbenchExternalAgentToolRegistryAdapter<
  Registry: AIAgentExternalToolRegistry
>: WorkbenchAIAgentToolRegistry, Sendable {
  public let registry: Registry

  public var catalog: AIAgentToolCatalogSnapshot { registry.catalog }

  public init(_ registry: Registry) {
    self.registry = registry
  }

  public func prepare(
    call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    let prepared = try registry.prepare(
      call: call,
      context: AIAgentToolContext(goal: context.goal)
    )
    return Self.workbenchInvocation(from: prepared)
  }

  public func revalidate(
    invocation: WorkbenchAIAgentToolInvocation,
    matching call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    guard invocation.automationStep == nil,
      invocation.targetDraftID == nil,
      invocation.targetDraftVersion == nil,
      let binding = invocation.externalToolBinding
    else {
      throw AIAgentToolRegistryError.catalogDrift
    }

    let reviewed = AIAgentExternalToolInvocation(
      toolCallID: invocation.toolCallID,
      toolID: invocation.toolID,
      modelToolName: invocation.modelToolName,
      executionPolicy: invocation.executionPolicy,
      catalogRevision: invocation.catalogRevision,
      correlationID: invocation.correlationID,
      externalToolBinding: binding
    )
    let revalidated = try registry.revalidate(
      invocation: reviewed,
      matching: call,
      context: AIAgentToolContext(goal: context.goal)
    )
    return Self.workbenchInvocation(from: revalidated)
  }

  public func workbenchResult(from result: AIAgentToolResult) -> WorkbenchAIAgentToolResult {
    WorkbenchAIAgentToolResult(content: result.content, isError: result.isError)
  }

  private static func workbenchInvocation(
    from invocation: AIAgentExternalToolInvocation
  ) -> WorkbenchAIAgentToolInvocation {
    WorkbenchAIAgentToolInvocation(
      toolCallID: invocation.toolCallID,
      toolID: invocation.toolID,
      modelToolName: invocation.modelToolName,
      executionPolicy: invocation.executionPolicy,
      catalogRevision: invocation.catalogRevision,
      correlationID: invocation.correlationID,
      externalToolBinding: invocation.externalToolBinding
    )
  }
}
