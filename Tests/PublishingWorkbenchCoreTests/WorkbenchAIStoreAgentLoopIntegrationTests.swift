import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAIStoreAgentLoopIntegrationTests: XCTestCase {
  override func setUp() async throws {
    // Production defaults to automatic remote authorization. Tests that need
    // fail-closed fault injection install an explicit provider below.
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
  }

  override func tearDown() async throws {
    AIOutboundPayloadApprovalBroker.shared.cancelPendingRequest()
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
  }

  func
    testSupportedToolCallingExecutesReadOnlyToolThenCompletesWithTwoTransportsWithoutPerRequestPayloadPrompt()
    async throws
  {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("只读检查完成。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    fixture.store.setInspectorPresented(false)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("打开检查器后告诉我结果。", draft: draft)

    XCTAssertEqual(reply?.content, "只读检查完成。")
    XCTAssertEqual(reply?.toolRuns.map(\.command), [.showInspector])
    XCTAssertEqual(reply?.toolRuns.map(\.status), [.succeeded])
    XCTAssertTrue(fixture.store.isInspectorPresented)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 2)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let bodies = await fixture.transport.capturedBodies()
    XCTAssertEqual(bodies.count, 2)
    let first = try jsonBody(bodies[0])
    XCTAssertFalse((first["tools"] as? [[String: Any]] ?? []).isEmpty)
    let second = try jsonBody(bodies[1])
    let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
    XCTAssertTrue(messages.contains { ($0["role"] as? String) == "tool" })
  }

  func testSupportedToolCallingAutomaticallyCreatesDraftThenCompletesWithAuditedRecord()
    async throws
  {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "createDraft", arguments: ["value": "AI 待确认草稿"]),
        textResponse("已新建草稿。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    let originalDraftCount = fixture.store.drafts.count
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("请新建一篇草稿。", draft: draft)

    XCTAssertEqual(reply?.content, "已新建草稿。")
    XCTAssertNil(reply?.automationPlan)
    XCTAssertEqual(reply?.toolRuns.map(\.command), [.createDraft])
    XCTAssertEqual(reply?.toolRuns.map(\.status), [.succeeded])
    XCTAssertEqual(fixture.store.drafts.count, originalDraftCount + 1)
    let createdDraft = try XCTUnwrap(fixture.store.selectedDraft)
    XCTAssertEqual(createdDraft.title, "AI 待确认草稿")
    let record = try XCTUnwrap(fixture.store.automationRunRecords.first)
    XCTAssertEqual(record.steps.first?.command, .createDraft)
    XCTAssertEqual(record.steps.first?.targetDraftID, createdDraft.id)
    XCTAssertTrue(record.hasRollback)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 2)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let bodies = await fixture.transport.capturedBodies()
    let first = try jsonBody(bodies[0])
    XCTAssertTrue(
      (first["tools"] as? [[String: Any]] ?? []).contains { tool in
        ((tool["function"] as? [String: Any])?["name"] as? String) == "createDraft"
      })
    let second = try jsonBody(bodies[1])
    let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
    XCTAssertTrue(
      messages.contains { message in
        (message["role"] as? String) == "tool"
          && (message["content"] as? String)?.contains(createdDraft.id.uuidString) == true
      })
  }

  func testUnknownToolCallingCapabilityUsesOrdinaryTextPathWithoutToolDeclaration() async throws {
    let fixture = makeStore(
      responses: [textResponse("普通文本回答。")],
      toolCallingSupported: false
    )
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("不要调用工具。", draft: draft)

    XCTAssertEqual(reply?.content, "普通文本回答。")
    XCTAssertNil(reply?.automationPlan)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let capturedBodies = await fixture.transport.capturedBodies()
    let body = try jsonBody(try XCTUnwrap(capturedBodies.first))
    XCTAssertNil(body["tools"])
  }

  func testDisabledApplicationToolsUsesOrdinaryTextPathWithoutToolDeclaration() async throws {
    let fixture = makeStore(
      responses: [textResponse("已关闭应用内工具，普通文本回复。")],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var disabledConfig = fixture.config
    disabledConfig.advancedSettings = AIProviderAdvancedSettings(
      allowsApplicationTools: false
    )
    configureActiveAIConnection(in: fixture.store, config: disabledConfig)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("不要使用应用内工具。", draft: draft)

    XCTAssertEqual(reply?.content, "已关闭应用内工具，普通文本回复。")
    XCTAssertNil(reply?.automationPlan)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let bodies = await fixture.transport.capturedBodies()
    let body = try jsonBody(try XCTUnwrap(bodies.first))
    XCTAssertNil(body["tools"])
  }

  func testConversationTextOnlyModeUsesOrdinaryTextPathWithoutToolDeclaration() async throws {
    let fixture = makeStore(
      responses: [textResponse("当前对话仅问答。")],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    XCTAssertNotNil(fixture.store.startNewAIChatConversation(draft: draft))
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    XCTAssertTrue(
      fixture.store.aiStore.setAIConversationAgentMode(
        .textOnly,
        for: conversationID
      )
    )

    let reply = await fixture.store.sendAIChatMessage("只用文字回答。", draft: draft)

    XCTAssertEqual(reply?.content, "当前对话仅问答。")
    let bodies = await fixture.transport.capturedBodies()
    XCTAssertEqual(bodies.count, 1)
    XCTAssertNil(try jsonBody(try XCTUnwrap(bodies.first))["tools"])
  }

  func testRejectedAgentReviewResumesExactlyOnceInOriginConversation() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        ),
        textResponse("已按拒绝决定继续。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage(
      "把摘要改掉。",
      draft: draft
    )
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    let baseline = fixture.store.automationDraftPreview(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )?.originalDraft.repositoryContentFingerprint

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: baseline
    )

    XCTAssertTrue(rejected)
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id == draft.id })?.summary,
      draft.summary
    )
    var requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let reviewedMessage = try XCTUnwrap(
      origin.messages.first(where: { $0.id == review.id })
    )
    XCTAssertNil(reviewedMessage.agentContinuation)
    XCTAssertEqual(reviewedMessage.reviewDecisions.map(\.choice), [.rejected])
    XCTAssertEqual(origin.messages.last?.content, "已按拒绝决定继续。")
    let bodies = await fixture.transport.capturedBodies()
    let resumedMessages = try XCTUnwrap(
      try jsonBody(bodies[1])["messages"] as? [[String: Any]]
    )
    XCTAssertTrue(
      resumedMessages.contains { message in
        (message["role"] as? String) == "tool"
          && (message["content"] as? String)?.contains("\"status\":\"rejected\"") == true
      })

    let repeated = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: baseline
    )
    XCTAssertTrue(repeated)
    requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testAcceptedAgentReviewMutatesOnceThenResumesExactlyOnce() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "AI 接受后的摘要",
          ]
        ),
        textResponse("已按接受决定继续。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage(
      "更新摘要。",
      draft: draft
    )
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    let preview = try XCTUnwrap(
      fixture.store.automationDraftPreview(
        conversationID: conversationID,
        messageID: review.id,
        stepID: step.id
      )
    )
    let originalVersionCount = fixture.store.versions(for: draft.id).count

    let result = await fixture.store.acceptAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: preview.originalDraft.repositoryContentFingerprint
    )

    XCTAssertEqual(result?.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id == draft.id })?.summary,
      "AI 接受后的摘要"
    )
    XCTAssertEqual(fixture.store.versions(for: draft.id).count, originalVersionCount + 1)
    var requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    XCTAssertEqual(
      origin.messages.first(where: { $0.id == review.id })?.agentContinuation?.phase,
      nil,
      fixture.store.aiChatMessage ?? "no status"
    )
    XCTAssertEqual(origin.messages.last?.content, "已按接受决定继续。")

    let repeated = await fixture.store.acceptAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: preview.originalDraft.repositoryContentFingerprint
    )
    XCTAssertNil(repeated)
    XCTAssertEqual(fixture.store.versions(for: draft.id).count, originalVersionCount + 1)
    requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testFailedReviewContinuationBecomesDeliveryUncertainAndDoesNotReplay() async throws {
    let fixture = makeStore(
      responses: [
        AgentTransportAttempt(
          data: toolCallResponse(
            name: "updateMetadata",
            arguments: [
              "draftID": "placeholder",
              "metadataField": "summary",
              "value": "不应应用的摘要",
            ]
          )
        ),
        AgentTransportAttempt(data: textResponse("服务端未确认的回答。"), statusCode: 500),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage("把摘要改掉。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )
    XCTAssertTrue(rejected)
    let sentRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(sentRequestCount, 2)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    XCTAssertEqual(
      origin.messages.first(where: { $0.id == review.id })?.agentContinuation?.phase,
      .deliveryUncertain
    )

    let repeated = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )
    XCTAssertTrue(repeated)
    let repeatedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(repeatedRequestCount, 2)
  }

  func testCompletedContinuationPersistenceFailureRestoresUncertainAuditWithoutReplay()
    async throws
  {
    let fixture = makeStore(
      responses: [
        AgentTransportAttempt(
          data: toolCallResponse(
            name: "updateMetadata",
            arguments: [
              "draftID": "placeholder",
              "metadataField": "summary",
              "value": "不应应用的摘要",
            ]
          )
        ),
        AgentTransportAttempt(data: toolCallResponse(name: "showInspector", arguments: [:])),
        AgentTransportAttempt(data: textResponse("完成但无法安全落盘。")),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    fixture.store.setInspectorPresented(false)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage("把摘要改掉。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    await fixture.transport.setBeforeAttempt(attemptIndex: 2) { @MainActor in
      fixture.store.persistenceStore.protectWritesForUnrecoverableSnapshot(
        message: "forced continuation persistence failure"
      )
    }

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )
    XCTAssertTrue(rejected)
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 3)
    XCTAssertTrue(fixture.store.isInspectorPresented)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let originMessage = try XCTUnwrap(origin.messages.first(where: { $0.id == review.id }))
    XCTAssertEqual(originMessage.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertTrue(originMessage.toolRuns.contains { $0.status == .rejected })
    XCTAssertEqual(originMessage.reviewDecisions.map(\.choice), [.rejected])
    XCTAssertTrue(
      originMessage.toolRuns.contains {
        $0.command == .showInspector && $0.status == .succeeded
      }
    )
    XCTAssertEqual(
      originMessage.agentContinuation?.checkpoint.toolRuns.map(\.command),
      [.updateMetadata]
    )
    XCTAssertFalse(
      origin.messages.contains {
        $0.id != review.id && $0.role == .assistant
      }
    )
    XCTAssertTrue(fixture.store.automationRunRecords.isEmpty)

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fixture.persistenceURL),
      safeMode: true
    )
    let persisted = try XCTUnwrap(
      reloaded.aiConversations.first(where: { $0.id == conversationID })?
        .messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(persisted.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertNil(persisted.agentContinuation?.activeStepID)
    XCTAssertEqual(
      persisted.agentContinuation?.checkpoint.toolRuns.map(\.command),
      [.updateMetadata]
    )
  }

  func testProtectedContinuationWritesRollbackApplyingDecisionAndFailClosedResolution()
    async throws
  {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        )
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage("更新摘要。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    let baseline = try XCTUnwrap(
      fixture.store.automationDraftPreview(
        conversationID: conversationID,
        messageID: review.id,
        stepID: step.id
      )?.originalDraft.repositoryContentFingerprint
    )

    fixture.store.persistenceStore.protectWritesForUnrecoverableSnapshot(
      message: "forced continuation write protection"
    )
    let accepted = await fixture.store.acceptAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: baseline
    )
    XCTAssertNil(accepted)
    XCTAssertEqual(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })?
        .messages.first(where: { $0.id == review.id })?.agentContinuation?.phase,
      .awaitingReview
    )

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id,
      previewBaselineFingerprint: baseline
    )
    XCTAssertTrue(rejected)
    let originMessage = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })?
        .messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(originMessage.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertEqual(originMessage.agentContinuation?.resolutions.count, 1)
    XCTAssertEqual(originMessage.toolRuns.first?.status, .rejected)
    XCTAssertEqual(originMessage.reviewDecisions.map(\.choice), [.rejected])
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testRevokedKnowledgePermissionBlocksPendingAutomaticCallBeforeExecution() async throws {
    let fixture = makeStore(
      responses: [
        toolCallsResponse([
          (
            name: "updateMetadata",
            arguments: [
              "draftID": "placeholder",
              "metadataField": "summary",
              "value": "不应应用的摘要",
            ]
          ),
          (name: "knowledgeSearch", arguments: ["query": "private notes"]),
        ]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage("更新摘要并查资料。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let automaticStep = try XCTUnwrap(
      review.automationPlan?.steps.first(where: { $0.command == .knowledgeSearch })
    )
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    let manualAutomaticResult = await fixture.store.executeAutomationPlan(
      conversationID: conversationID,
      messageID: review.id,
      onlyStepID: automaticStep.id
    )
    XCTAssertNil(manualAutomaticResult)
    XCTAssertTrue(fixture.store.automationRunRecords.isEmpty)
    fixture.store.setAIChatKnowledgePolicy(.off)

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )

    XCTAssertTrue(rejected)
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let reviewedMessage = try XCTUnwrap(
      origin.messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(reviewedMessage.agentContinuation?.phase, .cancelled)
    XCTAssertFalse(
      reviewedMessage.toolRuns.contains {
        $0.command == .knowledgeSearch && $0.status == .succeeded
      }
    )
    XCTAssertTrue(fixture.store.automationRunRecords.isEmpty)
  }

  func testAutomaticRunBeforeNextReviewRemainsVisibleOnNewReviewMessage() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        ),
        toolCallResponse(name: "showInspector", arguments: [:]),
        toolCallResponse(
          name: "replaceBody",
          arguments: ["draftID": "placeholder", "content": "下一轮待审正文"]
        ),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    fixture.store.setInspectorPresented(false)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )
    await fixture.transport.replaceToolArgument(
      inAttemptAt: 2,
      key: "draftID",
      value: draft.id.uuidString
    )

    let generatedReview = await fixture.store.sendAIChatMessage("先改摘要，再继续检查。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let firstStep = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: firstStep.id
    )
    XCTAssertTrue(rejected)
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 3)
    XCTAssertTrue(fixture.store.isInspectorPresented)

    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let nextReview = try XCTUnwrap(origin.messages.last)
    XCTAssertNotEqual(nextReview.id, review.id)
    XCTAssertEqual(nextReview.automationPlan?.steps.first?.command, .replaceBody)
    XCTAssertNotNil(nextReview.agentContinuation)
    XCTAssertEqual(nextReview.toolRuns.map(\.command), [.showInspector, .replaceBody])
    XCTAssertEqual(nextReview.toolRuns.map(\.status), [.succeeded, .awaitingConfirmation])
  }

  func testPermissionRevocationDuringResumeTransportPreventsReturnedAutomaticTool() async throws {
    let fixture = makeStore(
      responses: [
        AgentTransportAttempt(
          data: toolCallResponse(
            name: "updateMetadata",
            arguments: [
              "draftID": "placeholder",
              "metadataField": "summary",
              "value": "不应应用的摘要",
            ]
          )
        ),
        AgentTransportAttempt(
          data: toolCallResponse(
            name: "knowledgeSearch",
            arguments: ["query": "private notes"]
          ),
          delayNanoseconds: 150_000_000
        ),
        AgentTransportAttempt(data: textResponse("不应发送。")),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )
    let generatedReview = await fixture.store.sendAIChatMessage("更新摘要后查资料。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )

    let rejectionTask = Task { @MainActor in
      await fixture.store.rejectAutomationStep(
        conversationID: conversationID,
        messageID: review.id,
        stepID: step.id
      )
    }
    for _ in 0..<500 {
      if await fixture.transport.capturedRequestCount() == 2 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    let inFlightRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(inFlightRequestCount, 2)
    fixture.store.setAIChatKnowledgePolicy(.off)
    let rejected = await rejectionTask.value
    XCTAssertTrue(rejected)

    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let reviewedMessage = try XCTUnwrap(
      origin.messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(reviewedMessage.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertFalse(
      reviewedMessage.toolRuns.contains {
        $0.command == .knowledgeSearch && $0.status == .succeeded
      }
    )
    XCTAssertTrue(fixture.store.automationRunRecords.isEmpty)
  }

  func testDraftEditBeforeRejectCancelsStaleContinuationWithoutAnotherRequest() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        ),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )
    let generatedReview = await fixture.store.sendAIChatMessage("更新摘要。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    var editedDraft = draft
    editedDraft.bodyMarkdown += "\n用户在审阅期间新增的内容"
    editedDraft.updatedAt = draft.updatedAt.addingTimeInterval(1)
    fixture.store.updateDraft(editedDraft)

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )

    XCTAssertTrue(rejected)
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      editedDraft.bodyMarkdown
    )
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    let reviewedMessage = try XCTUnwrap(
      origin.messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(reviewedMessage.agentContinuation?.phase, .cancelled)
    XCTAssertEqual(reviewedMessage.reviewDecisions.map(\.choice), [.rejected])
  }

  func testKnowledgePolicyChangeBeforeRejectCancelsFrozenPromptWithoutAnotherRequest() async throws
  {
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        ),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    enableContentTools(in: fixture.store, config: fixture.config)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )
    let generatedReview = await fixture.store.sendAIChatMessage("更新摘要。", draft: draft)
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    fixture.store.setAIChatKnowledgePolicy(.off)

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )

    XCTAssertTrue(rejected)
    let requestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    let origin = try XCTUnwrap(
      fixture.store.aiConversations.first(where: { $0.id == conversationID })
    )
    XCTAssertEqual(
      origin.messages.first(where: { $0.id == review.id })?.agentContinuation?.phase,
      .cancelled
    )
  }

  func testSecondAgentRoundCancellationDoesNotReuseFirstInjectedDecisionOrSendAgain() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      return decisionCount == 1 ? .confirm : .cancel
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testSecondAgentRoundExpiredAuthorizationPerformsNoAdditionalTransport() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      return .confirm
    }
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = { preview in
      decisionCount == 2 ? preview.expiresAt.addingTimeInterval(1) : Date()
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testSecondAgentRoundDraftDriftPerformsNoAdditionalTransport() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      if decisionCount == 2, var changedDraft = fixture.store.selectedDraft {
        changedDraft.bodyMarkdown += "\n确认期间发生变化"
        fixture.store.updateDraft(changedDraft)
      }
      return .confirm
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testCancellingOperationWhileSecondAgentTransportIsInFlightDoesNotWriteLateReply()
    async throws
  {
    let fixture = makeStore(
      responses: [
        AgentTransportAttempt(data: toolCallResponse(name: "showInspector", arguments: [:])),
        AgentTransportAttempt(data: textResponse("迟到回答。"), delayNanoseconds: 120_000_000),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let task = Task {
      await fixture.store.sendAIChatMessage("运行后取消。", draft: draft)
    }
    for _ in 0..<500 {
      if await fixture.transport.capturedRequestCount() == 2 { break }
      try await Task.sleep(for: .milliseconds(2))
    }

    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 2)
    fixture.store.cancelAIChatReply()
    let reply = await task.value

    XCTAssertNil(reply)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
    XCTAssertFalse(fixture.store.isAIChatRunning)
  }

  func testKnowledgeRevokedDuringFirstAgentApprovalSendsZeroRequestsAndKeepsUserMessage()
    async throws
  {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "agent-knowledge-approval"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commitKnowledgeDocument(
      title: "首轮绑定资料",
      text: "首轮绑定资料：蓝鲸航线的授权上下文。",
      library: library
    )
    let fixture = makeStore(
      responses: [textResponse("不应请求到模型。")],
      toolCallingSupported: true,
      knowledgeLibraryService: library
    )
    defer { fixture.cleanup() }
    await fixture.store.knowledge.reload()
    let document = try XCTUnwrap(
      fixture.store.knowledge.documents.first(where: { $0.id == documentID })
    )
    let context = try XCTUnwrap(try library.context(query: "蓝鲸航线"))
    XCTAssertFalse(context.authorizationBindings.isEmpty)
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      try! library.setAllowsRemoteAIUse(false, documentID: documentID)
      return .confirm
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let reply = await fixture.store.sendAIChatMessage(
      "请参考蓝鲸航线。",
      draft: draft,
      contextReferences: [
        .knowledgeEntry(
          documentID: document.id,
          title: document.title,
          characterCount: 40
        )
      ]
    )

    XCTAssertNil(reply)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertEqual(
      fixture.store.aiChatMessage,
      "资料权限或版本已变化，本次未发送，请重新生成。"
    )
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testKnowledgeRevokedAfterFirstAgentResponseStopsAutomaticToolBeforeSecondRequest()
    async throws
  {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "agent-knowledge-automatic"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commitKnowledgeDocument(
      title: "自动工具资料",
      text: "自动工具资料：琥珀轨道的授权上下文。",
      library: library
    )
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发起第二请求。"),
      ],
      toolCallingSupported: true,
      knowledgeLibraryService: library
    )
    defer { fixture.cleanup() }
    await fixture.store.knowledge.reload()
    let document = try XCTUnwrap(
      fixture.store.knowledge.documents.first(where: { $0.id == documentID })
    )
    let context = try XCTUnwrap(try library.context(query: "琥珀轨道"))
    XCTAssertFalse(context.authorizationBindings.isEmpty)
    await fixture.transport.setBeforeAttempt(attemptIndex: 0) {
      try! library.setAllowsRemoteAIUse(false, documentID: documentID)
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    fixture.store.setInspectorPresented(false)
    let reply = await fixture.store.sendAIChatMessage(
      "请检查琥珀轨道并继续回答。",
      draft: draft,
      contextReferences: [
        .knowledgeEntry(
          documentID: document.id,
          title: document.title,
          characterCount: 40
        )
      ]
    )

    XCTAssertNil(reply)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertFalse(fixture.store.isInspectorPresented)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
    XCTAssertEqual(
      fixture.store.aiChatMessage,
      "资料权限或版本已变化，本次未发送，请重新生成。"
    )
  }

  func testKnowledgeRevokedBeforeFinalReviewCancelsContinuationAndPreservesAudit()
    async throws
  {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "agent-knowledge-review"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commitKnowledgeDocument(
      title: "审阅资料",
      text: "审阅资料：赤狐航线的授权上下文。",
      library: library
    )
    let fixture = makeStore(
      responses: [
        toolCallResponse(
          name: "updateMetadata",
          arguments: [
            "draftID": "placeholder",
            "metadataField": "summary",
            "value": "不应应用的摘要",
          ]
        ),
        textResponse("不应请求到第二轮。"),
      ],
      toolCallingSupported: true,
      knowledgeLibraryService: library
    )
    defer { fixture.cleanup() }
    await fixture.store.knowledge.reload()
    let document = try XCTUnwrap(
      fixture.store.knowledge.documents.first(where: { $0.id == documentID })
    )
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    enableContentTools(in: fixture.store, config: fixture.config)
    await fixture.transport.replaceFirstToolArgument(
      key: "draftID",
      value: draft.id.uuidString
    )
    let generatedReview = await fixture.store.sendAIChatMessage(
      "更新摘要，但先等待我审阅。",
      draft: draft,
      contextReferences: [
        .knowledgeEntry(
          documentID: document.id,
          title: document.title,
          characterCount: 40
        )
      ]
    )
    let review = try XCTUnwrap(generatedReview)
    let step = try XCTUnwrap(review.automationPlan?.steps.first)
    let conversationID = try XCTUnwrap(
      fixture.store.aiStore.activeAIChatConversationID(for: draft.id)
    )
    try library.setAllowsRemoteAIUse(false, documentID: documentID)

    let rejected = await fixture.store.rejectAutomationStep(
      conversationID: conversationID,
      messageID: review.id,
      stepID: step.id
    )

    XCTAssertTrue(rejected)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    let reviewedMessage = try XCTUnwrap(
      fixture.store.aiConversations
        .first(where: { $0.id == conversationID })?
        .messages.first(where: { $0.id == review.id })
    )
    XCTAssertEqual(reviewedMessage.agentContinuation?.phase, .cancelled)
    XCTAssertNotEqual(reviewedMessage.agentContinuation?.phase, .deliveryUncertain)
    XCTAssertEqual(reviewedMessage.reviewDecisions.map(\.choice), [.rejected])
    XCTAssertEqual(reviewedMessage.toolRuns.map(\.status), [.rejected])
  }

  private func makeStore(
    responses: [Data],
    toolCallingSupported: Bool,
    knowledgeLibraryService: KnowledgeLibraryService? = nil
  ) -> AgentStoreFixture {
    makeStore(
      responses: responses.map { AgentTransportAttempt(data: $0) },
      toolCallingSupported: toolCallingSupported,
      knowledgeLibraryService: knowledgeLibraryService
    )
  }

  private func makeStore(
    responses: [AgentTransportAttempt],
    toolCallingSupported: Bool,
    knowledgeLibraryService: KnowledgeLibraryService? = nil
  ) -> AgentStoreFixture {
    let transport = SequencedAgentAIChatTransport(attempts: responses)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchAgentRuntime-\(UUID().uuidString).json")
    let consentStore = AIDataSharingConsentStore(
      storageKey: "WorkbenchAgentRuntimeConsent.\(UUID().uuidString)"
    )
    var config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://agent.example/v1",
      model: "agent-test-model",
      requiresAPIKey: false
    )
    if toolCallingSupported {
      let now = Date()
      let key = AIProviderCapabilityCacheKey(config: config)
      config.capabilityProbeEvidence = [
        .toolCalling: AIProviderCapabilityProbeEvidence(
          key: key,
          capability: .toolCalling,
          outcome: .supported,
          observedAt: now,
          expiresAt: now.addingTimeInterval(60)
        )
      ]
    }
    XCTAssertTrue(consentStore.grant(for: config))
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      knowledgeLibraryService: knowledgeLibraryService ?? KnowledgeLibraryService(),
      keychainTokenStore: KeychainTokenStore(
        service: "WorkbenchAgentRuntime.\(UUID().uuidString.prefix(8))",
        accountPrefix: "agent-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    return AgentStoreFixture(
      store: store,
      transport: transport,
      config: config,
      consentStore: consentStore,
      persistenceURL: persistenceURL
    )
  }

  private func commitKnowledgeDocument(
    title: String,
    text: String,
    library: KnowledgeLibraryService
  ) async throws -> UUID {
    let hash = KnowledgeChunkingService.contentHash(for: text)
    let candidate = KnowledgeImportCandidate(
      kind: .markdown,
      title: title,
      sourceURL: nil,
      sourceName: "(title).md",
      allowsRemoteAIUse: true,
      originalContentHash: hash,
      normalizedText: text,
      normalizedContentHash: hash,
      sections: [KnowledgeExtractedSection(headingPath: title, text: text)]
    )
    let preview = KnowledgeImportPreview(
      sourceName: "agent-fixture",
      candidates: [candidate]
    )
    let result = try await library.commit(preview)
    return try XCTUnwrap(result.documentIDs.first)
  }

  private func configureActiveAIConnection(
    in store: WorkbenchStore,
    config: AIProviderConfig
  ) {
    var identityConfig = config
    identityConfig.capabilityProbeEvidence = nil
    var connection = store.activeAIConnectionProfile
    connection.config = identityConfig
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    connection = store.activeAIConnectionProfile
    connection.config = config
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
  }

  private func enableContentTools(
    in store: WorkbenchStore,
    config: AIProviderConfig
  ) {
    var enabled = config
    enabled.advancedSettings = AIProviderAdvancedSettings(
      allowsApplicationTools: true,
      agentPermissionPolicy: .all
    )
    configureActiveAIConnection(in: store, config: enabled)
  }

  private func toolCallResponse(
    name: String,
    arguments: [String: Any]
  ) -> Data {
    toolCallsResponse([(name: name, arguments: arguments)])
  }

  private func toolCallsResponse(
    _ calls: [(name: String, arguments: [String: Any])]
  ) -> Data {
    let toolCalls: [[String: Any]] = calls.enumerated().map { index, call in
      let argumentsData = try! JSONSerialization.data(
        withJSONObject: call.arguments,
        options: [.sortedKeys]
      )
      return [
        "id": "call-\(index)-\(call.name)",
        "type": "function",
        "function": [
          "name": call.name,
          "arguments": String(decoding: argumentsData, as: UTF8.self),
        ],
      ]
    }
    return try! JSONSerialization.data(withJSONObject: [
      "model": "agent-test-model",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": "",
            "tool_calls": toolCalls,
          ],
          "finish_reason": "tool_calls",
        ]
      ],
    ])
  }

  private func textResponse(_ content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "model": "agent-test-model",
      "choices": [
        [
          "message": ["role": "assistant", "content": content],
          "finish_reason": "stop",
        ]
      ],
    ])
  }

  private func jsonBody(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private struct AgentStoreFixture {
  let store: WorkbenchStore
  let transport: SequencedAgentAIChatTransport
  let config: AIProviderConfig
  let consentStore: AIDataSharingConsentStore
  let persistenceURL: URL

  @MainActor
  func cleanup() {
    consentStore.revoke(for: config)
    try? FileManager.default.removeItem(at: persistenceURL)
  }
}

private struct AgentTransportAttempt: Sendable {
  let data: Data
  let statusCode: Int
  let delayNanoseconds: UInt64

  init(data: Data, statusCode: Int = 200, delayNanoseconds: UInt64 = 0) {
    self.data = data
    self.statusCode = statusCode
    self.delayNanoseconds = delayNanoseconds
  }
}

private actor SequencedAgentAIChatTransport: AIChatTransport {
  private var attempts: [AgentTransportAttempt]
  private var requests: [URLRequest] = []
  private var beforeAttemptCallbacks: [Int: @MainActor () async -> Void] = [:]

  init(attempts: [AgentTransportAttempt]) {
    self.attempts = attempts
  }

  func setBeforeAttempt(
    attemptIndex: Int,
    callback: @escaping @MainActor () async -> Void
  ) {
    beforeAttemptCallbacks[attemptIndex] = callback
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let index = requests.count
    requests.append(request)
    if let callback = beforeAttemptCallbacks.removeValue(forKey: index) {
      await callback()
    }
    let attempt = attempts[min(index, max(0, attempts.count - 1))]
    if attempt.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: attempt.delayNanoseconds)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: attempt.statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (attempt.data, response)
  }

  func capturedRequestCount() -> Int {
    requests.count
  }

  func capturedBodies() -> [Data] {
    requests.compactMap(\.httpBody)
  }

  func replaceFirstToolArgument(key: String, value: String) {
    replaceToolArgument(inAttemptAt: 0, key: key, value: value)
  }

  func replaceToolArgument(
    inAttemptAt attemptIndex: Int,
    key: String,
    value: String
  ) {
    guard attempts.indices.contains(attemptIndex),
      var object = (try? JSONSerialization.jsonObject(with: attempts[attemptIndex].data))
        as? [String: Any],
      var choices = object["choices"] as? [[String: Any]],
      !choices.isEmpty,
      var message = choices[0]["message"] as? [String: Any],
      var calls = message["tool_calls"] as? [[String: Any]],
      !calls.isEmpty,
      var function = calls[0]["function"] as? [String: Any],
      let argumentsText = function["arguments"] as? String,
      var arguments =
        (try? JSONSerialization.jsonObject(
          with: Data(argumentsText.utf8)
        )) as? [String: Any]
    else { return }
    arguments[key] = value
    guard
      let argumentsData = try? JSONSerialization.data(
        withJSONObject: arguments,
        options: [.sortedKeys]
      )
    else { return }
    function["arguments"] = String(decoding: argumentsData, as: UTF8.self)
    calls[0]["function"] = function
    message["tool_calls"] = calls
    choices[0]["message"] = message
    object["choices"] = choices
    guard let responseData = try? JSONSerialization.data(withJSONObject: object) else {
      return
    }
    attempts[attemptIndex] = AgentTransportAttempt(
      data: responseData,
      statusCode: attempts[attemptIndex].statusCode,
      delayNanoseconds: attempts[attemptIndex].delayNanoseconds
    )
  }
}
