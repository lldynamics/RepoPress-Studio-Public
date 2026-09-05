import Foundation
import PublishingAICore
import XCTest

@testable import PublishingAgentContracts

final class AIAgentExternalToolContractsTests: XCTestCase {
  func testContextTrimsGoalWithoutWorkbenchState() {
    XCTAssertEqual(AIAgentToolContext(goal: "  inspect repository\n").goal, "inspect repository")
  }

  func testInvocationRoundTripsItsAuthorityBinding() throws {
    let invocation = AIAgentExternalToolInvocation(
      toolCallID: "call-1",
      toolID: AIAgentToolID("mcp/example/echo"),
      modelToolName: "mcp_example_echo",
      executionPolicy: .requiresConfirmation,
      catalogRevision: "catalog-v1",
      correlationID: UUID(uuidString: "8B67CE0C-FA08-4EE4-A84D-C53C05F5404A")!,
      externalToolBinding: AIAgentExternalToolBinding(
        sourceID: "example",
        sourceRevision: "source-v1",
        remoteToolName: "echo",
        argumentsJSON: #"{"value":"hello"}"#
      )
    )

    let encoded = try JSONEncoder().encode(invocation)
    XCTAssertEqual(
      try JSONDecoder().decode(AIAgentExternalToolInvocation.self, from: encoded),
      invocation
    )
  }

  func testToolResultAndRegistryErrorsRemainApplicationNeutral() {
    XCTAssertEqual(AIAgentToolResult(content: "ok"), AIAgentToolResult(content: "ok"))
    XCTAssertEqual(
      AIAgentToolRegistryError.argumentMismatch(toolCallID: "call-2", toolName: "echo"),
      .argumentMismatch(toolCallID: "call-2", toolName: "echo")
    )
  }
}
