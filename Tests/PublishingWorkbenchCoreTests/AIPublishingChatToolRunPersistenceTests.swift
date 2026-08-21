import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatToolRunPersistenceTests: XCTestCase {
  func testAgentContinuationRoundTripsAndLegacyMessageDefaultsToNil() throws {
    let draftID = UUID()
    let messageID = UUID()
    let step = WorkbenchAutomationStep(
      command: .replaceBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draftID,
        expectedDraftUpdatedAt: Date(timeIntervalSince1970: 100),
        content: "new body"
      ),
      status: .awaitingConfirmation
    )
    let call = AIToolCall(
      id: "persisted-review",
      function: AIToolFunctionCall(
        name: WorkbenchAutomationCommandID.replaceBody.rawValue,
        arguments: #"{"draftID":"00000000-0000-0000-0000-000000000000","content":"new body"}"#
      )
    )
    let run = WorkbenchAIAgentToolRunRecord(
      toolCallID: call.id,
      command: .replaceBody,
      status: .awaitingConfirmation,
      summary: "waiting",
      automationStepID: step.id,
      targetDraftID: draftID,
      startedAt: Date(timeIntervalSince1970: 101)
    )
    let checkpoint = WorkbenchAIAgentLoopCheckpoint(
      transcript: [
        AIChatMessage(role: "system", content: "trusted boundary"),
        AIChatMessage(role: "user", content: "update"),
        AIChatMessage(role: "assistant", toolCalls: [call]),
      ],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 2,
      limits: .default,
      allowedCommands: [.replaceBody],
      pendingCalls: [
        WorkbenchAIAgentLoopPendingCall(
          toolCallID: call.id,
          automationStepID: step.id,
          command: .replaceBody,
          targetDraftID: draftID,
          step: step
        )
      ],
      toolRuns: [run],
      modelRoundCount: 1,
      toolCallCount: 1,
      totalArgumentByteCount: call.function.arguments.utf8.count,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 1
    )
    let continuation = AIPublishingChatAgentContinuation(
      ownerConversationID: UUID(),
      ownerScope: .draft(draftID),
      ownerMessageID: messageID,
      planID: UUID(),
      requestTemplate: AIChatCompletionRequest(model: "test", messages: []),
      checkpoint: checkpoint,
      providerConfig: AIProviderConfig(model: "test"),
      taskConfig: AIProviderConfig(model: "test"),
      promptRevision: AIPublishingChatAgentPromptRevision(),
      reviewDraftFingerprint: "review-baseline",
      reviewDraftUpdatedAt: Date(timeIntervalSince1970: 199),
      createdAt: Date(timeIntervalSince1970: 200),
      updatedAt: Date(timeIntervalSince1970: 201)
    )
    XCTAssertTrue(continuation.isValidForPersistence)
    let message = AIPublishingChatMessage(
      id: messageID,
      role: .assistant,
      content: "review",
      toolRuns: [run],
      agentContinuation: continuation
    )

    let encoded = try JSONEncoder.workbench.encode(message)
    let decoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: encoded
    )
    XCTAssertEqual(decoded.agentContinuation, continuation)

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var staleContinuation = try XCTUnwrap(
      legacyObject["agentContinuation"] as? [String: Any]
    )
    staleContinuation.removeValue(forKey: "promptRevision")
    staleContinuation.removeValue(forKey: "reviewDraftFingerprint")
    staleContinuation.removeValue(forKey: "reviewDraftUpdatedAt")
    var staleObject = legacyObject
    staleObject["agentContinuation"] = staleContinuation
    let staleDecoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONSerialization.data(withJSONObject: staleObject)
    )
    XCTAssertNil(staleDecoded.agentContinuation)

    legacyObject.removeValue(forKey: "agentContinuation")
    let legacy = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    XCTAssertNil(legacy.agentContinuation)
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
