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
    guard !binding.message.isRetiredAgentRecord else {
      setAIChatMessage(
        AIAgentRetirement.message
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

  private func executeBoundAutomationPlan(
    _ binding: AutomationMessageBinding,
    messageID: AIPublishingChatMessage.ID,
    onlyStepID: UUID?,
    confirmedStepIDs: Set<UUID>
  ) async -> WorkbenchAutomationExecutionResult? {
    guard !aiWorkspaceStore.isAutomationRunning else {
      setAIChatMessage(WorkbenchAutomationValidationError.operationInProgress.localizedDescription)
      return nil
    }

    aiWorkspaceStore.isAutomationRunning = true
    aiWorkspaceStore.activeAutomationPlanID = binding.plan.id
    aiWorkspaceStore.automationCancellationRequested = false
    setAIChatMessage(CoreL10n.text("正在执行应用内操作计划…"))
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
      guard message.automationPlan?.id == binding.plan.id else { return false }
      message.automationPlan = result.plan
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
    setAIChatMessage(automationCompletionMessage(for: result.plan))
    save()
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
    guard !binding.message.isRetiredAgentRecord else {
      setAIChatMessage(AIAgentRetirement.message)
      return
    }
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
    return AutomationMessageBinding(
      identity: AIChatConversationIdentity(
        draftID: draftID,
        conversationID: conversationID
      ),
      message: message,
      plan: plan
    )
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
    if plan.steps.contains(where: { step in
      step.command == .publishOnline
        && AIPublishAuthorizationError.isReconfirmationMessage(step.resultMessage)
    }) {
      return CoreL10n.text("发布授权已失效，请重新审阅完整文件清单并确认。")
    }
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
