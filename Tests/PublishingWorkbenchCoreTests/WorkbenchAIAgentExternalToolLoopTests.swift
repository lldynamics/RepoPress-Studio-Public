import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAIAgentExternalToolLoopTests: XCTestCase {
  func testAutomaticExternalToolRunsWithoutWorkbenchProjection() async throws {
    let transport = ExternalToolTransport(responses: [
      AIChatCompletionResult(
        content: "",
        toolCalls: [Self.call(id: "external-auto")]
      ),
      AIChatCompletionResult(content: "done"),
    ])
    let executions = ExternalToolExecutions()
    let service = WorkbenchAIAgentLoopService(
      modelTransport: { try await transport.complete($0) },
      toolRegistry: try Self.registry(policy: .automatic),
      grantedScopes: [.localRead],
      automaticExecutor: { invocation in
        await executions.record(invocation)
        return WorkbenchAIAgentToolResult(content: "external result")
      }
    )

    let result = await service.run(
      request: Self.request(),
      context: WorkbenchAIAgentContext(goal: "external"),
      toolCallingSupport: .supported
    )

    XCTAssertEqual(result.termination, .completed)
    XCTAssertEqual(result.assistantText, ["done"])
    XCTAssertEqual(result.toolRuns.map(\.toolID), [.init("mcp/example.echo")])
    XCTAssertNil(result.toolRuns.first?.automationStepID)
    let executionCount = await executions.count()
    XCTAssertEqual(executionCount, 1)
  }

  func testExternalReviewCheckpointResumesWithoutWorkbenchPlan() async throws {
    let transport = ExternalToolTransport(responses: [
      AIChatCompletionResult(
        content: "review",
        toolCalls: [Self.call(id: "external-review")]
      ),
      AIChatCompletionResult(content: "continued"),
    ])
    let service = WorkbenchAIAgentLoopService(
      modelTransport: { try await transport.complete($0) },
      toolRegistry: try Self.registry(policy: .requiresConfirmation),
      grantedScopes: [.localRead],
      automaticExecutor: { _ in
        XCTFail("Reviewed calls must not enter the automatic executor")
        return WorkbenchAIAgentToolResult(content: "unexpected", isError: true)
      }
    )
    let context = WorkbenchAIAgentContext(goal: "external review")

    let paused = await service.run(
      request: Self.request(),
      context: context,
      toolCallingSupport: .supported
    )
    let checkpoint = try XCTUnwrap(paused.checkpoint)
    let pending = try XCTUnwrap(checkpoint.pendingCalls.first)
    XCTAssertEqual(paused.termination, .awaitingReview)
    XCTAssertNil(paused.pendingPlan)
    XCTAssertEqual(paused.pendingInvocations.map(\.toolID), [.init("mcp/example.echo")])
    XCTAssertNil(pending.automationStep)

    let resumed = await service.resume(
      request: Self.request(),
      context: context,
      toolCallingSupport: .supported,
      checkpoint: checkpoint,
      resolutions: [
        WorkbenchAIAgentToolResolution(
          resolving: pending,
          status: .succeeded,
          content: "approved external result"
        )
      ]
    )

    XCTAssertEqual(resumed.termination, .completed)
    XCTAssertEqual(resumed.assistantText, ["continued"])
    XCTAssertEqual(resumed.toolRuns.map(\.status), [.succeeded])
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testCatalogRevisionDriftRejectsBeforeTransport() async throws {
    let firstTransport = ExternalToolTransport(responses: [
      AIChatCompletionResult(
        content: "review",
        toolCalls: [Self.call(id: "drift")]
      )
    ])
    let firstService = WorkbenchAIAgentLoopService(
      modelTransport: { try await firstTransport.complete($0) },
      toolRegistry: try Self.registry(
        revision: "external-v1",
        policy: .requiresConfirmation
      ),
      grantedScopes: [.localRead],
      automaticExecutor: { _ in WorkbenchAIAgentToolResult(content: "unexpected") }
    )
    let context = WorkbenchAIAgentContext(goal: "drift")
    let paused = await firstService.run(
      request: Self.request(),
      context: context,
      toolCallingSupport: .supported
    )
    let checkpoint = try XCTUnwrap(paused.checkpoint)
    let pending = try XCTUnwrap(checkpoint.pendingCalls.first)
    let resumedTransport = ExternalToolTransport(responses: [
      AIChatCompletionResult(content: "must not be used")
    ])
    let resumedService = WorkbenchAIAgentLoopService(
      modelTransport: { try await resumedTransport.complete($0) },
      toolRegistry: try Self.registry(
        revision: "external-v2",
        policy: .requiresConfirmation
      ),
      grantedScopes: [.localRead],
      automaticExecutor: { _ in WorkbenchAIAgentToolResult(content: "unexpected") }
    )

    let result = await resumedService.resume(
      request: Self.request(),
      context: context,
      toolCallingSupport: .supported,
      checkpoint: checkpoint,
      resolutions: [
        WorkbenchAIAgentToolResolution(
          resolving: pending,
          status: .succeeded,
          content: "approved"
        )
      ]
    )

    XCTAssertEqual(result.termination, .rejected(.invalidContinuation))
    let requestCount = await resumedTransport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testMissingGrantedScopeRejectsBeforeExternalExecution() async throws {
    let transport = ExternalToolTransport(responses: [
      AIChatCompletionResult(
        content: "",
        toolCalls: [Self.call(id: "scope-denied")]
      )
    ])
    let executions = ExternalToolExecutions()
    let service = WorkbenchAIAgentLoopService(
      modelTransport: { try await transport.complete($0) },
      toolRegistry: try Self.registry(policy: .automatic),
      grantedScopes: [],
      automaticExecutor: { invocation in
        await executions.record(invocation)
        return WorkbenchAIAgentToolResult(content: "unexpected")
      }
    )

    let result = await service.run(
      request: Self.request(),
      context: WorkbenchAIAgentContext(goal: "scope denied"),
      toolCallingSupport: .supported
    )

    XCTAssertEqual(result.termination, .rejected(.toolNotAllowed("external_echo")))
    let executionCount = await executions.count()
    XCTAssertEqual(executionCount, 0)
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].tools?.isEmpty, true)
  }

  func testAutomaticExternalToolRevalidatesImmediatelyBeforeExecution() async throws {
    let transport = ExternalToolTransport(responses: [
      AIChatCompletionResult(
        content: "",
        toolCalls: [Self.call(id: "revalidate")]
      )
    ])
    let executions = ExternalToolExecutions()
    let service = WorkbenchAIAgentLoopService(
      modelTransport: { try await transport.complete($0) },
      toolRegistry: try Self.registry(
        policy: .automatic,
        rejectsRevalidation: true
      ),
      grantedScopes: [.localRead],
      automaticExecutor: { invocation in
        await executions.record(invocation)
        return WorkbenchAIAgentToolResult(content: "unexpected")
      }
    )

    let result = await service.run(
      request: Self.request(),
      context: WorkbenchAIAgentContext(goal: "revalidate"),
      toolCallingSupport: .supported
    )

    XCTAssertEqual(result.termination, .rejected(.invalidContinuation))
    let executionCount = await executions.count()
    XCTAssertEqual(executionCount, 0)
  }

  private static func request() -> AIChatCompletionRequest {
    AIChatCompletionRequest(
      model: "fixture",
      messages: [AIChatMessage(role: "user", content: "use external tool")]
    )
  }

  private static func registry(
    revision: String = "external-v1",
    policy: AIAgentToolExecutionPolicy,
    rejectsRevalidation: Bool = false
  ) throws -> WorkbenchExternalAgentToolRegistryAdapter<ExternalToolRegistry> {
    try WorkbenchExternalAgentToolRegistryAdapter(
      ExternalToolRegistry(
        revision: revision,
        policy: policy,
        rejectsRevalidation: rejectsRevalidation
      )
    )
  }

  private static func call(id: String) -> AIToolCall {
    AIToolCall(
      id: id,
      function: AIToolFunctionCall(
        name: "external_echo",
        arguments: #"{"value":"hello"}"#
      )
    )
  }
}

