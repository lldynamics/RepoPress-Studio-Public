import Foundation

private struct AutomationMessageBinding {
  let identity: AIChatConversationIdentity
  let message: AIPublishingChatMessage
  let plan: WorkbenchAutomationPlan
}

extension WorkbenchStore {
  @discardableResult
  public func executeAutomationPlan(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID,
    onlyStepID: UUID? = nil,
    confirmedStepIDs: Set<UUID> = []
  ) async -> WorkbenchAutomationExecutionResult? {
    guard
      let binding = automationMessageBinding(
        conversationID: conversationID,
        messageID: messageID
      )
    else {
      setAIChatMessage(CoreL10n.text("找不到要执行的自动化计划。"))
      return nil
    }
    guard binding.message.agentContinuation == nil else {
      setAIChatMessage(
        CoreL10n.text("AI 操作由审阅流程继续，不能单独执行自动步骤。")
      )
      return nil
    }

    return await executeBoundAutomationPlan(
      binding,
      messageID: messageID,
      onlyStepID: onlyStepID,
      confirmedStepIDs: confirmedStepIDs
    )
  }

  /// Accepts exactly one Agent-proposed content mutation after validating the
  /// conversation, plan, step, and preview compare-and-swap baseline. The
  /// executor is entered only after every guard passes.
  @discardableResult
  public func acceptAutomationStep(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID,
    stepID: UUID,
    previewBaselineFingerprint: String
  ) async -> WorkbenchAutomationExecutionResult? {
    guard !aiWorkspaceStore.isAutomationRunning else {
      setAIChatMessage(WorkbenchAutomationValidationError.operationInProgress.localizedDescription)
      return nil
    }
    guard
      let binding = automationMessageBinding(
        conversationID: conversationID,
        messageID: messageID
      ),
      binding.plan.source == .agentLoop,
      let step = binding.plan.steps.first(where: { $0.id == stepID }),
      let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command),
      descriptor.risk == .contentChange,
      step.status == .proposed || step.status == .awaitingConfirmation,
      let draftID = step.arguments.draftID,
      draftID == binding.identity.draftID,
      let baseline = previewBaselineFingerprint.trimmedForPublishing.nilIfEmpty
    else {
      setAIChatMessage(CoreL10n.text("这条 AI 修改已失效，未执行。"))
      return nil
    }

    guard
      !binding.message.reviewDecisions.contains(where: {
        $0.planID == binding.plan.id && $0.stepID == stepID
      })
    else {
      setAIChatMessage(CoreL10n.text("这条 AI 修改已经有审阅决定，未重复执行。"))
      return nil
    }

    flushDraftBodyEditorBuffer(for: draftID)
    guard let currentDraft = drafts.first(where: { $0.id == draftID }),
      currentDraft.repositoryContentFingerprint == baseline
    else {
      setAIChatMessage(CoreL10n.text("文章已发生变化，AI 修改未执行；请重新预览。"))
      return nil
    }

    if binding.message.agentContinuation != nil {
      guard
        aiStore.markAgentContinuationApplyingDecision(
          conversationID: conversationID,
          messageID: messageID,
          planID: binding.plan.id,
          stepID: stepID
        )
      else {
        setAIChatMessage(CoreL10n.text("原 AI 对话已变化，未执行这条修改。"))
        return nil
      }
    }

