import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAgentReviewDecisionTests: XCTestCase {
  func testReviewDecisionRoundTripsAndLegacyMessageDefaultsToEmptyDecisions() throws {
    let planID = UUID()
    let stepID = UUID()
    let decision = AIPublishingChatReviewDecision(
      choice: .accepted,
      planID: planID,
      stepID: stepID,
      toolCallID: "tool-1",
      decidedAt: Date(timeIntervalSince1970: 1_234),
      previewBaselineFingerprint: "baseline"
    )
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "review",
      reviewDecisions: [decision]
    )

    let encoded = try JSONEncoder.workbench.encode(message)
    let decoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: encoded
    )
    XCTAssertEqual(decoded.reviewDecisions, [decision])

    let transcript = AIPublishingAssistantService().chatMessages(
      for: AIChatRequest(messages: [message], context: .general())
    )
    let encodedTranscript = String(
      data: try JSONEncoder().encode(transcript),
      encoding: .utf8
    ) ?? ""
    XCTAssertTrue(encodedTranscript.contains("review"))
    XCTAssertFalse(encodedTranscript.contains("tool-1"))
    XCTAssertFalse(encodedTranscript.contains("baseline"))

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "reviewDecisions")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacyDecoded = try JSONDecoder.workbench.decode(
      AIPublishingChatMessage.self,
      from: legacyData
    )
    XCTAssertTrue(legacyDecoded.reviewDecisions.isEmpty)
  }

  func testAcceptExecutesOnceAndSynchronizesDecisionPlanToolRunAndRollbackRecord() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewAccept")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "AI 已修改的正文"
    )
    let originalVersionCount = store.versions(for: draft.id).count

    let result = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )

    XCTAssertEqual(result?.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, "AI 已修改的正文")
    XCTAssertEqual(store.versions(for: draft.id).count, originalVersionCount + 1)
    XCTAssertEqual(store.automationRunRecords.count, 1)

    let updatedMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
    XCTAssertEqual(updatedMessage.reviewDecisions.map(\.choice), [.accepted])
    XCTAssertEqual(updatedMessage.reviewDecisions.first?.previewBaselineFingerprint, fixture.baseline)
    XCTAssertEqual(updatedMessage.automationPlan?.steps.first?.status, .succeeded)
    XCTAssertEqual(updatedMessage.toolRuns.first?.status, .succeeded)
    XCTAssertNotNil(updatedMessage.toolRuns.first?.completedAt)

    let repeated = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )
    XCTAssertNil(repeated)
    XCTAssertEqual(store.versions(for: draft.id).count, originalVersionCount + 1)
    XCTAssertEqual(store.automationRunRecords.count, 1)
  }

  func testRejectIsIdempotentAndNeverMutatesDraftVersionOrRunHistory() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewReject")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "不应应用的正文"
    )
    let originalVersionCount = store.versions(for: draft.id).count
    let originalRunCount = store.automationRunRecords.count

    let firstRejection = await store.rejectAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )
    let repeatedRejection = await store.rejectAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )
    XCTAssertTrue(firstRejection)
    XCTAssertTrue(repeatedRejection)

    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id }), draft)
    XCTAssertEqual(store.versions(for: draft.id).count, originalVersionCount)
    XCTAssertEqual(store.automationRunRecords.count, originalRunCount)
    let updatedMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
    XCTAssertEqual(updatedMessage.reviewDecisions.map(\.choice), [.rejected])
    XCTAssertEqual(updatedMessage.automationPlan?.steps.first?.status, .cancelled)
    XCTAssertEqual(updatedMessage.toolRuns.first?.status, .rejected)
    XCTAssertNotNil(updatedMessage.toolRuns.first?.completedAt)

    let acceptAfterReject = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )
    XCTAssertNil(acceptAfterReject)
    XCTAssertEqual(store.versions(for: draft.id).count, originalVersionCount)
    XCTAssertEqual(store.automationRunRecords.count, originalRunCount)
  }

  func testCancellingPlanRemainsDistinctFromRejectingStep() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewCancel")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "不应执行的正文"
    )

    store.cancelAutomationPlan(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID
    )

    let updatedMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
    XCTAssertTrue(updatedMessage.reviewDecisions.isEmpty)
    XCTAssertEqual(updatedMessage.automationPlan?.steps.first?.status, .cancelled)
    XCTAssertEqual(updatedMessage.toolRuns.first?.status, .cancelled)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id }), draft)
    XCTAssertTrue(store.automationRunRecords.isEmpty)
  }

  func testAcceptFailsClosedAfterDraftDriftWithoutRecordingDecision() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewDrift")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "不应覆盖用户新正文"
    )
    var changedDraft = draft
    changedDraft.bodyMarkdown = "用户在预览后编辑的正文"
    changedDraft.updatedAt = draft.updatedAt.addingTimeInterval(1)
    store.updateDraft(changedDraft)

    let result = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )

    XCTAssertNil(result)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      "用户在预览后编辑的正文"
    )
    XCTAssertTrue(store.automationRunRecords.isEmpty)
    let unchangedMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
    XCTAssertTrue(unchangedMessage.reviewDecisions.isEmpty)
    XCTAssertEqual(unchangedMessage.automationPlan?.steps.first?.status, .awaitingConfirmation)
    XCTAssertEqual(unchangedMessage.toolRuns.first?.status, .awaitingConfirmation)
  }

  func testAcceptWritesBackToOriginConversationAfterSwitchingConversation() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewConversationBinding")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "绑定原对话的修改"
    )
    let secondConversation = try XCTUnwrap(store.startNewAIChatConversation(draft: draft))
    XCTAssertNotEqual(secondConversation.id, fixture.conversationID)
    XCTAssertTrue(store.aiChatMessages.isEmpty)

    let result = await store.acceptAutomationStep(
      conversationID: fixture.conversationID,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )

    XCTAssertEqual(result?.plan.steps.first?.status, .succeeded)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    let originMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
    XCTAssertEqual(originMessage.reviewDecisions.map(\.choice), [.accepted])
    XCTAssertEqual(originMessage.toolRuns.first?.status, .succeeded)
  }

  func testBranchCancelsCopiedAgentReviewAndCannotMutateOriginConversation() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReviewBranchBinding")
    let draft = try XCTUnwrap(store.selectedDraft)
    let fixture = try installPendingReview(
      in: store,
      draft: draft,
      replacementBody: "分支不得应用的修改"
    )

    let branch = try XCTUnwrap(
      store.branchAIChatConversation(after: fixture.messageID, draft: draft)
    )
    XCTAssertNotEqual(branch.id, fixture.conversationID)

    let copiedMessage = try message(
      fixture.messageID,
      conversationID: branch.id,
      in: store
    )
    XCTAssertNil(copiedMessage.agentContinuation)
    XCTAssertEqual(copiedMessage.automationPlan?.steps.first?.status, .cancelled)
    XCTAssertEqual(copiedMessage.toolRuns.first?.status, .cancelled)

    let branchResult = await store.acceptAutomationStep(
      conversationID: branch.id,
      messageID: fixture.messageID,
      stepID: fixture.stepID,
      previewBaselineFingerprint: fixture.baseline
    )
    XCTAssertNil(branchResult)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id }), draft)

    let originMessage = try message(
      fixture.messageID,
      conversationID: fixture.conversationID,
      in: store
    )
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
    let plan = WorkbenchAutomationPlan(
      goal: "修改正文",
      steps: [step],
      source: .agentLoop
    )
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "请审阅修改",
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "tool-\(step.id.uuidString)",
          command: .replaceBody,
          status: .awaitingConfirmation,
          summary: "等待用户确认",
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
        conversationID: conversation.id,
        messageID: message.id,
        stepID: step.id
      )
    )
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
      store.aiConversations.first(where: { $0.id == conversationID })
    )
    return try XCTUnwrap(conversation.messages.first(where: { $0.id == messageID }))
  }
}
