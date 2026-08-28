import Foundation

/// The agent loop converts a model-transport error into a result termination.
/// This side channel preserves the dedicated cancellation semantics when a
/// frozen knowledge binding is revoked while a continuation is resuming.
private final class AgentContinuationKnowledgeAuthorizationState: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  func markChanged() {
    lock.lock()
    changed = true
    lock.unlock()
  }

  var didChange: Bool {
    lock.lock()
    defer { lock.unlock() }
    return changed
  }
}

private struct AgentContinuationBinding {
  var conversation: AIConversation
  var identity: AIChatConversationIdentity
  var message: AIPublishingChatMessage
  var plan: WorkbenchAutomationPlan
  var continuation: AIPublishingChatAgentContinuation
}

private struct AgentContinuationRuntimeContext {
  var draft: ArticleDraft
  var profile: SiteProfile
  var taskConfig: AIProviderConfig
  var allowedCommands: Set<WorkbenchAutomationCommandID>
  var loopContext: WorkbenchAIAgentContext
  var conversationRevision: AgentContinuationConversationRevision
  var draftFingerprint: String
  var draftUpdatedAt: Date
}

/// In-memory transaction image for continuation writes. A continuation result
/// is first assembled in the active session, then synchronously persisted. If
/// that persistence boundary fails, restoring this image lets the caller keep
/// the original continuation and mark it uncertain instead of leaving an
/// apparently completed, non-replayable message behind.
private struct AgentContinuationStoreSnapshot {
  var conversations: [AIConversation]
  var activeDraftConversationIDs: [UUID: UUID]
  var activeScopeConversationIDs: [String: UUID]
  var chatDraftID: UUID?
  var chatTitle: String?
  var chatMessages: [AIPublishingChatMessage]
  var chatContextMode: AIPublishingChatContextMode
  var chatKnowledgePolicy: KnowledgeRetrievalPolicy
  var chatModelGrade: AIChatModelGrade
  var chatReasoningLevel: AIChatReasoningLevel
  var chatSelectedModel: String
  var chatFocusedParagraphID: String?
}

private struct AgentContinuationConversationRevision: Equatable {
  var connectionProfileID: UUID?
  var agentMode: AIConversationAgentMode
  var contextMode: AIPublishingChatContextMode
  var knowledgePolicy: KnowledgeRetrievalPolicy
  var modelGrade: AIChatModelGrade
  var reasoningLevel: AIChatReasoningLevel
  var selectedModel: String
  var focusedParagraphID: String?
  var messages: [AIPublishingChatMessage]

  init(_ conversation: AIConversation) {
    connectionProfileID = conversation.connectionProfileID
    agentMode = conversation.agentMode
    contextMode = conversation.contextMode
    knowledgePolicy = conversation.knowledgePolicy
    modelGrade = conversation.modelGrade
    reasoningLevel = conversation.reasoningLevel
    selectedModel = conversation.selectedModel
    focusedParagraphID = conversation.focusedParagraphID
    messages = conversation.messages.map { message in
      var promptMessage = message
      // Continuation phase/revision changes are local crash-safety state and
      // are intentionally not part of the model-visible conversation.
      promptMessage.agentContinuation = nil
      return promptMessage
    }
  }
}

extension WorkbenchAIStore {
  /// Persists the intent to execute a reviewed mutation before the executor is
  /// entered. A crash after this point is deliberately not replayable.
  @discardableResult
  func markAgentContinuationApplyingDecision(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    stepID: UUID
  ) -> Bool {
    guard !isAIChatRunning,
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ),
      binding.continuation.phase == .awaitingReview,
      binding.continuation.activeStepID == nil,
      let pending = binding.continuation.checkpoint.pendingCalls.first(where: {
        $0.automationStepID == stepID
      }),
      !binding.continuation.resolutions.contains(where: {
        $0.toolCallID == pending.toolCallID
      })
    else {
      return false
    }

