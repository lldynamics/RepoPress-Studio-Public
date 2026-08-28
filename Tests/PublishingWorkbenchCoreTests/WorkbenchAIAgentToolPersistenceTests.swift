import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAIAgentToolPersistenceTests: XCTestCase {
  func testExternalToolIdentityRoundTripsAcrossPersistedModels() throws {
    let toolID = AIAgentToolID("example.weather/current")
    let correlationID = UUID()
    let draftID = UUID()
    let version = Date(timeIntervalSince1970: 42)
    let externalBinding = AIAgentExternalToolBinding(
      sourceID: "example.weather",
      sourceRevision: "config-42",
      remoteToolName: "current",
      argumentsJSON: #"{"city":"Shanghai"}"#
    )
    let invocation = WorkbenchAIAgentToolInvocation(
      toolCallID: "external-1",
      toolID: toolID,
      modelToolName: "weather_now",
      executionPolicy: .automatic,
      catalogRevision: "catalog-42",
      correlationID: correlationID,
      targetDraftID: draftID,
      targetDraftVersion: version,
      externalToolBinding: externalBinding
    )
    let pending = WorkbenchAIAgentLoopPendingCall(
      toolCallID: invocation.toolCallID,
      correlationID: correlationID,
      toolID: toolID,
      modelToolName: invocation.modelToolName,
      executionPolicy: invocation.executionPolicy,
      catalogRevision: invocation.catalogRevision,
      targetDraftID: draftID,
      targetDraftVersion: version,
      externalToolBinding: externalBinding
    )
    let run = WorkbenchAIAgentToolRunRecord(
      toolCallID: invocation.toolCallID,
      toolID: toolID,
      modelToolName: invocation.modelToolName,
      executionPolicy: invocation.executionPolicy,
      catalogRevision: invocation.catalogRevision,
      status: .awaitingConfirmation,
      summary: "等待外部工具确认",
      correlationID: correlationID,
      targetDraftID: draftID,
      targetDraftVersion: version,
      startedAt: version
    )
    let resolution = WorkbenchAIAgentToolResolution(
      toolCallID: invocation.toolCallID,
      correlationID: correlationID,
      toolID: toolID,
      modelToolName: invocation.modelToolName,
      catalogRevision: invocation.catalogRevision,
      status: .succeeded,
      content: "晴朗",
      targetDraftID: draftID,
      targetDraftVersion: version,
      resolvedAt: version
    )
    let checkpoint = WorkbenchAIAgentLoopCheckpoint(
      transcript: [],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 0,
      limits: .default,
      catalogRevision: "catalog-42",
      allowedToolIDs: [toolID],
      pendingCalls: [pending],
      toolRuns: [run],
      modelRoundCount: 0,
      toolCallCount: 1,
      totalArgumentByteCount: 0,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 0
    )

    XCTAssertEqual(try roundTrip(invocation), invocation)
    XCTAssertEqual(try roundTrip(run), run)
    XCTAssertEqual(try roundTrip(resolution), resolution)
    XCTAssertEqual(try roundTrip(checkpoint), checkpoint)
    XCTAssertEqual(try roundTrip(checkpoint).pendingCalls[0].externalToolBinding, externalBinding)
    XCTAssertNil(WorkbenchAutomationRegistry.agentCommand(for: try roundTrip(run).toolID))
    XCTAssertFalse(
      String(decoding: try JSONEncoder.workbench.encode(run), as: UTF8.self)
        .contains("Shanghai")
    )
    XCTAssertFalse(
      String(decoding: try JSONEncoder.workbench.encode(resolution), as: UTF8.self)
        .contains("Shanghai")
    )
  }

  func testSchemaVersionOneMapsKnownBuiltInCommandsWithoutUpgradingSchema() throws {
    let step = WorkbenchAutomationStep(
      command: .knowledgeRead,
      arguments: WorkbenchAutomationArguments(documentID: UUID())
    )
    let pending = WorkbenchAIAgentLoopPendingCall(
      toolCallID: "legacy-call",
      correlationID: step.id,
      toolID: WorkbenchAutomationAgentToolRegistry.toolID(for: .knowledgeRead),
      modelToolName: WorkbenchAutomationCommandID.knowledgeRead.rawValue,
      executionPolicy: .requiresConfirmation,
      catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
      automationStepID: step.id,
      targetDraftID: nil,
      targetDraftVersion: nil,
      externalToolBinding: nil,
      automationStep: step
    )
    let run = WorkbenchAIAgentToolRunRecord(
      toolCallID: "legacy-call",
      toolID: WorkbenchAutomationAgentToolRegistry.toolID(for: .knowledgeRead),
      modelToolName: WorkbenchAutomationCommandID.knowledgeRead.rawValue,
      executionPolicy: .requiresConfirmation,
      catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
      status: .awaitingConfirmation,
      summary: "旧记录",
      correlationID: step.id,
      automationStepID: step.id,
      targetDraftID: nil,
      targetDraftVersion: nil,
      startedAt: Date(timeIntervalSince1970: 1),
      completedAt: nil
    )
    let current = WorkbenchAIAgentLoopCheckpoint(
      transcript: [],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 0,
      limits: .default,
      catalogRevision: "catalog-current",
      allowedToolIDs: [AIAgentToolID("workbench/knowledgeRead")],
      pendingCalls: [pending],
      toolRuns: [run],
      modelRoundCount: 0,
      toolCallCount: 0,
      totalArgumentByteCount: 0,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 0
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(current)) as? [String: Any]
    )
    object["schemaVersion"] = 1
    object.removeValue(forKey: "catalogRevision")
    object.removeValue(forKey: "allowedToolIDs")
    object["allowedCommands"] = [WorkbenchAutomationCommandID.knowledgeRead.rawValue]
    var pendingObject = try XCTUnwrap((object["pendingCalls"] as? [[String: Any]])?.first)
    pendingObject.removeValue(forKey: "correlationID")
    pendingObject.removeValue(forKey: "toolID")
    pendingObject.removeValue(forKey: "modelToolName")
    pendingObject.removeValue(forKey: "executionPolicy")
    pendingObject.removeValue(forKey: "catalogRevision")
    pendingObject.removeValue(forKey: "targetDraftVersion")
    pendingObject["command"] = WorkbenchAutomationCommandID.knowledgeRead.rawValue
    pendingObject["step"] = pendingObject.removeValue(forKey: "automationStep")
    object["pendingCalls"] = [pendingObject]
    var runObject = try XCTUnwrap((object["toolRuns"] as? [[String: Any]])?.first)
    runObject.removeValue(forKey: "correlationID")
    runObject.removeValue(forKey: "toolID")
    runObject.removeValue(forKey: "modelToolName")
    runObject.removeValue(forKey: "executionPolicy")
    runObject.removeValue(forKey: "catalogRevision")
    runObject.removeValue(forKey: "targetDraftVersion")
    runObject["command"] = WorkbenchAutomationCommandID.knowledgeRead.rawValue
    object["toolRuns"] = [runObject]

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchAIAgentLoopCheckpoint.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertEqual(decoded.catalogRevision, "workbench-legacy-v1")
    XCTAssertEqual(decoded.allowedToolIDs, [AIAgentToolID("workbench/knowledgeRead")])
    XCTAssertEqual(decoded.pendingCalls.first?.toolID, AIAgentToolID("workbench/knowledgeRead"))
    XCTAssertEqual(decoded.pendingCalls.first?.automationStep, step)
    XCTAssertEqual(decoded.toolRuns.first?.toolID, AIAgentToolID("workbench/knowledgeRead"))
    XCTAssertEqual(try roundTrip(decoded), decoded)
  }

  func testSchemaVersionOneUnknownBuiltInCommandFailsClosed() throws {
    let data = try legacyCheckpointData(allowedCommands: ["not-a-command"])
    XCTAssertThrowsError(
      try JSONDecoder.workbench.decode(WorkbenchAIAgentLoopCheckpoint.self, from: data)
    )
  }

  private func legacyCheckpointData(allowedCommands: [String]) throws -> Data {
    let current = WorkbenchAIAgentLoopCheckpoint(
      transcript: [],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 0,
      limits: .default,
      catalogRevision: "catalog-current",
      allowedToolIDs: [],
      pendingCalls: [],
      toolRuns: [],
      modelRoundCount: 0,
      toolCallCount: 0,
      totalArgumentByteCount: 0,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 0
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(current)) as? [String: Any]
    )
    object["schemaVersion"] = 1
    object.removeValue(forKey: "catalogRevision")
    object.removeValue(forKey: "allowedToolIDs")
    object["allowedCommands"] = allowedCommands
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder.workbench.decode(Value.self, from: JSONEncoder.workbench.encode(value))
  }
}
