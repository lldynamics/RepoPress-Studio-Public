import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAgentDeliveryUncertainRecoveryTests: XCTestCase {
  func testTransientContinuationDecodeBecomesNonReplayableUncertainty() throws {
    let draftID = UUID()
    let conversationID = UUID()
    let messageID = UUID()
    let planID = UUID()
    let stepID = UUID()
    let continuationID = UUID()
    let attemptID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let config = testProviderConfig()
    let step = testStep(id: stepID, draftID: draftID)
    let checkpoint = testCheckpoint(step: step, draftID: draftID, now: now)

    for transientPhase in [
      AIPublishingChatAgentContinuationPhase.applyingDecision,
      .resuming,
      .sending,
    ] {
      let continuation = AIPublishingChatAgentContinuation(
        id: continuationID,
        ownerConversationID: conversationID,
        ownerScope: .draft(draftID),
        ownerMessageID: messageID,
        planID: planID,
        phase: transientPhase,
        revision: 7,
        activeStepID: stepID,
        resumeAttemptID: attemptID,
        requestTemplate: testRequest(),
        checkpoint: checkpoint,
        providerConfig: config,
        taskConfig: config,
        promptRevision: AIPublishingChatAgentPromptRevision(),
        reviewDraftFingerprint: "draft-fingerprint",
        reviewDraftUpdatedAt: now,
        createdAt: now,
        updatedAt: now
      )

      let decoded = try JSONDecoder().decode(
        AIPublishingChatAgentContinuation.self,
        from: JSONEncoder().encode(continuation)
      )

      XCTAssertEqual(decoded.phase, .deliveryUncertain)
      XCTAssertNil(decoded.activeStepID)
      XCTAssertEqual(decoded.resumeAttemptID, attemptID)
      XCTAssertEqual(decoded.revision, 7)
      XCTAssertEqual(decoded.checkpoint, checkpoint)
      XCTAssertFalse(decoded.phase.allowsAutomaticResume)
      XCTAssertTrue(decoded.phase.requiresExplicitDisposition)
    }
  }

  func testAbandonUsesExactCASAndPreservesAudit() throws {
    let fixture = try makeFixture(phase: .deliveryUncertain)
    defer { fixture.cleanup() }

    let before = try XCTUnwrap(
      fixture.store.aiStore.aiConversations.first(where: { $0.id == fixture.conversationID })?
        .messages.first(where: { $0.id == fixture.messageID })
    )
    let expectedRevision = try XCTUnwrap(before.agentContinuation?.revision)
    let continuationID = try XCTUnwrap(before.agentContinuation?.id)
    let originalCheckpoint = try XCTUnwrap(before.agentContinuation?.checkpoint)
    let originalPlan = try XCTUnwrap(before.automationPlan)
    let originalToolRuns = before.toolRuns
    let originalReviewDecisions = before.reviewDecisions
    let originalAttemptID = before.agentContinuation?.resumeAttemptID

    XCTAssertTrue(
      fixture.store.aiStore.abandonAgentContinuation(
        conversationID: fixture.conversationID,
        messageID: fixture.messageID,
        planID: fixture.planID,
        continuationID: continuationID,
        expectedRevision: expectedRevision
      )
    )

    let abandoned = try XCTUnwrap(
      fixture.store.aiStore.aiConversations.first(where: { $0.id == fixture.conversationID })?
        .messages.first(where: { $0.id == fixture.messageID })
    )
    XCTAssertEqual(abandoned.agentContinuation?.phase, .abandonedAfterDeliveryUncertain)
    XCTAssertEqual(abandoned.agentContinuation?.revision, expectedRevision + 1)
    XCTAssertEqual(abandoned.agentContinuation?.checkpoint, originalCheckpoint)
    XCTAssertEqual(abandoned.automationPlan, originalPlan)
    XCTAssertEqual(abandoned.toolRuns, originalToolRuns)
    XCTAssertEqual(abandoned.reviewDecisions, originalReviewDecisions)
    XCTAssertEqual(abandoned.agentContinuation?.resumeAttemptID, originalAttemptID)

    XCTAssertFalse(
      fixture.store.aiStore.abandonAgentContinuation(
        conversationID: fixture.conversationID,
        messageID: fixture.messageID,
        planID: fixture.planID,
        continuationID: continuationID,
        expectedRevision: expectedRevision
      )
    )
    XCTAssertFalse(
      fixture.store.aiStore.abandonAgentContinuation(
        conversationID: fixture.conversationID,
        messageID: fixture.messageID,
        planID: fixture.planID,
        continuationID: continuationID,
        expectedRevision: expectedRevision + 1
      )
    )
  }

  func testUncertainContinuationBlocksMutationButBranchKeepsOriginalAudit() async throws {
    let fixture = try makeFixture(phase: .deliveryUncertain)
    defer { fixture.cleanup() }
    let originalMessages = fixture.store.aiChatMessages

    let sent = await fixture.store.aiStore.sendAIChatMessage(
      "不应发送",
      draft: fixture.draft
    )
    XCTAssertNil(sent)
    XCTAssertEqual(fixture.store.aiChatMessages, originalMessages)

    XCTAssertNil(fixture.store.aiStore.startNewAIChatConversation(draft: fixture.draft))
    XCTAssertFalse(fixture.store.aiStore.archiveAIChatConversation(fixture.conversationID))
    XCTAssertFalse(fixture.store.aiStore.deleteAIChatConversation(fixture.conversationID))
    fixture.store.aiStore.deleteAIChatMessage(fixture.messageID, draft: fixture.draft)
    XCTAssertEqual(fixture.store.aiChatMessages, originalMessages)
    fixture.store.aiStore.clearAIChat()
    XCTAssertEqual(fixture.store.aiChatMessages, originalMessages)
    fixture.store.aiStore.aiChatContextMode = .general
    fixture.store.aiStore.clearAIChat()
    XCTAssertEqual(fixture.store.aiChatMessages, originalMessages)

    let branch = fixture.store.aiStore.branchAIChatConversation(
      after: fixture.messageID,
      draft: fixture.draft
    )
    let branchMessage = try XCTUnwrap(branch?.messages.first)
    XCTAssertNil(branchMessage.agentContinuation)

    let original = try XCTUnwrap(
      fixture.store.aiStore.aiConversations.first(where: { $0.id == fixture.conversationID })?
        .messages.first(where: { $0.id == fixture.messageID })
    )
    XCTAssertEqual(original.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertEqual(original.agentContinuation?.checkpoint, fixture.checkpoint)
  }

  private func makeFixture(
    phase: AIPublishingChatAgentContinuationPhase
  ) throws -> RecoveryFixture {
    let persistenceURL = try temporaryPersistenceURL(prefix: "AgentDeliveryUncertain")
    let store = try TestWorkbenchFactory.makeStore(fileURL: persistenceURL)
    guard let draft = store.selectedDraft else {
      throw NSError(domain: "WorkbenchAgentDeliveryUncertainRecoveryTests", code: 1)
    }

    let conversationID = UUID()
    let messageID = UUID()
    let planID = UUID()
    let stepID = UUID()
    let continuationID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let step = testStep(id: stepID, draftID: draft.id)
    let checkpoint = testCheckpoint(step: step, draftID: draft.id, now: now)
    let config = testProviderConfig()
    let continuation = AIPublishingChatAgentContinuation(
      id: continuationID,
      ownerConversationID: conversationID,
      ownerScope: .draft(draft.id),
      ownerMessageID: messageID,
      planID: planID,
      phase: phase,
      revision: 4,
      resumeAttemptID: UUID(),
      requestTemplate: testRequest(),
      checkpoint: checkpoint,
      providerConfig: config,
      taskConfig: config,
      promptRevision: AIPublishingChatAgentPromptRevision(),
      reviewDraftFingerprint: draft.repositoryContentFingerprint,
      reviewDraftUpdatedAt: draft.updatedAt,
      createdAt: now,
      updatedAt: now
    )
    let plan = WorkbenchAutomationPlan(
      id: planID,
      goal: "保留审计的测试计划",
      steps: [step],
      createdAt: now,
      source: .agentLoop
    )
    let message = AIPublishingChatMessage(
      id: messageID,
      role: .assistant,
      content: "结果不确定",
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "call-audit",
          toolID: AIAgentToolID.updateMetadata,
          modelToolName: WorkbenchAutomationCommandID.updateMetadata.rawValue,
          executionPolicy: .requiresConfirmation,
          catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
          status: .awaitingConfirmation,
          summary: "待审阅",
          correlationID: stepID,
          automationStepID: stepID,
          targetDraftID: draft.id,
          startedAt: now
        )
      ],
      reviewDecisions: [
        AIPublishingChatReviewDecision(
          choice: .rejected,
          planID: planID,
          stepID: stepID,
          toolCallID: "call-audit",
          decidedAt: now,
          previewBaselineFingerprint: draft.repositoryContentFingerprint
        )
      ],
      agentContinuation: continuation,
      automationPlan: plan,
      createdAt: now
    )
    XCTAssertNotNil(message.agentContinuation)

    let conversation = AIConversation(
      id: conversationID,
      draftID: draft.id,
      messages: [message],
      contextMode: .site,
      createdAt: now,
      updatedAt: now
    )
    store.aiStore.aiConversations = [conversation]
    store.aiStore.activeAIConversationIDsByDraftID = [draft.id: conversationID]
    store.aiStore.prepareAIChat(for: draft)
    return RecoveryFixture(
      store: store,
      draft: draft,
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      checkpoint: checkpoint,
      persistenceURL: persistenceURL
    )
  }

  private func testProviderConfig() -> AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://agent-recovery.example/v1",
      model: "agent-recovery-test",
      requiresAPIKey: false
    )
  }

  private func testRequest() -> AIChatCompletionRequest {
    AIChatCompletionRequest(
      model: "agent-recovery-test",
      messages: [AIChatMessage(role: "user", content: "resume")]
    )
  }

  private func testStep(id: UUID, draftID: UUID) -> WorkbenchAutomationStep {
    WorkbenchAutomationStep(
      id: id,
      command: .updateMetadata,
      arguments: WorkbenchAutomationArguments(
        draftID: draftID,
        metadataField: .summary,
        value: "审计保留"
      ),
      status: .awaitingConfirmation
    )
  }

  private func testCheckpoint(
    step: WorkbenchAutomationStep,
    draftID: UUID,
    now: Date
  ) -> WorkbenchAIAgentLoopCheckpoint {
    WorkbenchAIAgentLoopCheckpoint(
      transcript: [AIChatMessage(role: "user", content: "resume")],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 0,
      limits: .default,
      catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
      allowedToolIDs: [AIAgentToolID.updateMetadata],
      pendingCalls: [
        WorkbenchAIAgentLoopPendingCall(
          toolCallID: "call-audit",
          correlationID: step.id,
          toolID: AIAgentToolID.updateMetadata,
          modelToolName: step.command.rawValue,
          executionPolicy: .requiresConfirmation,
          catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
          automationStepID: step.id,
          targetDraftID: draftID,
          targetDraftVersion: nil,
          externalToolBinding: nil,
          automationStep: step
        )
      ],
      toolRuns: [
        WorkbenchAIAgentToolRunRecord(
          toolCallID: "call-audit",
          toolID: AIAgentToolID.updateMetadata,
          modelToolName: step.command.rawValue,
          executionPolicy: .requiresConfirmation,
          catalogRevision: WorkbenchAIAgentToolInvocation.legacyCatalogRevision,
          status: .awaitingConfirmation,
          summary: "待审阅",
          correlationID: step.id,
          automationStepID: step.id,
          targetDraftID: draftID,
          startedAt: now
        )
      ],
      modelRoundCount: 1,
      toolCallCount: 1,
      totalArgumentByteCount: 16,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 32
    )
  }
}

@MainActor
private struct RecoveryFixture {
  let store: WorkbenchStore
  let draft: ArticleDraft
  let conversationID: UUID
  let messageID: UUID
  let planID: UUID
  let checkpoint: WorkbenchAIAgentLoopCheckpoint
  let persistenceURL: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: persistenceURL)
  }
}