    let transactionSnapshot = captureAgentContinuationStoreSnapshot()
    let didUpdate = updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: binding.continuation.id
    ) { _, continuation in
      guard continuation.phase == .awaitingReview,
        continuation.activeStepID == nil
      else { return false }
      continuation.phase = .applyingDecision
      continuation.activeStepID = stepID
      continuation.revision += 1
      continuation.updatedAt = Date()
      return true
    }
    guard didUpdate else {
      store.setAIChatMessage(
        CoreL10n.text("无法安全保存 AI 审阅状态，未执行修改。")
      )
      return false
    }
    let didFlush = store.flushPendingChanges()
    guard didFlush, !store.persistenceStore.isRecoveryWriteProtected else {
      restoreAgentContinuationStoreSnapshot(transactionSnapshot)
      store.setAIChatMessage(
        CoreL10n.text("无法安全保存 AI 审阅状态，未执行修改。")
      )
      return false
    }
    return true
  }

  /// Permanently closes a continuation whose delivery outcome could not be
  /// confirmed. This is a compare-and-swap operation: only the exact persisted
  /// revision observed by the caller may transition, and the complete
  /// checkpoint/plan/tool-run/review audit remains untouched.
  @discardableResult
  public func abandonAgentContinuation(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    expectedRevision: Int
  ) -> Bool {
    guard !isAIChatRunning else {
      store.setAIChatMessage(CoreL10n.text("请先停止当前 AI 回复，再结束结果不确定的续跑。"))
      return false
    }
    guard
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        includingArchived: true
      ),
      binding.continuation.phase == .deliveryUncertain,
      binding.continuation.revision == expectedRevision
    else {
      return false
    }

    // updateAgentContinuation updates both the persisted conversation and the
    // active in-memory projection. Keep an exact rollback image in case the
    // synchronous flush fails; a failed CAS must never be reported as closed.
    let originalSnapshot = captureAgentContinuationStoreSnapshot()

    let didUpdate = updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID,
      allowArchived: true
    ) { _, continuation in
      guard continuation.phase == .deliveryUncertain,
        continuation.revision == expectedRevision
      else { return false }
      continuation.phase = .abandonedAfterDeliveryUncertain
      continuation.revision += 1
      continuation.updatedAt = Date()
      return true
    }
    guard didUpdate else { return false }

    let didFlush = store.flushPendingChanges()
    guard didFlush, !store.persistenceStore.isRecoveryWriteProtected else {
      restoreAgentContinuationStoreSnapshot(originalSnapshot)
      store.setAIChatMessage(
        CoreL10n.text("无法安全保存处置状态，结果不确定的 AI 续跑仍待处理。")
      )
      return false
    }
    store.setAIChatMessage(CoreL10n.text("已结束结果不确定的 AI 续跑，完整审计记录已保留。"))
    return true
  }

  /// Records the complete model-facing result for one reviewed call. The
  /// result is synchronously persisted before a continuation can contact the
  /// model, and duplicate decisions never create another request.
  @discardableResult
  func recordAgentContinuationResolution(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    resolution: WorkbenchAIAgentToolResolution
  ) async -> Bool {
    guard
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ),
      let pending = binding.continuation.checkpoint.pendingCalls.first(where: {
        $0.toolCallID == resolution.toolCallID
      }),
      pending.correlationID == resolution.correlationID,
      pending.toolID == resolution.toolID,
      pending.modelToolName == resolution.modelToolName,
      pending.catalogRevision == resolution.catalogRevision,
      pending.automationStepID == resolution.automationStepID,
      !binding.continuation.resolutions.contains(where: {
        $0.toolCallID == resolution.toolCallID
      }),
      resolution.content.utf8.count
        <= WorkbenchAIAgentToolResolution.maximumContentByteCount
    else {
      return false
    }

    let phaseAllowsResolution =
      (binding.continuation.phase == .applyingDecision
        && binding.continuation.activeStepID == resolution.automationStepID)
      || (binding.continuation.phase == .awaitingReview
        && binding.continuation.activeStepID == nil)
    guard phaseAllowsResolution else { return false }

    let updatesReviewDraftBaseline =
      resolution.status == .succeeded
      && resolution.targetDraftID == binding.identity.draftID
    let resolvedReviewDraft =
      updatesReviewDraftBaseline
      ? store.drafts.first(where: { $0.id == binding.identity.draftID })
      : nil
    guard !updatesReviewDraftBaseline || resolvedReviewDraft != nil else {
      return false
    }

    let didUpdate = updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: binding.continuation.id
    ) { _, continuation in
      guard
        !continuation.resolutions.contains(where: {
          $0.toolCallID == resolution.toolCallID
        })
      else { return false }
      continuation.resolutions.append(resolution)
      continuation.phase = .awaitingReview
      continuation.activeStepID = nil
      if let resolvedReviewDraft {
        continuation.reviewDraftFingerprint =
          resolvedReviewDraft.repositoryContentFingerprint
        continuation.reviewDraftUpdatedAt = resolvedReviewDraft.updatedAt
      }
      continuation.revision += 1
      continuation.updatedAt = Date()
      return true
    }
    guard didUpdate else {
      store.setAIChatMessage(
        CoreL10n.text("AI 审阅结果保存失败，未继续请求模型。")
      )
      return false
    }
    let didFlush = store.flushPendingChanges()
    guard didFlush, !store.persistenceStore.isRecoveryWriteProtected else {
      // The reviewed operation may already have changed the draft. Keep the
      // resolution, plan, and tool-run audit in memory and fail closed until
      // the user explicitly disposes the uncertain delivery.
      markAgentContinuationDeliveryUncertain(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: binding.continuation.id
      )
      store.setAIChatMessage(
        CoreL10n.text("AI 审阅结果保存失败，结果不确定的续跑仍待处理。")
      )
      return false
    }

    await resumeAgentContinuationIfReady(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID
    )
    return true
  }

  private func resumeAgentContinuationIfReady(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID
  ) async {
    guard
      let initialBinding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ),
      initialBinding.continuation.phase == .awaitingReview,
      initialBinding.message.id == initialBinding.conversation.messages.last?.id
    else {
      return
    }

    let resolvedIDs = Set(initialBinding.continuation.resolutions.map(\.toolCallID))
    let unresolvedHumanCalls = initialBinding.continuation.checkpoint.pendingCalls.filter {
      pending in
      !resolvedIDs.contains(pending.toolCallID)
        && (pending.automationStep?.status == .awaitingConfirmation
          || pending.executionPolicy != .automatic)
    }
    guard unresolvedHumanCalls.isEmpty else { return }

    guard
      let operationID = beginAIChatOperation(
        statusMessage: CoreL10n.text("正在继续已审阅的 AI 操作…"),
        clearsManualRetryState: false
      )
    else {
      return
    }
    defer { finishAIChatOperation(operationID) }

    var enteredSending = false
    let continuationID = initialBinding.continuation.id
    let attemptID = UUID()
    let knowledgeAuthorizationState =
      AgentContinuationKnowledgeAuthorizationState()
    do {
      try checkAIChatOperation(operationID)
      let initialRuntime = try await validatedAgentContinuationRuntimeContext(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID
      )
      guard
        let validatedBinding = agentContinuationBinding(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID
        ),
        validatedBinding.continuation.id == continuationID,
        validatedBinding.plan.steps.count
          == validatedBinding.continuation.checkpoint.pendingCalls.count,
        validatedBinding.plan.steps.indices.allSatisfy({ index in
          let step = validatedBinding.plan.steps[index]
          let pending = validatedBinding.continuation.checkpoint.pendingCalls[index]
          guard let pendingStep = pending.automationStep else { return false }
          return step.id == pending.automationStepID
            && step.command == pendingStep.command
            && step.arguments == pendingStep.arguments
            && pending.toolID
              == WorkbenchAutomationAgentToolRegistry.toolID(for: step.command)
        })
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }
      let checkpointValidator = WorkbenchAIAgentLoopService(
        modelTransport: { _ in throw CancellationError() },
        toolRegistry: WorkbenchAutomationAgentToolRegistry(
          allowedToolIDs: Set(
            initialRuntime.allowedCommands.map(
              WorkbenchAutomationAgentToolRegistry.toolID(for:)
            )
          )
        ),
        grantedScopes: Set(
          initialRuntime.allowedCommands.map(WorkbenchAutomationRegistry.requiredPermission(for:))
        ),
        automaticExecutor: { _ in throw CancellationError() }
      )
      guard
        checkpointValidator.isValidResumeCheckpoint(
          context: initialRuntime.loopContext,
          toolCallingSupport: initialRuntime.taskConfig.capabilitySupport(for: .toolCalling),
          checkpoint: validatedBinding.continuation.checkpoint
        )
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }

      let resumeTransitionSnapshot = captureAgentContinuationStoreSnapshot()
      guard
        updateAgentContinuation(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          update: { _, continuation in
            guard continuation.phase == .awaitingReview,
              continuation.activeStepID == nil
            else { return false }
            continuation.phase = .resuming
            continuation.resumeAttemptID = attemptID
            continuation.revision += 1
            continuation.updatedAt = Date()
            return true
          }
        )
      else {
        store.setAIChatMessage(
          CoreL10n.text("无法安全保存 AI 续跑状态，未请求模型。")
        )
        return
      }

      let didPersistResumeTransition = store.flushPendingChanges()
      guard didPersistResumeTransition,
        !store.persistenceStore.isRecoveryWriteProtected
      else {
        restoreAgentContinuationStoreSnapshot(resumeTransitionSnapshot)
        store.setAIChatMessage(
          CoreL10n.text("无法安全保存 AI 续跑状态，未请求模型。")
        )
        return
      }

      guard
        try await resolvePendingAutomaticCalls(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID,
          operationID: operationID,
          preResumeSnapshot: resumeTransitionSnapshot,
          knowledgeAuthorizationState: knowledgeAuthorizationState
        )
      else {
        store.setAIChatMessage(
          CoreL10n.text("无法安全保存 AI 续跑状态，未请求模型。")
        )
        return
      }
      try checkAIChatOperation(operationID)

      let runtime = try await validatedAgentContinuationRuntimeContext(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID,
        expectedPhase: .resuming,
        expectedAttemptID: attemptID,
        knowledgeAuthorizationState: knowledgeAuthorizationState
      )
      guard
        let readyBinding = agentContinuationBinding(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID
        ),
        readyBinding.continuation.id == continuationID,
        readyBinding.continuation.resolutions.count
          == readyBinding.continuation.checkpoint.pendingCalls.count
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }

      let sendingTransitionSnapshot = captureAgentContinuationStoreSnapshot()
      guard
        updateAgentContinuation(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          update: { _, continuation in
            guard continuation.phase == .resuming,
              continuation.resumeAttemptID == attemptID,
              continuation.activeStepID == nil
            else { return false }
            continuation.phase = .sending
            continuation.revision += 1
            continuation.updatedAt = Date()
            return true
          }
        )
      else {
        store.setAIChatMessage(
          CoreL10n.text("无法安全保存 AI 发送状态，未请求模型。")
        )
        return
      }
      let didPersistSendingTransition = store.flushPendingChanges()
      guard didPersistSendingTransition,
        !store.persistenceStore.isRecoveryWriteProtected
      else {
        restoreAgentContinuationStoreSnapshot(sendingTransitionSnapshot)
        markAgentContinuationDeliveryUncertain(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
        store.setAIChatMessage(
          CoreL10n.text("无法安全保存 AI 发送状态，结果不确定的续跑仍待处理。")
        )
        return
      }
      enteredSending = true

      guard
        let sendingBinding = agentContinuationBinding(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID
        ),
        sendingBinding.continuation.id == continuationID,
        sendingBinding.continuation.phase == .sending,
        sendingBinding.continuation.resumeAttemptID == attemptID
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }

      let privacyService = AIOutboundPayloadPrivacyService()
      let toolRegistry = WorkbenchAutomationAgentToolRegistry(
        allowedToolIDs: Set(
          runtime.allowedCommands.map(WorkbenchAutomationAgentToolRegistry.toolID(for:))
        )
      )
      let loop = WorkbenchAIAgentLoopService(
        modelTransport: { [weak self] roundRequest in
          guard let self else { throw CancellationError() }
          return try await self.authorizedAgentContinuationModelCompletion(
            roundRequest,
            conversationID: conversationID,
            messageID: messageID,
            planID: planID,
            continuationID: continuationID,
            attemptID: attemptID,
            operationID: operationID,
            expectedDraftFingerprint: runtime.draftFingerprint,
            expectedDraftUpdatedAt: runtime.draftUpdatedAt,
            expectedConversationRevision: runtime.conversationRevision,
            expectedAllowedCommands: runtime.allowedCommands,
            privacyService: privacyService,
            knowledgeAuthorizationState: knowledgeAuthorizationState
          )
        },
        toolRegistry: toolRegistry,
        grantedScopes: Set(
          runtime.allowedCommands.map(WorkbenchAutomationRegistry.requiredPermission(for:))
        ),
        automaticExecutor: { [weak self] invocation in
          guard let self else { throw CancellationError() }
          let currentRuntime: AgentContinuationRuntimeContext
          do {
            currentRuntime = try await self.validatedAgentContinuationRuntimeContext(
              conversationID: conversationID,
              messageID: messageID,
              planID: planID,
              continuationID: continuationID,
              expectedPhase: .sending,
              expectedAttemptID: attemptID,
              knowledgeAuthorizationState: knowledgeAuthorizationState
            )
          } catch let error as AIOutboundPayloadConfirmationError
            where error == .knowledgeAuthorizationChanged
          {
            throw CancellationError()
          }
          guard
            let command = WorkbenchAutomationAgentToolRegistry.command(
              for: invocation.toolID
            ),
            currentRuntime.allowedCommands.contains(command),
            currentRuntime.conversationRevision == runtime.conversationRevision,
            currentRuntime.draftFingerprint == runtime.draftFingerprint,
            currentRuntime.draftUpdatedAt == runtime.draftUpdatedAt
          else {
            throw AIOutboundPayloadConfirmationError.drifted
          }
          return try await self.executeAgentAutomaticInvocation(
            invocation,
            operationID: operationID,
            conversationID: conversationID
          )
        }
      )
      let result = await loop.resume(
        request: sendingBinding.continuation.requestTemplate,
        context: runtime.loopContext,
        toolCallingSupport: runtime.taskConfig.capabilitySupport(for: .toolCalling),
        checkpoint: sendingBinding.continuation.checkpoint,
        resolutions: sendingBinding.continuation.resolutions
      )
      try checkAIChatOperation(operationID)
      if knowledgeAuthorizationState.didChange {
        throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
      }
      let finalRuntime = try await validatedAgentContinuationRuntimeContext(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID,
        expectedPhase: .sending,
        expectedAttemptID: attemptID
      )
      guard finalRuntime.draftFingerprint == runtime.draftFingerprint,
        finalRuntime.draftUpdatedAt == runtime.draftUpdatedAt,
        finalRuntime.allowedCommands == runtime.allowedCommands,
        finalRuntime.conversationRevision == runtime.conversationRevision
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }

      switch result.termination {
      case .completed:
        try persistCompletedAgentContinuation(
          result,
          binding: sendingBinding,
          attemptID: attemptID
        )
      case .awaitingReview:
        try persistNextAgentReview(
          result,
          binding: sendingBinding,
          attemptID: attemptID
        )
      case .cancelled, .capabilityUnavailable, .rejected, .limitReached,
        .modelTransportFailed:
        markAgentContinuationDeliveryUncertain(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
        store.setAIChatMessage(
          CoreL10n.text("AI 续跑未能确认完成；为避免重复计费，不会自动重试。")
        )
      }
    } catch let error as AIOutboundPayloadConfirmationError
      where error == .knowledgeAuthorizationChanged
    {
      // Knowledge revocation is a deterministic pre-next-action stop. Even
      // after the local phase was persisted as `.sending`, the continuation
      // can be cancelled safely because this error is raised before the next
      // transport/tool boundary or after a completed response. Keep all
      // resolutions and tool-run audit records; never classify it as uncertain.
      markAgentContinuationCancelled(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID,
        attemptID: attemptID
      )
      store.setAIChatMessage(error.localizedDescription)
    } catch is CancellationError {
      if enteredSending {
        markAgentContinuationDeliveryUncertain(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
      } else {
        markAgentContinuationCancelled(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
      }
      store.setAIChatMessage(CoreL10n.text("AI 续跑已停止。"))
    } catch {
      if enteredSending {
        markAgentContinuationDeliveryUncertain(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
        store.setAIChatMessage(
          CoreL10n.text("AI 续跑结果不确定；为避免重复计费，不会自动重试。")
        )
      } else {
        markAgentContinuationCancelled(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
        store.setAIChatMessage(CoreL10n.text("AI 续跑失败，未请求模型。"))
      }
    }
  }

  private func resolvePendingAutomaticCalls(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    attemptID: UUID,
    operationID: UUID,
    preResumeSnapshot: AgentContinuationStoreSnapshot,
    knowledgeAuthorizationState: AgentContinuationKnowledgeAuthorizationState? = nil
  ) async throws -> Bool {
    guard
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      )
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let resolvedIDs = Set(binding.continuation.resolutions.map(\.toolCallID))
    let pendingAutomaticCalls = binding.continuation.checkpoint.pendingCalls.filter {
      !resolvedIDs.contains($0.toolCallID)
        && $0.automationStep?.status == .proposed
        && $0.executionPolicy == .automatic
    }
    var didExecuteAutomaticTool = false

    for pending in pendingAutomaticCalls {
      try checkAIChatOperation(operationID)
      let runtime = try await validatedAgentContinuationRuntimeContext(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID,
        expectedPhase: .resuming,
        expectedAttemptID: attemptID
      )
      guard
        let currentBinding = agentContinuationBinding(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID
        ),
        currentBinding.continuation.id == continuationID,
        currentBinding.continuation.checkpoint.allowedToolIDs.contains(pending.toolID),
        let command = WorkbenchAutomationAgentToolRegistry.command(for: pending.toolID),
        runtime.allowedCommands.contains(command),
        pending.automationStep?.command == command
      else {
        throw AIOutboundPayloadConfirmationError.drifted
      }
      let activeStepSnapshot = captureAgentContinuationStoreSnapshot()
      guard
        updateAgentContinuation(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          update: { _, continuation in
            guard continuation.phase == .resuming,
              continuation.resumeAttemptID == attemptID,
              continuation.activeStepID == nil,
              !continuation.resolutions.contains(where: {
                $0.toolCallID == pending.toolCallID
              })
            else { return false }
            continuation.activeStepID = pending.automationStepID
            continuation.revision += 1
            continuation.updatedAt = Date()
            return true
          }
        )
      else {
        restoreAgentContinuationStoreSnapshot(activeStepSnapshot)
        if didExecuteAutomaticTool {
          markAgentContinuationDeliveryUncertain(
            conversationID: conversationID,
            messageID: messageID,
            planID: planID,
            continuationID: continuationID,
            attemptID: attemptID
          )
        } else {
          restoreAgentContinuationStoreSnapshot(preResumeSnapshot)
        }
        return false
      }
      let didPersistActiveStep = store.flushPendingChanges()
      guard didPersistActiveStep, !store.persistenceStore.isRecoveryWriteProtected else {
        restoreAgentContinuationStoreSnapshot(activeStepSnapshot)
        if didExecuteAutomaticTool {
          markAgentContinuationDeliveryUncertain(
            conversationID: conversationID,
            messageID: messageID,
            planID: planID,
            continuationID: continuationID,
            attemptID: attemptID
          )
        } else {
          restoreAgentContinuationStoreSnapshot(preResumeSnapshot)
        }
        return false
      }

      let resolution: WorkbenchAIAgentToolResolution
      do {
        guard let knowledgePolicy = currentBinding.continuation.promptRevision?.knowledgePolicy
        else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        try await validateAgentContinuationKnowledgeAuthorization(
          continuation: currentBinding.continuation,
          policy: knowledgePolicy,
          failureState: knowledgeAuthorizationState
        )
        let result = try await executeAgentAutomaticInvocation(
          pending.invocation,
          operationID: operationID,
          conversationID: conversationID
        )
        resolution = WorkbenchAIAgentToolResolution(
          resolving: pending,
          status: result.isError ? .failed : .succeeded,
          content: String(
            result.content.prefix(
              WorkbenchAIAgentToolResolution.maximumContentByteCount
            )
          ),
          targetDraftID: result.targetDraftID ?? pending.targetDraftID
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        resolution = WorkbenchAIAgentToolResolution(
          resolving: pending,
          status: .failed,
          content: "The application tool failed.",
          targetDraftID: pending.targetDraftID
        )
      }
      didExecuteAutomaticTool = true

      let didPersistResolution = persistAutomaticAgentResolution(
        resolution,
        conversationID: conversationID,
        messageID: messageID,
        planID: planID,
        continuationID: continuationID,
        attemptID: attemptID
      )
      let didFlushResolution = didPersistResolution && store.flushPendingChanges()
      guard didPersistResolution,
        didFlushResolution,
        !store.persistenceStore.isRecoveryWriteProtected
      else {
        if !didPersistResolution {
          _ = updateAgentContinuation(
            conversationID: conversationID,
            messageID: messageID,
            planID: planID,
            continuationID: continuationID
          ) { message, continuation in
            guard continuation.phase == .resuming,
              continuation.resumeAttemptID == attemptID,
              continuation.activeStepID == pending.automationStepID
            else { return false }
            synchronizeAgentReviewMessage(&message, resolution: resolution)
            return true
          }
        }
        markAgentContinuationDeliveryUncertain(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          attemptID: attemptID
        )
        return false
      }
    }
    return true
  }

  private func persistAutomaticAgentResolution(
    _ resolution: WorkbenchAIAgentToolResolution,
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    attemptID: UUID
  ) -> Bool {
    guard
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ), binding.continuation.id == continuationID
    else {
      return false
    }
    let updatesReviewDraftBaseline =
      resolution.status == .succeeded
      && resolution.targetDraftID == binding.identity.draftID
    let resolvedReviewDraft =
      updatesReviewDraftBaseline
      ? store.drafts.first(where: { $0.id == binding.identity.draftID })
      : nil
    guard !updatesReviewDraftBaseline || resolvedReviewDraft != nil else {
      return false
    }
    return updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID
    ) { message, continuation in
      guard continuation.phase == .resuming,
        continuation.resumeAttemptID == attemptID,
        continuation.activeStepID == resolution.automationStepID,
        !continuation.resolutions.contains(where: {
          $0.toolCallID == resolution.toolCallID
        })
      else { return false }
      continuation.resolutions.append(resolution)
      continuation.activeStepID = nil
      if let resolvedReviewDraft {
        continuation.reviewDraftFingerprint =
          resolvedReviewDraft.repositoryContentFingerprint
        continuation.reviewDraftUpdatedAt = resolvedReviewDraft.updatedAt
      }
      continuation.revision += 1
      continuation.updatedAt = Date()
      synchronizeAgentReviewMessage(
        &message,
        resolution: resolution
      )
      return true
    }
  }

  private func validatedAgentContinuationRuntimeContext(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    expectedPhase: AIPublishingChatAgentContinuationPhase? = nil,
    expectedAttemptID: UUID? = nil,
    knowledgeAuthorizationState: AgentContinuationKnowledgeAuthorizationState? = nil
  ) async throws -> AgentContinuationRuntimeContext {
    try Task.checkCancellation()
    guard
      let binding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ),
      binding.continuation.id == continuationID,
      binding.message.id == binding.conversation.messages.last?.id,
      expectedPhase.map({ binding.continuation.phase == $0 }) ?? true,
      expectedAttemptID.map({ binding.continuation.resumeAttemptID == $0 }) ?? true,
      let promptRevision = binding.continuation.promptRevision,
      promptRevision
        == AIPublishingChatAgentPromptRevision(
          conversation: binding.conversation
        ),
      aiConversationAgentMode(for: conversationID) != .textOnly,
      let draftID = binding.conversation.draftID,
      let draft = store.drafts.first(where: { $0.id == draftID }),
      let reviewDraftFingerprint = binding.continuation.reviewDraftFingerprint,
      let reviewDraftUpdatedAt = binding.continuation.reviewDraftUpdatedAt,
      draft.repositoryContentFingerprint == reviewDraftFingerprint,
      draft.updatedAt == reviewDraftUpdatedAt
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }

    try await validateAgentContinuationKnowledgeAuthorization(
      continuation: binding.continuation,
      policy: promptRevision.knowledgePolicy,
      failureState: knowledgeAuthorizationState
    )

    let privacyService = AIOutboundPayloadPrivacyService()
    let profile = store.profile(for: draft)
    let currentProviderConfig = privacyService.sanitizedProviderConfig(
      store.aiProviderConfig(for: profile)
    )
    guard currentProviderConfig == binding.continuation.providerConfig else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let frozenKnowledgeContext: KnowledgeContextSnapshot? = {
      guard
        !binding.continuation.knowledgeAuthorizationBindings.isEmpty
          || !binding.message.knowledgeCitations.isEmpty
      else {
        return nil
      }
      return KnowledgeContextSnapshot(
        query: "",
        citations: binding.message.knowledgeCitations,
        authorizationBindings: binding.continuation.knowledgeAuthorizationBindings
      )
    }()
    // The continuation owns the first prompt and its bindings. Reuse a
    // frozen context while resolving the current task config; never trigger
    // retrieval again merely because a review was resumed.
    let currentRequest = await assembledAIChatRequest(
      for: draft,
      conversationIdentity: binding.identity,
      privacyService: privacyService,
      knowledgeContextAssembly: .frozen(
        knowledgeContext: frozenKnowledgeContext,
        explicitContextPrompt: nil
      )
    )
    guard
      let refreshedBinding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ),
      refreshedBinding.continuation.id == continuationID,
      refreshedBinding.conversation == binding.conversation,
      let refreshedDraft = store.drafts.first(where: { $0.id == draft.id }),
      refreshedDraft == draft,
      privacyService.sanitizedProviderConfig(
        store.aiProviderConfig(for: store.profile(for: refreshedDraft))
      ) == currentProviderConfig
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let currentTaskConfig = try aiPublishingAssistantService.resolvedChatTaskConfig(
      for: currentRequest,
      config: currentProviderConfig
    )
    guard currentTaskConfig == binding.continuation.taskConfig,
      currentTaskConfig.capabilitySupport(for: .toolCalling) == .supported,
      let conversationMode = aiConversationAgentMode(for: conversationID)
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let settings = currentTaskConfig.resolvedAdvancedSettings
    let allowsTools = conversationMode.effectiveAllowsTools(
      connectionAllowsTools: settings.resolvedAllowsApplicationTools
    )
    var allowedCommands = WorkbenchAutomationRegistry.agentCommands(
      allowedBy: settings.resolvedAgentPermissionPolicy,
      masterEnabled: allowsTools
    )
    if refreshedBinding.conversation.knowledgePolicy != .automatic {
      allowedCommands.subtract([.knowledgeSearch, .knowledgeRead])
    }

    return AgentContinuationRuntimeContext(
      draft: draft,
      profile: profile,
      taskConfig: currentTaskConfig,
      allowedCommands: allowedCommands,
      loopContext: WorkbenchAIAgentContext(
        goal: binding.plan.goal,
        currentDraft: draft,
        draftVersions: Dictionary(
          uniqueKeysWithValues: store.drafts.map { ($0.id, $0.updatedAt) }
        )
      ),
      conversationRevision: AgentContinuationConversationRevision(
        refreshedBinding.conversation
      ),
      draftFingerprint: draft.repositoryContentFingerprint,
      draftUpdatedAt: draft.updatedAt
    )
  }

  private func validateAgentContinuationKnowledgeAuthorization(
    continuation: AIPublishingChatAgentContinuation,
    policy: KnowledgeRetrievalPolicy,
    failureState: AgentContinuationKnowledgeAuthorizationState? = nil
  ) async throws {
    guard
      await store.knowledge.validateKnowledgeAuthorizationBindings(
        continuation.knowledgeAuthorizationBindings,
        policy: policy
      )
    else {
      failureState?.markChanged()
      throw AIOutboundPayloadConfirmationError.knowledgeAuthorizationChanged
    }
  }

  private func authorizedAgentContinuationModelCompletion(
    _ roundRequest: AIChatCompletionRequest,
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    attemptID: UUID,
    operationID: UUID,
    expectedDraftFingerprint: String,
    expectedDraftUpdatedAt: Date,
    expectedConversationRevision: AgentContinuationConversationRevision,
    expectedAllowedCommands: Set<WorkbenchAutomationCommandID>,
    privacyService: AIOutboundPayloadPrivacyService,
    knowledgeAuthorizationState: AgentContinuationKnowledgeAuthorizationState? = nil
  ) async throws -> AIChatCompletionResult {
    try checkAIChatOperation(operationID)
    let beforeApproval = try await validatedAgentContinuationRuntimeContext(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID,
      expectedPhase: .sending,
      expectedAttemptID: attemptID,
      knowledgeAuthorizationState: knowledgeAuthorizationState
    )
    guard beforeApproval.draft.repositoryContentFingerprint == expectedDraftFingerprint,
      beforeApproval.draft.updatedAt == expectedDraftUpdatedAt,
      beforeApproval.conversationRevision == expectedConversationRevision,
      beforeApproval.allowedCommands == expectedAllowedCommands
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }

    let bindingValues = [
      "agent-continuation",
      continuationID.uuidString.lowercased(),
      attemptID.uuidString.lowercased(),
    ]
    let initialTransport = try aiPublishingAssistantService.prepareTransport(
      completion: roundRequest,
      taskConfig: beforeApproval.taskConfig,
      privacyService: privacyService,
      contextBindingValues: bindingValues
    )
    let outcome = await AIOutboundPayloadApprovalBroker.shared.requestApproval(
      for: initialTransport.payload.preview,
      scopeID: conversationID
    )
    guard case .confirmed(let confirmation) = outcome else {
      throw AIOutboundPayloadConfirmationError.cancelled
    }
    try checkAIChatOperation(operationID)

    let afterApproval = try await validatedAgentContinuationRuntimeContext(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID,
      expectedPhase: .sending,
      expectedAttemptID: attemptID,
      knowledgeAuthorizationState: knowledgeAuthorizationState
    )
    guard afterApproval.draft.repositoryContentFingerprint == expectedDraftFingerprint,
      afterApproval.draft.updatedAt == expectedDraftUpdatedAt,
      afterApproval.conversationRevision == expectedConversationRevision,
      afterApproval.allowedCommands == expectedAllowedCommands,
      afterApproval.taskConfig == beforeApproval.taskConfig
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let refreshedTransport = try aiPublishingAssistantService.prepareTransport(
      completion: roundRequest,
      taskConfig: afterApproval.taskConfig,
      privacyService: privacyService,
      contextBindingValues: bindingValues,
      now: initialTransport.payload.preview.createdAt,
      nonce: initialTransport.payload.preview.nonce
    )
    try privacyService.validate(
      confirmation: confirmation,
      prepared: refreshedTransport.payload
    )
    let authorizedTransport = refreshedTransport.bindingAuthorizationDeadline(
      refreshedTransport.payload.preview.expiresAt
    )
    let authorization = AIOutboundPayloadTransportAuthorization(
      confirmation: confirmation,
      prepared: authorizedTransport.payload,
      privacyService: privacyService
    )
    let token = try aiChatAvailableAPIKey(for: afterApproval.profile)
    guard
      let currentBinding = agentContinuationBinding(
        conversationID: conversationID,
        messageID: messageID,
        planID: planID
      ), currentBinding.continuation.id == continuationID
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    try await validateAgentContinuationKnowledgeAuthorization(
      continuation: currentBinding.continuation,
      policy: afterApproval.conversationRevision.knowledgePolicy,
      failureState: knowledgeAuthorizationState
    )
    try authorization.consume()
    try checkAIChatOperation(operationID)
    return try await aiPublishingAssistantService.completePreparedResult(
      authorizedTransport,
      apiKey: token
    )
  }

  private func persistCompletedAgentContinuation(
    _ result: WorkbenchAIAgentLoopResult,
    binding: AgentContinuationBinding,
    attemptID: UUID
  ) throws {
    let content = result.assistantText
      .joined(separator: "\n\n")
      .trimmedForPublishing
    guard !content.isEmpty else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    guard
      let currentDraft = store.drafts.first(where: {
        $0.id == binding.identity.draftID
      })
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let extraction = AIChatFollowUpSuggestionService.extractOrInferSuggestions(
      content: content,
      draft: currentDraft,
      hasAutomationPlan: false
    )
    let priorCallIDs = Set(binding.continuation.checkpoint.toolRuns.map(\.toolCallID))
    let newRuns = result.toolRuns.filter { !priorCallIDs.contains($0.toolCallID) }
    let assistantMessage = AIPublishingChatMessage(
      role: .assistant,
      content: extraction.displayContent,
      model: binding.continuation.taskConfig.normalizedModel,
      contextMode: binding.message.contextMode,
      toolRuns: newRuns,
      followUpSuggestions: extraction.suggestions
    )
    let transactionSnapshot = captureAgentContinuationStoreSnapshot()
    let didUpdate = updateAgentContinuation(
      conversationID: binding.identity.conversationID,
      messageID: binding.message.id,
      planID: binding.plan.id,
      continuationID: binding.continuation.id
    ) { message, continuation in
      guard continuation.phase == .sending,
        continuation.resumeAttemptID == attemptID
      else { return false }
      mergeAgentToolRuns(&message, from: result.toolRuns)
      message.agentContinuation = nil
      return true
    }
    guard didUpdate else { throw AIOutboundPayloadConfirmationError.drifted }
    updateAIChatSession(for: binding.identity) { messages in
      guard messages.last?.id == binding.message.id else { return }
      messages.append(assistantMessage)
    }
    let didFlush = store.flushPendingChanges()
    guard didFlush, !store.persistenceStore.isRecoveryWriteProtected else {
      restoreAgentContinuationStoreSnapshot(transactionSnapshot)
      markAgentContinuationDeliveryUncertain(
        conversationID: binding.identity.conversationID,
        messageID: binding.message.id,
        planID: binding.plan.id,
        continuationID: binding.continuation.id,
        attemptID: attemptID,
        preservingToolRuns: result.toolRuns
      )
      throw AIOutboundPayloadConfirmationError.drifted
    }
    store.setAIChatMessage(CoreL10n.text("AI 已根据审阅结果继续完成。"))
  }

  private func persistNextAgentReview(
    _ result: WorkbenchAIAgentLoopResult,
    binding: AgentContinuationBinding,
    attemptID: UUID
  ) throws {
    guard let plan = result.pendingPlan,
      let checkpoint = result.checkpoint,
      let promptRevision = binding.continuation.promptRevision,
      let currentDraft = store.drafts.first(where: {
        $0.id == binding.identity.draftID
      })
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let messageID = UUID()
    let continuation = AIPublishingChatAgentContinuation(
      ownerConversationID: binding.identity.conversationID,
      ownerScope: binding.conversation.scope,
      ownerMessageID: messageID,
      planID: plan.id,
      requestTemplate: binding.continuation.requestTemplate,
      checkpoint: checkpoint,
      providerConfig: binding.continuation.providerConfig,
      taskConfig: binding.continuation.taskConfig,
      promptRevision: promptRevision,
      reviewDraftFingerprint: currentDraft.repositoryContentFingerprint,
      reviewDraftUpdatedAt: currentDraft.updatedAt,
      knowledgeAuthorizationBindings:
        binding.continuation.knowledgeAuthorizationBindings
    )
    guard continuation.isValidForPersistence else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    let priorCallIDs = Set(binding.continuation.checkpoint.toolRuns.map(\.toolCallID))
    let newRuns = result.toolRuns.filter { !priorCallIDs.contains($0.toolCallID) }
    let content = result.assistantText
      .joined(separator: "\n\n")
      .trimmedForPublishing
    let assistantMessage = AIPublishingChatMessage(
      id: messageID,
      role: .assistant,
      content: content.isEmpty
        ? CoreL10n.text("AI 已生成一份待确认的应用内操作计划。")
        : content,
      model: binding.continuation.taskConfig.normalizedModel,
      contextMode: binding.message.contextMode,
      toolRuns: newRuns,
      agentContinuation: continuation,
      automationPlan: plan
    )
    let transactionSnapshot = captureAgentContinuationStoreSnapshot()
    let didUpdate = updateAgentContinuation(
      conversationID: binding.identity.conversationID,
      messageID: binding.message.id,
      planID: binding.plan.id,
      continuationID: binding.continuation.id
    ) { message, current in
      guard current.phase == .sending,
        current.resumeAttemptID == attemptID
      else { return false }
      mergeAgentToolRuns(&message, from: result.toolRuns)
      message.agentContinuation = nil
      return true
    }
    guard didUpdate else { throw AIOutboundPayloadConfirmationError.drifted }
    updateAIChatSession(for: binding.identity) { messages in
      guard messages.last?.id == binding.message.id else { return }
      messages.append(assistantMessage)
    }
    let didFlush = store.flushPendingChanges()
    guard didFlush, !store.persistenceStore.isRecoveryWriteProtected else {
      restoreAgentContinuationStoreSnapshot(transactionSnapshot)
      markAgentContinuationDeliveryUncertain(
        conversationID: binding.identity.conversationID,
        messageID: binding.message.id,
        planID: binding.plan.id,
        continuationID: binding.continuation.id,
        attemptID: attemptID,
        preservingToolRuns: result.toolRuns
      )
      throw AIOutboundPayloadConfirmationError.drifted
    }
    store.setAIChatMessage(CoreL10n.text("AI 已生成下一组待确认操作。"))
  }

  private func markAgentContinuationDeliveryUncertain(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    attemptID: UUID? = nil,
    preservingToolRuns: [WorkbenchAIAgentToolRunRecord] = []
  ) {
    _ = updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID
    ) { message, continuation in
      guard attemptID == nil || continuation.resumeAttemptID == attemptID,
        !continuation.phase.isTerminal,
        continuation.phase != .deliveryUncertain
      else { return false }
      mergeAgentToolRuns(
        &message,
        from: preservingToolRuns,
        appendingUnmatched: !preservingToolRuns.isEmpty
      )
      continuation.phase = .deliveryUncertain
      continuation.activeStepID = nil
      continuation.revision += 1
      continuation.updatedAt = Date()
      return true
    }
    _ = store.flushPendingChanges()
  }

  private func markAgentContinuationCancelled(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    attemptID: UUID
  ) {
    _ = updateAgentContinuation(
      conversationID: conversationID,
      messageID: messageID,
      planID: planID,
      continuationID: continuationID
    ) { _, continuation in
      let matchesStartedAttempt = continuation.resumeAttemptID == attemptID
      let failedBeforeAttemptWasPersisted =
        continuation.phase == .awaitingReview
        && continuation.resumeAttemptID == nil
      guard matchesStartedAttempt || failedBeforeAttemptWasPersisted else {
        return false
      }
      continuation.phase = .cancelled
      continuation.activeStepID = nil
      continuation.revision += 1
      continuation.updatedAt = Date()
      return true
    }
    _ = store.flushPendingChanges()
  }

  func hasUndisposedAgentDeliveryUncertainty(in conversationID: UUID?) -> Bool {
    guard let conversationID else { return false }
    return aiConversations.first(where: { $0.id == conversationID })?.messages.contains {
      guard let phase = $0.agentContinuation?.phase else { return false }
      switch phase {
      case .applyingDecision, .resuming, .sending, .deliveryUncertain:
        return true
      case .awaitingReview, .cancelled, .abandonedAfterDeliveryUncertain:
        return false
      }
    } == true
  }

  /// Returns true when a user action must be blocked until an uncertain
  /// delivery is explicitly closed. Ordinary awaiting-review continuations
  /// remain usable; transient phases are included defensively so an in-memory
  /// persistence failure can never expose a mutable continuation to deletion
  /// or a second send.
  @discardableResult
  func blockChatMutationForDeliveryUncertainty(conversationID: UUID?) -> Bool {
    guard hasUndisposedAgentDeliveryUncertainty(in: conversationID) else {
      return false
    }
    store.setAIChatMessage(
      CoreL10n.text("当前 AI 续跑结果不确定，请先结束该任务后再发送、删除或清空对话。")
    )
    return true
  }

  private func captureAgentContinuationStoreSnapshot() -> AgentContinuationStoreSnapshot {
    AgentContinuationStoreSnapshot(
      conversations: aiConversations,
      activeDraftConversationIDs: activeAIConversationIDsByDraftID,
      activeScopeConversationIDs: activeAIConversationIDsByScope,
      chatDraftID: aiChatDraftID,
      chatTitle: aiChatConversationTitle,
      chatMessages: aiChatMessages,
      chatContextMode: aiChatContextMode,
      chatKnowledgePolicy: aiChatKnowledgePolicy,
      chatModelGrade: aiChatModelGrade,
      chatReasoningLevel: aiChatReasoningLevel,
      chatSelectedModel: aiChatSelectedModel,
      chatFocusedParagraphID: aiChatFocusedParagraphID
    )
  }

  private func restoreAgentContinuationStoreSnapshot(
    _ snapshot: AgentContinuationStoreSnapshot
  ) {
    aiConversations = snapshot.conversations
    activeAIConversationIDsByDraftID = snapshot.activeDraftConversationIDs
    activeAIConversationIDsByScope = snapshot.activeScopeConversationIDs
    aiChatDraftID = snapshot.chatDraftID
    aiChatConversationTitle = snapshot.chatTitle
    aiChatMessages = snapshot.chatMessages
    aiChatContextMode = snapshot.chatContextMode
    aiChatKnowledgePolicy = snapshot.chatKnowledgePolicy
    aiChatModelGrade = snapshot.chatModelGrade
    aiChatReasoningLevel = snapshot.chatReasoningLevel
    aiChatSelectedModel = snapshot.chatSelectedModel
    aiChatFocusedParagraphID = snapshot.chatFocusedParagraphID
  }

  private func agentContinuationBinding(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    includingArchived: Bool = false
  ) -> AgentContinuationBinding? {
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && (includingArchived || !$0.isArchived)
      }),
      let draftID = conversation.draftID
    else {
      return nil
    }
    let identity = AIChatConversationIdentity(
      draftID: draftID,
      conversationID: conversationID
    )
    guard let state = aiChatSessionState(for: identity),
      let message = state.messages.first(where: { $0.id == messageID }),
      let plan = message.automationPlan,
      plan.id == planID,
      let continuation = message.agentContinuation,
      continuation.isValidForPersistence,
      continuation.ownerConversationID == conversationID,
      continuation.ownerScope == conversation.scope,
      continuation.ownerMessageID == messageID,
      continuation.planID == planID
    else {
      return nil
    }
    var currentConversation = conversation
    currentConversation.messages = state.messages
    return AgentContinuationBinding(
      conversation: currentConversation,
      identity: identity,
      message: message,
      plan: plan,
      continuation: continuation
    )
  }

  @discardableResult
  private func updateAgentContinuation(
    conversationID: UUID,
    messageID: UUID,
    planID: UUID,
    continuationID: UUID,
    allowArchived: Bool = false,
    update: (inout AIPublishingChatMessage, inout AIPublishingChatAgentContinuation) -> Bool
  ) -> Bool {
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && (allowArchived || !$0.isArchived)
      }),
      let draftID = conversation.draftID
    else { return false }
    let identity = AIChatConversationIdentity(
      draftID: draftID,
      conversationID: conversationID
    )
    var didUpdate = false
    updateAIChatSession(for: identity) { messages in
      guard let index = messages.firstIndex(where: { $0.id == messageID }),
        messages[index].automationPlan?.id == planID
      else { return }
      var message = messages[index]
      guard var continuation = message.agentContinuation,
        continuation.id == continuationID,
        continuation.ownerConversationID == conversationID,
        continuation.ownerScope == conversation.scope,
        continuation.ownerMessageID == messageID,
        continuation.planID == planID,
        update(&message, &continuation)
      else { return }
      if message.agentContinuation == nil {
        message.agentContinuation = nil
      } else {
        guard continuation.isValidForPersistence else { return }
        message.agentContinuation = continuation
      }
      messages[index] = message
      didUpdate = true
    }
    return didUpdate
  }

  private func synchronizeAgentReviewMessage(
    _ message: inout AIPublishingChatMessage,
    resolution: WorkbenchAIAgentToolResolution
  ) {
    if let runIndex = message.toolRuns.firstIndex(where: {
      $0.toolCallID == resolution.toolCallID
    }) {
      switch resolution.status {
      case .succeeded: message.toolRuns[runIndex].status = .succeeded
      case .failed: message.toolRuns[runIndex].status = .failed
      case .rejected: message.toolRuns[runIndex].status = .rejected
      case .cancelled: message.toolRuns[runIndex].status = .cancelled
      }
      message.toolRuns[runIndex].summary = String(
        resolution.content.prefix(WorkbenchAIAgentToolRunRecord.maximumSummaryLength)
      )
      message.toolRuns[runIndex].targetDraftID =
        resolution.targetDraftID ?? message.toolRuns[runIndex].targetDraftID
      message.toolRuns[runIndex].completedAt = resolution.resolvedAt
    }
    if var plan = message.automationPlan,
      let stepIndex = plan.steps.firstIndex(where: {
        $0.id == resolution.automationStepID
      })
    {
      switch resolution.status {
      case .succeeded: plan.steps[stepIndex].status = .succeeded
      case .failed: plan.steps[stepIndex].status = .failed
      case .rejected, .cancelled: plan.steps[stepIndex].status = .cancelled
      }
      plan.steps[stepIndex].resultMessage = String(
        resolution.content.prefix(WorkbenchAIAgentToolRunRecord.maximumSummaryLength)
      )
      message.automationPlan = plan
    }
  }

  private func mergeAgentToolRuns(
    _ message: inout AIPublishingChatMessage,
    from runs: [WorkbenchAIAgentToolRunRecord],
    appendingUnmatched: Bool = false
  ) {
    var existingIDs = Set(message.toolRuns.map(\.toolCallID))
    for run in runs {
      if let index = message.toolRuns.firstIndex(where: {
        $0.toolCallID == run.toolCallID
      }) {
        message.toolRuns[index] = run
      } else if appendingUnmatched, existingIDs.insert(run.toolCallID).inserted {
        message.toolRuns.append(run)
      }
    }
  }
}
