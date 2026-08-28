import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAIAgentToolRegistryTests: XCTestCase {
  func testBuiltInCatalogExactlyMirrorsExposedAutomationDefinitions() {
    let registry = WorkbenchAutomationAgentToolRegistry()
    let expectedDefinitions = WorkbenchAutomationRegistry.agentToolDefinitions

    XCTAssertEqual(
      registry.catalog.descriptors.map(\.definition),
      expectedDefinitions
    )
    XCTAssertEqual(
      registry.catalog.descriptors.map(\.id.rawValue),
      expectedDefinitions.map { "workbench/\($0.function.name)" }
    )
    XCTAssertEqual(
      registry.catalog.revision, WorkbenchAutomationAgentToolRegistry.builtInCatalogRevision)
    XCTAssertFalse(
      registry.catalog.descriptors.contains {
        $0.definition.function.name == WorkbenchAutomationCommandID.webSearch.rawValue
      })
    XCTAssertFalse(registry.catalog.descriptors.contains { $0.id.rawValue.contains("*") })

    for descriptor in registry.catalog.descriptors {
      let command = WorkbenchAutomationCommandID(rawValue: descriptor.definition.function.name)
      XCTAssertEqual(command.map(WorkbenchAutomationAgentToolRegistry.toolID(for:)), descriptor.id)
      XCTAssertEqual(
        command.map { [WorkbenchAutomationRegistry.requiredPermission(for: $0)] },
        descriptor.requiredScopes
      )
      XCTAssertEqual(
        command.flatMap(WorkbenchAutomationRegistry.descriptor(for:))?.allowsAgentAutomaticExecution
          == true
          ? .automatic : .requiresConfirmation,
        descriptor.executionPolicy
      )
    }
  }

  func testPolicyAllowlistUsesStableBuiltInIDsAndDoesNotExposeHiddenCommands() {
    let allowed = WorkbenchAutomationAgentToolRegistry.allowedToolIDs(
      allowedBy: .legacySafeDefault,
      masterEnabled: true
    )

    XCTAssertTrue(allowed.contains(.init("workbench/draftRead")))
    XCTAssertTrue(allowed.contains(.init("workbench/createDraft")))
    XCTAssertFalse(allowed.contains(.init("workbench/replaceBody")))
    XCTAssertFalse(allowed.contains(.init("workbench/webSearch")))
    XCTAssertTrue(
      WorkbenchAutomationAgentToolRegistry.allowedToolIDs(
        allowedBy: .all,
        masterEnabled: false
      ).isEmpty
    )
  }

  func testPrepareRejectsUnknownAndNotAllowedTools() throws {
    let registry = WorkbenchAutomationAgentToolRegistry(
      allowedBy: .legacySafeDefault,
      masterEnabled: true
    )
    let context = WorkbenchAIAgentContext(goal: "test")

    assertRegistryError(
      .unknownTool("mcp/anything"),
      from: registry,
      call: AIToolCall(
        id: "unknown",
        function: AIToolFunctionCall(name: "mcp/anything", arguments: "{}")
      ),
      context: context
    )
    assertRegistryError(
      .toolNotAllowed(.init("workbench/replaceBody")),
      from: registry,
      call: AIToolCall(
        id: "blocked",
        function: AIToolFunctionCall(name: "replaceBody", arguments: "{}")
      ),
      context: context
    )
    assertRegistryError(
      .invalidJSON(toolCallID: "bad-json"),
      from: registry,
      call: AIToolCall(
        id: "bad-json",
        function: AIToolFunctionCall(name: "draftRead", arguments: "{")
      ),
      context: context
    )
  }

  func testRevalidationFailsClosedForForgedIdentityRevisionAndPayload() throws {
    let draftID = UUID()
    let context = WorkbenchAIAgentContext(
      goal: "test",
      draftVersions: [draftID: Date(timeIntervalSince1970: 1_000)]
    )
    let registry = WorkbenchAutomationAgentToolRegistry(
      allowedBy: .legacySafeDefault,
      masterEnabled: true
    )
    let call = AIToolCall(
      id: "read",
      function: AIToolFunctionCall(
        name: "draftRead",
        arguments: #"{"draftID":"\#(draftID.uuidString)","mode":"full"}"#
      )
    )
    let invocation = try registry.prepare(call: call, context: context)
    XCTAssertEqual(
      try registry.revalidate(invocation: invocation, matching: call, context: context), invocation)

    var forgedID = invocation
    forgedID.toolID = .init("workbench/searchDrafts")
    assertCatalogDrift(registry, invocation: forgedID, call: call, context: context)

    var forgedName = invocation
    forgedName.modelToolName = "searchDrafts"
    assertCatalogDrift(registry, invocation: forgedName, call: call, context: context)

    var forgedRevision = invocation
    forgedRevision.catalogRevision = "other"
    assertCatalogDrift(registry, invocation: forgedRevision, call: call, context: context)

    let mismatchedPayload = AIToolCall(
      id: call.id,
      function: AIToolFunctionCall(
        name: call.function.name,
        arguments: #"{"draftID":"\#(draftID.uuidString)","mode":"outline"}"#
      )
    )
    assertCatalogDrift(registry, invocation: invocation, call: mismatchedPayload, context: context)
  }

  private func assertRegistryError(
    _ expected: WorkbenchAIAgentToolRegistryError,
    from registry: WorkbenchAutomationAgentToolRegistry,
    call: AIToolCall,
    context: WorkbenchAIAgentContext,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try registry.prepare(call: call, context: context),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? WorkbenchAIAgentToolRegistryError, expected, file: file, line: line)
    }
  }

  private func assertCatalogDrift(
    _ registry: WorkbenchAutomationAgentToolRegistry,
    invocation: WorkbenchAIAgentToolInvocation,
    call: AIToolCall,
    context: WorkbenchAIAgentContext,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try registry.revalidate(invocation: invocation, matching: call, context: context),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? WorkbenchAIAgentToolRegistryError, .catalogDrift, file: file, line: line)
    }
  }
}