    let toolCallID = binding.message.toolRuns.first {
      $0.automationStepID == stepID
    }?.toolCallID
    let decision = AIPublishingChatReviewDecision(
      choice: .accepted,
      planID: binding.plan.id,
      stepID: stepID,
      toolCallID: toolCallID,
      previewBaselineFingerprint: baseline
    )
    setAIChatMessage(CoreL10n.text("正在应用已接受的 AI 修改…"))
    return await executeBoundAutomationPlan(
      binding,
      messageID: messageID,
      onlyStepID: stepID,
      confirmedStepIDs: [stepID],
      reviewDecision: decision
    )
  }

  /// Rejects one Agent-proposed content mutation without entering the
  /// executor. It is deliberately asynchronous so a fully resolved Agent
  /// round may continue in the originating conversation.
  @discardableResult
  public func rejectAutomationStep(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID,
    stepID: UUID,
    previewBaselineFingerprint: String? = nil
  ) async -> Bool {
    guard !aiWorkspaceStore.isAutomationRunning,
      let binding = automationMessageBinding(
        conversationID: conversationID,
        messageID: messageID
      ),
      binding.plan.source == .agentLoop,
      let step = binding.plan.steps.first(where: { $0.id == stepID }),
      let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command),
      descriptor.risk == .contentChange
    else {
      setAIChatMessage(CoreL10n.text("这条 AI 修改已失效，未记录拒绝。"))
      return false
    }
    if let existingDecision = binding.message.reviewDecisions.first(where: {
      $0.planID == binding.plan.id && $0.stepID == stepID
    }) {
      guard existingDecision.choice == .rejected else {
        setAIChatMessage(CoreL10n.text("这条 AI 修改已被接受，不能再拒绝。"))
        return false
      }
      setAIChatMessage(CoreL10n.text("这条 AI 修改已经拒绝，未重复记录。"))
      return true
    }
    guard step.status == .proposed || step.status == .awaitingConfirmation else {
      setAIChatMessage(CoreL10n.text("这条 AI 修改已失效，未记录拒绝。"))
      return false
    }

    let toolCallID = binding.message.toolRuns.first {
      $0.automationStepID == stepID
    }?.toolCallID
    let decision = AIPublishingChatReviewDecision(
      choice: .rejected,
      planID: binding.plan.id,
      stepID: stepID,
      toolCallID: toolCallID,
      previewBaselineFingerprint: previewBaselineFingerprint
    )
    let didUpdate = updateAutomationMessage(
      binding,
      messageID: messageID
    ) { message in
      guard var plan = message.automationPlan,
        let index = plan.steps.firstIndex(where: { $0.id == stepID })
      else { return false }
      plan.steps[index].status = .cancelled
      plan.steps[index].resultMessage = CoreL10n.text("用户已拒绝此修改，未执行。")
      message.automationPlan = plan
      message.reviewDecisions.append(decision)
      markRejectedAutomationToolRun(
        in: &message,
        stepID: stepID,
        toolCallID: toolCallID
      )
      return true
    }
    guard didUpdate else {
      setAIChatMessage(CoreL10n.text("原 AI 对话已变化，拒绝未写回。"))
      return false
    }
    if binding.message.agentContinuation != nil {
      guard let toolCallID,
        await aiStore.recordAgentContinuationResolution(
          conversationID: conversationID,
          messageID: messageID,
          planID: binding.plan.id,
          resolution: WorkbenchAIAgentToolResolution(
            toolCallID: toolCallID,
            automationStepID: stepID,
            command: step.command,
            status: .rejected,
            content: "The user rejected this proposed action; it was not executed.",
            targetDraftID: step.arguments.draftID
          )
        )
      else {
        setAIChatMessage(CoreL10n.text("已拒绝 AI 修改，但未继续请求模型。"))
        return true
      }
    }
    if binding.message.agentContinuation == nil {
      setAIChatMessage(CoreL10n.text("已拒绝 AI 修改，文章未变化。"))
      save()
    } else if agentContinuationPhase(
      conversationID: conversationID,
      messageID: messageID
    ) == .awaitingReview {
      setAIChatMessage(CoreL10n.text("已记录拒绝决定，等待审阅其余 AI 操作。"))
    }
    return true
  }

  private func executeBoundAutomationPlan(
    _ binding: AutomationMessageBinding,
    messageID: AIPublishingChatMessage.ID,
    onlyStepID: UUID?,
    confirmedStepIDs: Set<UUID>,
    reviewDecision: AIPublishingChatReviewDecision? = nil
  ) async -> WorkbenchAutomationExecutionResult? {
    guard !aiWorkspaceStore.isAutomationRunning else {
      setAIChatMessage(WorkbenchAutomationValidationError.operationInProgress.localizedDescription)
      return nil
    }

    aiWorkspaceStore.isAutomationRunning = true
    aiWorkspaceStore.activeAutomationPlanID = binding.plan.id
    aiWorkspaceStore.automationCancellationRequested = false
    if reviewDecision == nil {
      setAIChatMessage(CoreL10n.text("正在执行应用内操作计划…"))
    }
    defer {
      aiWorkspaceStore.isAutomationRunning = false
      aiWorkspaceStore.activeAutomationPlanID = nil
      aiWorkspaceStore.automationCancellationRequested = false
    }

    let result = await WorkbenchAutomationExecutor.execute(
      plan: binding.plan,
      in: self,
      onlyStepID: onlyStepID,
      confirmedStepIDs: confirmedStepIDs,
      shouldCancel: { [weak self] in
        self?.aiWorkspaceStore.automationCancellationRequested ?? true
      }
    )

    let didUpdate = updateAutomationMessage(binding, messageID: messageID) { message in
      guard var currentPlan = message.automationPlan,
        currentPlan.id == binding.plan.id
      else { return false }
      if let reviewDecision {
        guard let currentStep = currentPlan.steps.first(where: { $0.id == reviewDecision.stepID }),
          currentStep.status == .proposed || currentStep.status == .awaitingConfirmation,
          !message.reviewDecisions.contains(where: {
            $0.planID == reviewDecision.planID && $0.stepID == reviewDecision.stepID
          })
        else { return false }
      }
      currentPlan = result.plan
      message.automationPlan = currentPlan
      synchronizeAutomationToolRuns(
        in: &message,
        plan: result.plan,
        record: result.record,
        onlyStepID: onlyStepID
      )
      if let reviewDecision {
        message.reviewDecisions.append(reviewDecision)
      }
      return true
    }
    guard didUpdate else {
      // The app mutation has already happened. Preserve the global audit and
      // rollback record even if the originating conversation was removed or
      // replaced while an async step was running, and return the real result
      // so the caller never reports a successful mutation as "not executed".
      recordAutomationRun(result.record)
      setAIChatMessage(
        CoreL10n.text("原 AI 对话已变化；操作结果未能写回对话，但已保留执行与回滚记录。")
      )
      save()
      return result
    }
    recordAutomationRun(result.record)
    var didRecordContinuationResolution: Bool?
    if binding.message.agentContinuation != nil {
      if let reviewDecision,
        let reviewedStep = binding.plan.steps.first(where: { $0.id == reviewDecision.stepID }),
        let stepRecord = result.record.steps.first(where: {
          $0.command == reviewedStep.command
            && $0.targetDraftID == reviewedStep.arguments.draftID
        }),
        let toolCallID = reviewDecision.toolCallID
      {
        didRecordContinuationResolution = await aiStore.recordAgentContinuationResolution(
          conversationID: binding.identity.conversationID,
          messageID: messageID,
          planID: binding.plan.id,
          resolution: WorkbenchAIAgentToolResolution(
            toolCallID: toolCallID,
            automationStepID: reviewDecision.stepID,
            command: stepRecord.command,
            status: continuationResolutionStatus(for: stepRecord.status),
            content: String(
              stepRecord.message.prefix(WorkbenchAIAgentToolResolution.maximumContentByteCount)
            ),
            targetDraftID: stepRecord.targetDraftID,
            resolvedAt: stepRecord.completedAt
          )
        )
      } else {
        didRecordContinuationResolution = false
      }
    }
    if binding.message.agentContinuation == nil {
      setAIChatMessage(automationCompletionMessage(for: result.plan))
      save()
    } else if didRecordContinuationResolution != true {
      setAIChatMessage(
        CoreL10n.text("AI 修改已应用，但续跑状态未能安全写入；不会自动重试。")
      )
    } else if agentContinuationPhase(
      conversationID: binding.identity.conversationID,
      messageID: messageID
    ) == .awaitingReview {
      setAIChatMessage(CoreL10n.text("已应用 AI 修改，等待审阅其余操作。"))
    }
    return result
  }

  public func automationDraftPreview(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID,
    stepID: UUID
  ) -> WorkbenchAutomationDraftPreview? {
    guard
      let binding = automationMessageBinding(
        conversationID: conversationID,
        messageID: messageID
      ),
      let step = binding.plan.steps.first(where: { $0.id == stepID })
    else {
      setAIChatMessage(CoreL10n.text("找不到要预览的自动化步骤。"))
      return nil
    }
    do {
      return try WorkbenchAutomationExecutor.draftPreview(for: step, in: self)
    } catch {
      setAIChatMessage(error.localizedDescription)
      return nil
    }
  }

  public func cancelAutomationPlan(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID
  ) {
    guard
      let binding = automationMessageBinding(
        conversationID: conversationID,
        messageID: messageID
      )
    else { return }
    if aiWorkspaceStore.isAutomationRunning {
      guard aiWorkspaceStore.activeAutomationPlanID == binding.plan.id else { return }
      aiWorkspaceStore.automationCancellationRequested = true
      setAIChatMessage(CoreL10n.text("正在停止自动化计划；当前步骤结束后不会继续。"))
      return
    }
    let didUpdate = updateAutomationMessage(binding, messageID: messageID) { message in
      guard var plan = message.automationPlan else { return false }
      for index in plan.steps.indices where !plan.steps[index].status.isTerminal {
        plan.steps[index].status = .cancelled
        plan.steps[index].resultMessage = CoreL10n.text("已取消，未执行。")
      }
      message.automationPlan = plan
      message.agentContinuation = nil
      for index in message.toolRuns.indices
      where message.toolRuns[index].status == .awaitingConfirmation {
        message.toolRuns[index].status = .cancelled
        message.toolRuns[index].completedAt = Date()
        message.toolRuns[index].summary = boundedAutomationReviewSummary(
          CoreL10n.text("自动化计划已取消，工具未执行。")
        )
      }
      return true
    }
    guard didUpdate else { return }
    if flushPendingChanges() {
      setAIChatMessage(CoreL10n.text("自动化计划已取消。"))
    } else {
      setAIChatMessage(CoreL10n.text("自动化计划已取消，但取消状态保存失败。"))
    }
  }

  private func automationMessageBinding(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID
  ) -> AutomationMessageBinding? {
    guard
      let conversation = aiConversations.first(where: {
        $0.id == conversationID && !$0.isArchived
      }), let draftID = conversation.draftID,
      let message = conversation.messages.first(where: { $0.id == messageID }),
      let plan = message.automationPlan
    else { return nil }
    guard
      message.agentContinuation.map({ continuation in
        continuation.ownerConversationID == conversationID
          && continuation.ownerScope == conversation.scope
          && continuation.ownerMessageID == messageID
          && continuation.planID == plan.id
      }) ?? true
    else {
      return nil
    }
    return AutomationMessageBinding(
      identity: AIChatConversationIdentity(
        draftID: draftID,
        conversationID: conversationID
      ),
      message: message,
      plan: plan
    )
  }

  private func agentContinuationPhase(
    conversationID: UUID,
    messageID: AIPublishingChatMessage.ID
  ) -> AIPublishingChatAgentContinuationPhase? {
    aiConversations
      .first(where: { $0.id == conversationID })?
      .messages
      .first(where: { $0.id == messageID })?
      .agentContinuation?
      .phase
  }

  @discardableResult
  private func updateAutomationMessage(
    _ binding: AutomationMessageBinding,
    messageID: AIPublishingChatMessage.ID,
    update: (inout AIPublishingChatMessage) -> Bool
  ) -> Bool {
    guard let state = aiStore.aiChatSessionState(for: binding.identity),
      state.messages.contains(where: { $0.id == messageID })
    else {
      return false
    }

    var didUpdate = false
    aiStore.updateAIChatSession(for: binding.identity) { messages in
      guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
      didUpdate = update(&messages[index])
    }
    return didUpdate
  }

  private func synchronizeAutomationToolRuns(
    in message: inout AIPublishingChatMessage,
    plan: WorkbenchAutomationPlan,
    record: WorkbenchAutomationRunRecord,
    onlyStepID: UUID?
  ) {
    var consumedToolCallIDs = Set<String>()
    for stepRecord in record.steps {
      guard
        let toolRunIndex = message.toolRuns.indices.first(where: { index in
          let run = message.toolRuns[index]
          guard !consumedToolCallIDs.contains(run.toolCallID),
            run.command == stepRecord.command,
            let automationStepID = run.automationStepID,
            plan.steps.contains(where: {
              $0.id == automationStepID && $0.command == stepRecord.command
            })
          else { return false }
          return onlyStepID == nil || automationStepID == onlyStepID
        })
      else { continue }

      consumedToolCallIDs.insert(message.toolRuns[toolRunIndex].toolCallID)
      message.toolRuns[toolRunIndex].status = toolRunStatus(for: stepRecord.status)
      message.toolRuns[toolRunIndex].summary = boundedAutomationReviewSummary(stepRecord.message)
      message.toolRuns[toolRunIndex].targetDraftID =
        stepRecord.targetDraftID ?? message.toolRuns[toolRunIndex].targetDraftID
      message.toolRuns[toolRunIndex].completedAt =
        stepRecord.status.isTerminal ? stepRecord.completedAt : nil
    }
  }

  private func markRejectedAutomationToolRun(
    in message: inout AIPublishingChatMessage,
    stepID: UUID,
    toolCallID: String?
  ) {
    for index in message.toolRuns.indices
    where
      message.toolRuns[index].automationStepID == stepID
      || (toolCallID != nil && message.toolRuns[index].toolCallID == toolCallID)
    {
      message.toolRuns[index].status = .rejected
      message.toolRuns[index].completedAt = Date()
      message.toolRuns[index].summary = boundedAutomationReviewSummary(
        CoreL10n.text("该操作已被用户拒绝，未执行。")
      )
    }
  }

  private func toolRunStatus(
    for status: WorkbenchAutomationStepStatus
  ) -> WorkbenchAIAgentToolRunStatus {
    switch status {
    case .succeeded:
      return .succeeded
    case .failed:
      return .failed
    case .cancelled:
      return .cancelled
    case .proposed, .running, .awaitingConfirmation:
      return .awaitingConfirmation
    }
  }

  private func continuationResolutionStatus(
    for status: WorkbenchAutomationStepStatus
  ) -> WorkbenchAIAgentToolResolutionStatus {
    switch status {
    case .succeeded:
      return .succeeded
    case .failed:
      return .failed
    case .cancelled:
      return .cancelled
    case .proposed, .running, .awaitingConfirmation:
      return .failed
    }
  }

  private func boundedAutomationReviewSummary(_ summary: String) -> String {
    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > WorkbenchAIAgentToolRunRecord.maximumSummaryLength else {
      return normalized
    }
    return String(normalized.prefix(WorkbenchAIAgentToolRunRecord.maximumSummaryLength - 3)) + "..."
  }

  @discardableResult
  public func rollbackAutomationRun(_ recordID: UUID) -> Int {
    guard let record = aiWorkspaceStore.automationRunRecords.first(where: { $0.id == recordID })
    else {
      setAIChatMessage(CoreL10n.text("找不到自动化执行记录。"))
      return 0
    }
    let result = WorkbenchAutomationExecutor.rollbackDetailed(record: record, in: self)
    if result.restoredCount > 0,
      result.completedWithoutFailures,
      let index = aiWorkspaceStore.automationRunRecords.firstIndex(where: { $0.id == recordID })
    {
      aiWorkspaceStore.automationRunRecords[index].rolledBackAt = Date()
      if !flushPendingChanges() {
        setAIChatMessage(CoreL10n.text("本地修改已撤销，但撤销记录保存失败。"))
        return result.restoredCount
      }
    }
    if result.completedWithoutFailures {
      setAIChatMessage(
        result.restoredCount > 0
          ? CoreL10n.format("已撤销 %lld 项自动化修改。", result.restoredCount)
          : CoreL10n.text("这条执行记录没有可自动撤销的本地修改。")
      )
    } else {
      var details = result.failureMessages
      if !result.persistenceSucceeded {
        details.append(CoreL10n.text("恢复后的工作台状态未能保存。"))
      }
      setAIChatMessage(
        CoreL10n.format(
          "已撤销 %lld 项，但仍有问题：%@",
          result.restoredCount,
          details.joined(separator: "；")
        )
      )
    }
    return result.restoredCount
  }

  func recordAutomationRun(_ record: WorkbenchAutomationRunRecord) {
    guard record.steps.contains(where: { $0.status.isTerminal }) else { return }
    aiWorkspaceStore.automationRunRecords.insert(record, at: 0)
    if aiWorkspaceStore.automationRunRecords.count
      > WorkbenchAutomationRunRecord.maximumHistoryCount
    {
      aiWorkspaceStore.automationRunRecords = Array(
        aiWorkspaceStore.automationRunRecords.prefix(
          WorkbenchAutomationRunRecord.maximumHistoryCount)
      )
    }
  }

  private func automationCompletionMessage(for plan: WorkbenchAutomationPlan) -> String {
    switch plan.status {
    case .succeeded:
      return CoreL10n.text("应用内操作计划已完成。")
    case .awaitingConfirmation, .partiallySucceeded:
      return CoreL10n.text("安全步骤已完成，其余步骤等待你逐项确认。")
    case .failed:
      return CoreL10n.text("自动化计划已停止，请查看失败步骤。")
    case .cancelled:
      return CoreL10n.text("自动化计划已取消。")
    case .proposed:
      return CoreL10n.text("自动化计划尚未执行。")
    case .running:
      return CoreL10n.text("自动化计划正在执行。")
    }
  }
}