private struct ExternalToolRegistry: AIAgentExternalToolRegistry {
  let catalog: AIAgentToolCatalogSnapshot
  let rejectsRevalidation: Bool

  init(
    revision: String = "external-v1",
    policy: AIAgentToolExecutionPolicy,
    rejectsRevalidation: Bool = false
  ) throws {
    self.rejectsRevalidation = rejectsRevalidation
    catalog = try AIAgentToolCatalogSnapshot(
      revision: revision,
      descriptors: [
        AIAgentToolDescriptor(
          id: AIAgentToolID("mcp/example.echo"),
          definition: AIToolDefinition(
            function: AIToolFunctionDefinition(
              name: "external_echo",
              description: "Echoes a value through an external test tool.",
              parameters: .object(["type": .string("object")]),
              strict: true
            )
          ),
          requiredScopes: [.localRead],
          executionPolicy: policy
        )
      ]
    )
  }

  func prepare(
    call: AIToolCall,
    context _: AIAgentToolContext
  ) throws -> AIAgentExternalToolInvocation {
    guard call.function.name == "external_echo" else {
      throw AIAgentToolRegistryError.unknownTool(call.function.name)
    }
    guard call.function.arguments == #"{"value":"hello"}"# else {
      throw AIAgentToolRegistryError.argumentMismatch(
        toolCallID: call.id,
        toolName: call.function.name
      )
    }
    let descriptor = catalog.descriptors[0]
    return AIAgentExternalToolInvocation(
      toolCallID: call.id,
      toolID: descriptor.id,
      modelToolName: descriptor.definition.function.name,
      executionPolicy: descriptor.executionPolicy,
      catalogRevision: catalog.revision,
      externalToolBinding: AIAgentExternalToolBinding(
        sourceID: "example",
        sourceRevision: catalog.revision,
        remoteToolName: "echo",
        argumentsJSON: call.function.arguments
      )
    )
  }

  func revalidate(
    invocation: AIAgentExternalToolInvocation,
    matching call: AIToolCall,
    context: AIAgentToolContext
  ) throws -> AIAgentExternalToolInvocation {
    if rejectsRevalidation {
      throw AIAgentToolRegistryError.catalogDrift
    }
    let fresh = try prepare(call: call, context: context)
    guard invocation.toolCallID == fresh.toolCallID,
      invocation.toolID == fresh.toolID,
      invocation.modelToolName == fresh.modelToolName,
      invocation.executionPolicy == fresh.executionPolicy,
      invocation.catalogRevision == fresh.catalogRevision,
      invocation.externalToolBinding == fresh.externalToolBinding
    else {
      throw AIAgentToolRegistryError.catalogDrift
    }
    return invocation
  }
}

private actor ExternalToolTransport {
  enum FixtureError: Error { case exhausted }

  private var responses: [AIChatCompletionResult]
  private var requests: [AIChatCompletionRequest] = []

  init(responses: [AIChatCompletionResult]) {
    self.responses = responses
  }

  func complete(_ request: AIChatCompletionRequest) throws -> AIChatCompletionResult {
    requests.append(request)
    guard !responses.isEmpty else { throw FixtureError.exhausted }
    return responses.removeFirst()
  }

  func requestCount() -> Int { requests.count }

  func recordedRequests() -> [AIChatCompletionRequest] { requests }
}

private actor ExternalToolExecutions {
  private var invocations: [WorkbenchAIAgentToolInvocation] = []

  func record(_ invocation: WorkbenchAIAgentToolInvocation) {
    invocations.append(invocation)
  }

  func count() -> Int { invocations.count }
}
