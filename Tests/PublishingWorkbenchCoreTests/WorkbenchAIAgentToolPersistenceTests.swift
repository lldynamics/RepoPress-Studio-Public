import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAIAgentToolPersistenceTests: XCTestCase {
  func testExternalToolRunIdentityRoundTripsWithoutBecomingACommand() throws {
    let toolID = AIAgentToolID("example.weather/current")
    let version = Date(timeIntervalSince1970: 42)
    let run = WorkbenchAIAgentToolRunRecord(
      toolCallID: "external-1",
      toolID: toolID,
      modelToolName: "weather_now",
      executionPolicy: .automatic,
      catalogRevision: "catalog-42",
      status: .awaitingConfirmation,
      summary: "等待外部工具确认",
      correlationID: UUID(),
      targetDraftID: UUID(),
      targetDraftVersion: version,
      startedAt: version
    )

    XCTAssertEqual(try roundTrip(run), run)
    XCTAssertNil(try roundTrip(run).command)
  }

  func testCommandOnlyToolRunMapsToBuiltInIdentity() throws {
    let stepID = UUID()
    let current = WorkbenchAIAgentToolRunRecord(
      toolCallID: "legacy-call",
      command: .knowledgeRead,
      status: .awaitingConfirmation,
      summary: "旧记录",
      automationStepID: stepID,
      startedAt: Date(timeIntervalSince1970: 1)
    )
    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(current))
        as? [String: Any]
    )
    for key in ["toolID", "modelToolName", "executionPolicy", "catalogRevision", "correlationID"] {
      legacyObject.removeValue(forKey: key)
    }
    legacyObject["command"] = WorkbenchAutomationCommandID.knowledgeRead.rawValue

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchAIAgentToolRunRecord.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )

    XCTAssertEqual(decoded.toolID, AIAgentToolID("workbench/knowledgeRead"))
    XCTAssertEqual(decoded.command, .knowledgeRead)
    XCTAssertEqual(decoded.catalogRevision, "workbench-legacy-v1")
    XCTAssertEqual(decoded.executionPolicy, .requiresConfirmation)
    XCTAssertEqual(decoded.correlationID, stepID)
    XCTAssertEqual(try roundTrip(decoded), decoded)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder.workbench.decode(Value.self, from: JSONEncoder.workbench.encode(value))
  }
}
