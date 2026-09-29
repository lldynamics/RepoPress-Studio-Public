import XCTest

@testable import PublishingWorkbenchCore

final class WorkbenchAIAgentToolRegistryTests: XCTestCase {
  func testBuiltInToolIDsRoundTripEveryAutomationCommand() {
    for command in WorkbenchAutomationCommandID.allCases {
      let toolID = WorkbenchAutomationAgentToolRegistry.toolID(for: command)
      XCTAssertEqual(toolID.rawValue, "workbench/\(command.rawValue)")
      XCTAssertEqual(WorkbenchAutomationAgentToolRegistry.command(for: toolID), command)
    }
  }

  func testForeignOrUnknownToolIDsDoNotMapToWorkbenchCommands() {
    XCTAssertNil(WorkbenchAutomationAgentToolRegistry.command(for: .init("draftRead")))
    XCTAssertNil(WorkbenchAutomationAgentToolRegistry.command(for: .init("external/draftRead")))
    XCTAssertNil(WorkbenchAutomationAgentToolRegistry.command(for: .init("workbench/unknown")))
  }
}
