import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAgentReviewDecisionTests: XCTestCase {
  func testReviewDecisionRoundTripsAndLegacyMessageDefaultsToEmptyDecisions() throws {
    let decision = AIPublishingChatReviewDecision(
      choice: .accepted,
      planID: UUID(),
      stepID: UUID(),
      toolCallID: "tool-1",
      decidedAt: Date(timeIntervalSince1970: 1_234),
      previewBaselineFingerprint: "baseline"
    )
    let message = AIPublishingChatMessage(
      role: .assistant, content: "review", reviewDecisions: [decision])
    let encoded = try JSONEncoder.workbench.encode(message)
    let decoded = try JSONDecoder.workbench.decode(AIPublishingChatMessage.self, from: encoded)
    XCTAssertEqual(decoded.reviewDecisions, [decision])

    let transcript = AIPublishingAssistantService().chatMessages(
      for: AIChatRequest(messages: [message], context: .general())
    )
    let encodedTranscript =
      String(data: try JSONEncoder().encode(transcript), encoding: .utf8) ?? ""
    XCTAssertTrue(encodedTranscript.contains("review"))
    XCTAssertFalse(encodedTranscript.contains("tool-1"))
    XCTAssertFalse(encodedTranscript.contains("baseline"))

    var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyObject.removeValue(forKey: "reviewDecisions")
    let legacyDecoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    XCTAssertTrue(legacyDecoded.reviewDecisions.isEmpty)
  }

  func testAcceptIsRetiredAndLeavesReviewHistoryAndDraftUntouched() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewAcceptRetired")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(in: store, draft: draft, replacementBody: "不得应用")
    let beforeMessage = try message(
      fixture.messageID, conversationID: fixture.conversationID, in: store)
    let beforeDraft = try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
    let beforeVersions = store.versions(for: draft.id).count
    let beforeRuns = store.automationRunRecords

    let result = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )

    XCTAssertNil(result)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id }), beforeDraft)
    XCTAssertEqual(store.versions(for: draft.id).count, beforeVersions)
    XCTAssertEqual(store.automationRunRecords, beforeRuns)
    XCTAssertEqual(
      try message(fixture.messageID, conversationID: fixture.conversationID, in: store),
      beforeMessage)
  }

  func testRejectIsRetiredAndLeavesReviewHistoryAndDraftUntouched() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewRejectRetired")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(in: store, draft: draft, replacementBody: "不得拒绝写回")
    let beforeMessage = try message(
      fixture.messageID, conversationID: fixture.conversationID, in: store)
    let beforeRuns = store.automationRunRecords

    let result = await store.rejectAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )

    XCTAssertFalse(result)
    XCTAssertEqual(store.automationRunRecords, beforeRuns)
    XCTAssertEqual(
      try message(fixture.messageID, conversationID: fixture.conversationID, in: store),
      beforeMessage)
  }

  func testExecuteRejectsRetiredAgentRecordWithoutChangingHistory() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewExecuteRetired")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(in: store, draft: draft, replacementBody: "不得执行")
    let beforeMessage = try message(
      fixture.messageID, conversationID: fixture.conversationID, in: store)
    let beforeDraft = try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))

    let result = await store.executeAutomationPlan(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID
    )

    XCTAssertNil(result)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id }), beforeDraft)
    XCTAssertEqual(
      try message(fixture.messageID, conversationID: fixture.conversationID, in: store),
      beforeMessage)
  }

  func testCancelRetiredAgentHistoryIsReadOnly() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewCancelRetired")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(in: store, draft: draft, replacementBody: "不得取消写回")
    let beforeMessage = try message(
      fixture.messageID, conversationID: fixture.conversationID, in: store)

    store.cancelAutomationPlan(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID
    )

    XCTAssertEqual(
      try message(fixture.messageID, conversationID: fixture.conversationID, in: store),
      beforeMessage)
    XCTAssertTrue(store.automationRunRecords.isEmpty)
  }

  func testBranchCancelsCopiedAgentReviewWithoutMutatingOrigin() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewBranchBinding")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(in: store, draft: draft, replacementBody: "分支不得应用")
    let branch = try XCTUnwrap(
      store.branchAIChatConversation(after: fixture.messageID, draft: draft))
    XCTAssertNotEqual(branch.id, fixture.conversationID)

    let copiedMessage = try message(fixture.messageID, conversationID: branch.id, in: store)
    XCTAssertNil(copiedMessage.agentContinuation)
    XCTAssertEqual(copiedMessage.automationPlan?.steps.first?.status, .cancelled)
    XCTAssertEqual(copiedMessage.toolRuns.first?.status, .cancelled)

    let originMessage = try message(
      fixture.messageID, conversationID: fixture.conversationID, in: store)
    XCTAssertEqual(originMessage.automationPlan?.steps.first?.status, .awaitingConfirmation)
    XCTAssertEqual(originMessage.toolRuns.first?.status, .awaitingConfirmation)
    XCTAssertTrue(originMessage.reviewDecisions.isEmpty)
  }

  private struct PendingReviewFixture {
    var conversationID: UUID
    var messageID: UUID
    var stepID: UUID
    var baseline: String
  }

  private func installPendingReview(
    in store: WorkbenchStore,
    draft: ArticleDraft,
    replacementBody: String
  ) throws -> PendingReviewFixture {
    let conversation = try XCTUnwrap(store.startNewAIChatConversation(draft: draft))
    let step = WorkbenchAutomationStep(
      command: .replaceBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        content: replacementBody
      ),
      status: .awaitingConfirmation
    )
    let plan = WorkbenchAutomationPlan(goal: "修改正文", steps: [step], source: .agentLoop)
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "请审阅修改",
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "tool-\(step.id.uuidString)",
          toolID: AIAgentToolID.replaceBody,
          modelToolName: WorkbenchAutomationCommandID.replaceBody.rawValue,
          executionPolicy: .requiresConfirmation,
          catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
          status: .awaitingConfirmation,
          summary: "等待用户确认",
          correlationID: step.id,
          automationStepID: step.id,
          targetDraftID: draft.id,
          startedAt: Date()
        )
      ],
      automationPlan: plan
    )
    store.aiStore.updateAIChatSession(for: draft.id) { messages in
      messages.append(message)
    }
    let preview = try XCTUnwrap(
      store.automationDraftPreview(
        conversationID: conversation.id, messageID: message.id, stepID: step.id))
    return PendingReviewFixture(
      conversationID: conversation.id,
      messageID: message.id,
      stepID: step.id,
      baseline: preview.originalDraft.repositoryContentFingerprint
    )
  }

  private func message(
    _ messageID: UUID,
    conversationID: UUID,
    in store: WorkbenchStore
  ) throws -> AIPublishingChatMessage {
    let conversation = try XCTUnwrap(
      store.aiConversations.first(where: { $0.id == conversationID }))
    return try XCTUnwrap(conversation.messages.first(where: { $0.id == messageID }))
  }
}
