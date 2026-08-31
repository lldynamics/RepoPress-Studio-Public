import Foundation
import PublishingAgentContracts

/// The narrow, host-owned boundary between model tool calls and executable
/// Workbench capabilities. A registry snapshot is immutable for its lifetime;
/// a later catalog must be represented by a new registry instance.
public protocol WorkbenchAIAgentToolRegistry: Sendable {
  var catalog: AIAgentToolCatalogSnapshot { get }

  func prepare(
    call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation

  /// Re-parses the model call immediately before execution or resume. The
  /// returned invocation preserves the reviewed correlation identity only
  /// after every authority-bearing field matches the fresh parse.
  func revalidate(
    invocation: WorkbenchAIAgentToolInvocation,
    matching call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation
}

/// Errors deliberately separate malformed/untrusted input from a changed
/// catalog. The Agent loop can therefore report a rejected tool call without
/// treating it as a transport failure.
public typealias WorkbenchAIAgentToolRegistryError = AIAgentToolRegistryError

/// The built-in adapter. It retains the existing Workbench command parser and
/// validator while giving it a source-qualified, stable host identity.
public struct WorkbenchAutomationAgentToolRegistry: WorkbenchAIAgentToolRegistry {
  public static let builtInCatalogRevision = "workbench-builtins-v1"

  public let catalog: AIAgentToolCatalogSnapshot

  /// Creates a catalog containing only the explicitly allowed built-in tool
  /// IDs. Passing `nil` is useful for internal callers which need the complete
  /// built-in catalog; production Agent sessions should use the policy-based
  /// initializer below.
  public init(allowedToolIDs: Set<AIAgentToolID>? = nil) {
    let descriptors = Self.allDescriptors.filter { descriptor in
      allowedToolIDs?.contains(descriptor.id) ?? true
    }
    do {
      catalog = try AIAgentToolCatalogSnapshot(
        revision: Self.builtInCatalogRevision,
        descriptors: descriptors
      )
    } catch {
      preconditionFailure("Built-in Agent tool catalog is invalid: \(error)")
    }
  }

  public init(
    allowedBy policy: AIAgentPermissionPolicy,
    masterEnabled: Bool
  ) {
    self.init(
      allowedToolIDs: Self.allowedToolIDs(
        allowedBy: policy,
        masterEnabled: masterEnabled
      )
    )
  }

  public static func toolID(
    for command: WorkbenchAutomationCommandID
  ) -> AIAgentToolID {
    AIAgentToolID("workbench/\(command.rawValue)")
  }

  public static func command(
    for toolID: AIAgentToolID
  ) -> WorkbenchAutomationCommandID? {
    let prefix = "workbench/"
    guard toolID.rawValue.hasPrefix(prefix) else { return nil }
    let rawValue = String(toolID.rawValue.dropFirst(prefix.count))
    guard let command = WorkbenchAutomationCommandID(rawValue: rawValue),
      Self.toolID(for: command) == toolID
    else {
      return nil
    }
    return command
  }

  public static func allowedToolIDs(
    allowedBy policy: AIAgentPermissionPolicy,
    masterEnabled: Bool
  ) -> Set<AIAgentToolID> {
    Set(
      WorkbenchAutomationRegistry.agentCommands(
        allowedBy: policy,
        masterEnabled: masterEnabled
      )
      .map(toolID(for:))
    )
  }

  public func prepare(
    call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    let name = call.function.name
    guard let command = WorkbenchAutomationCommandID(rawValue: name),
      let descriptor = Self.descriptor(for: command)
    else {
      throw WorkbenchAIAgentToolRegistryError.unknownTool(name)
    }

    guard catalog.descriptors.contains(where: { $0.id == descriptor.id }) else {
      throw WorkbenchAIAgentToolRegistryError.toolNotAllowed(descriptor.id)
    }

    let step: WorkbenchAutomationStep
    do {
      step = try WorkbenchAutomationRegistry.agentStep(
        for: call,
        draftVersions: context.draftVersions
      )
    } catch let error as WorkbenchAutomationAgentToolError {
      switch error {
      case .unknownTool:
        throw WorkbenchAIAgentToolRegistryError.unknownTool(name)
      case .invalidJSON:
        throw WorkbenchAIAgentToolRegistryError.invalidJSON(toolCallID: call.id)
      case .argumentMismatch:
        throw WorkbenchAIAgentToolRegistryError.argumentMismatch(
          toolCallID: call.id,
          toolName: name
        )
      }
    } catch {
      throw WorkbenchAIAgentToolRegistryError.argumentMismatch(
        toolCallID: call.id,
        toolName: name
      )
    }

    return WorkbenchAIAgentToolInvocation(
      toolCallID: call.id,
      toolID: descriptor.id,
      modelToolName: name,
      executionPolicy: descriptor.executionPolicy,
      catalogRevision: catalog.revision,
      correlationID: step.id,
      targetDraftID: step.arguments.draftID,
      targetDraftVersion: step.arguments.expectedDraftUpdatedAt,
      automationStep: step
    )
  }

  public func revalidate(
    invocation: WorkbenchAIAgentToolInvocation,
    matching call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    guard invocation.toolCallID == call.id,
      invocation.catalogRevision == catalog.revision,
      let reviewedStep = invocation.automationStep,
      invocation.correlationID == reviewedStep.id,
      let command = Self.command(for: invocation.toolID),
      let descriptor = Self.descriptor(for: command),
      descriptor.id == invocation.toolID,
      invocation.modelToolName == descriptor.definition.function.name,
      call.function.name == descriptor.definition.function.name,
      invocation.executionPolicy == descriptor.executionPolicy,
      invocation.externalToolBinding == nil
    else {
      throw WorkbenchAIAgentToolRegistryError.catalogDrift
    }

    let fresh = try prepare(call: call, context: context)
    guard fresh.toolID == invocation.toolID,
      fresh.modelToolName == invocation.modelToolName,
      fresh.executionPolicy == invocation.executionPolicy,
      fresh.catalogRevision == invocation.catalogRevision,
      fresh.targetDraftID == invocation.targetDraftID,
      fresh.targetDraftVersion == invocation.targetDraftVersion,
      fresh.externalToolBinding == invocation.externalToolBinding,
      fresh.automationStep?.command == reviewedStep.command,
      fresh.automationStep?.arguments == reviewedStep.arguments
    else {
      throw WorkbenchAIAgentToolRegistryError.catalogDrift
    }

    return invocation
  }

  private static let allDescriptors: [AIAgentToolDescriptor] = {
    WorkbenchAutomationRegistry.agentToolDefinitions.compactMap { definition in
      guard let command = WorkbenchAutomationCommandID(rawValue: definition.function.name) else {
        return nil
      }
      return AIAgentToolDescriptor(
        id: toolID(for: command),
        definition: definition,
        requiredScopes: [WorkbenchAutomationRegistry.requiredPermission(for: command)],
        executionPolicy: WorkbenchAutomationRegistry.descriptor(for: command)?
          .allowsAgentAutomaticExecution == true ? .automatic : .requiresConfirmation
      )
    }
  }()

  private static func descriptor(
    for command: WorkbenchAutomationCommandID
  ) -> AIAgentToolDescriptor? {
    allDescriptors.first { $0.id == toolID(for: command) }
  }
}
