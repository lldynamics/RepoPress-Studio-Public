import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatToolRunPersistenceTests: XCTestCase {
  func testRetiredAgentContinuationIsDroppedWhenAnOldMessageIsDecoded() throws {
    let run = WorkbenchAIAgentToolRunRecord(
      toolCallID: "persisted-review",
      command: .replaceBody,
      status: .awaitingConfirmation,
      summary: "waiting",
      startedAt: Date(timeIntervalSince1970: 101)
    )
    let message = AIPublishingChatMessage(role: .assistant, content: "review", toolRuns: [run])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(message))
        as? [String: Any]
    )
    object["agentContinuation"] = [
      "schemaVersion": 3,
      "phase": "awaitingReview",
      "checkpoint": ["schemaVersion": 2, "pendingCalls": []],
    ]

    let decoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    let savedAgain = try JSONEncoder.workbench.encode(decoded)

    XCTAssertEqual(decoded.content, "review")
    XCTAssertEqual(decoded.toolRuns, [run])
    XCTAssertFalse(String(decoding: savedAgain, as: UTF8.self).contains("agentContinuation"))
  }

  func testToolRunsRoundTripWithChatMessage() throws {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let completedAt = Date(timeIntervalSince1970: 1_002)
    let automationStepID = UUID()
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "已完成资料检索。",
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "knowledge-1",
          command: .knowledgeSearch,
          status: .succeeded,
          summary: "返回 2 条允许远程 AI 使用的资料。",
          automationStepID: automationStepID,
          startedAt: startedAt,
          completedAt: completedAt
        )
      ]
    )

    let decoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONEncoder.workbench.encode(message)
    )

    XCTAssertEqual(decoded.toolRuns, message.toolRuns)
    XCTAssertEqual(decoded.toolRuns.first?.automationStepID, automationStepID)
  }

  func testRejectedToolRunStatusRoundTripsWithAutomationStepID() throws {
    let stepID = UUID()
    let record = WorkbenchAIAgentToolRunRecord(
      toolCallID: "rejected-1",
      command: .knowledgeRead,
      status: .rejected,
      summary: "该操作已被审阅决策拒绝。",
      automationStepID: stepID,
      startedAt: Date(timeIntervalSince1970: 2_000),
      completedAt: Date(timeIntervalSince1970: 2_001)
    )

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchAIAgentToolRunRecord.self,
      from: JSONEncoder.workbench.encode(record)
    )

    XCTAssertEqual(decoded, record)
    XCTAssertEqual(decoded.status, .rejected)
    XCTAssertEqual(decoded.automationStepID, stepID)
  }

  func testLegacyToolRunWithoutAutomationStepIDDecodesAsNil() throws {
    let record = WorkbenchAIAgentToolRunRecord(
      toolCallID: "legacy-1",
      command: .knowledgeRead,
      status: .succeeded,
      summary: "旧记录",
      startedAt: Date(timeIntervalSince1970: 3_000),
      completedAt: Date(timeIntervalSince1970: 3_001)
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(record)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "automationStepID")

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchAIAgentToolRunRecord.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(decoded.automationStepID)
    XCTAssertEqual(decoded.toolCallID, record.toolCallID)
    XCTAssertEqual(decoded.status, record.status)
  }

  func testLegacyMessageWithoutToolRunsDefaultsToEmpty() throws {
    let message = AIPublishingChatMessage(role: .assistant, content: "旧消息")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(message)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "toolRuns")

    let decoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertTrue(decoded.toolRuns.isEmpty)
  }

  func testPersistedToolRunSummaryIsDisplayOnlyAndNotAddedToLaterModelTranscript() throws {
    let privateSummaryMarker = "DISPLAY_ONLY_TOOL_SUMMARY"
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "用户可见的最终回答。",
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "display-only",
          command: .knowledgeRead,
          status: .succeeded,
          summary: privateSummaryMarker,
          startedAt: Date(),
          completedAt: Date()
        )
      ]
    )
    let transcript = AIPublishingAssistantService().chatMessages(
      for: AIChatRequest(
        messages: [message],
        context: .general()
      )
    )
    let encodedTranscript =
      String(
        data: try JSONEncoder().encode(transcript),
        encoding: .utf8
      ) ?? ""

    XCTAssertTrue(encodedTranscript.contains("用户可见的最终回答。"))
    XCTAssertFalse(encodedTranscript.contains(privateSummaryMarker))
  }
}
