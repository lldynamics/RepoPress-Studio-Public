import Foundation

extension WorkbenchStore {
  @discardableResult
  public func executeAutomationPlan(
    messageID: AIPublishingChatMessage.ID,
    onlyStepID: UUID? = nil,
    confirmedStepIDs: Set<UUID> = []
  ) async -> WorkbenchAutomationExecutionResult? {
    guard !aiWorkspaceStore.isAutomationRunning else {
      setAIChatMessage(WorkbenchAutomationValidationError.operationInProgress.localizedDescription)
      return nil
    }
    guard let draftID = aiChatDraftID,
          let message = aiChatMessages.first(where: { $0.id == messageID }),
          let plan = message.automationPlan else {
      setAIChatMessage(CoreL10n.text("找不到要执行的自动化计划。"))
      return nil
    }

    aiWorkspaceStore.isAutomationRunning = true
    aiWorkspaceStore.activeAutomationPlanID = plan.id
    aiWorkspaceStore.automationCancellationRequested = false
    setAIChatMessage(CoreL10n.text("正在执行应用内操作计划…"))
    defer {
      aiWorkspaceStore.isAutomationRunning = false
      aiWorkspaceStore.activeAutomationPlanID = nil
      aiWorkspaceStore.automationCancellationRequested = false
    }

    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: self,
      onlyStepID: onlyStepID,
      confirmedStepIDs: confirmedStepIDs,
      shouldCancel: { [weak self] in
        self?.aiWorkspaceStore.automationCancellationRequested ?? true
      }
    )

    aiStore.updateAIChatSession(for: draftID) { messages in
      guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
      messages[index].automationPlan = result.plan
    }
    recordAutomationRun(result.record)
    setAIChatMessage(automationCompletionMessage(for: result.plan))
    save()
    return result
  }

  public func automationDraftPreview(
    messageID: AIPublishingChatMessage.ID,
    stepID: UUID
  ) -> WorkbenchAutomationDraftPreview? {
    guard let message = aiChatMessages.first(where: { $0.id == messageID }),
          let step = message.automationPlan?.steps.first(where: { $0.id == stepID }) else {
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

  public func cancelAutomationPlan(messageID: AIPublishingChatMessage.ID) {
    if aiWorkspaceStore.isAutomationRunning {
      aiWorkspaceStore.automationCancellationRequested = true
      setAIChatMessage(CoreL10n.text("正在停止自动化计划；当前步骤结束后不会继续。"))
      return
    }
    guard let draftID = aiChatDraftID else { return }
    aiStore.updateAIChatSession(for: draftID) { messages in
      guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
            var plan = messages[messageIndex].automationPlan else { return }
      for index in plan.steps.indices where !plan.steps[index].status.isTerminal {
        plan.steps[index].status = .cancelled
        plan.steps[index].resultMessage = CoreL10n.text("已取消，未执行。")
      }
      messages[messageIndex].automationPlan = plan
    }
    setAIChatMessage(CoreL10n.text("自动化计划已取消。"))
  }

  @discardableResult
  public func rollbackAutomationRun(_ recordID: UUID) -> Int {
    guard let record = aiWorkspaceStore.automationRunRecords.first(where: { $0.id == recordID }) else {
      setAIChatMessage(CoreL10n.text("找不到自动化执行记录。"))
      return 0
    }
    let count = WorkbenchAutomationExecutor.rollback(record: record, in: self)
    if count > 0,
       let index = aiWorkspaceStore.automationRunRecords.firstIndex(where: { $0.id == recordID }) {
      aiWorkspaceStore.automationRunRecords[index].rolledBackAt = Date()
      save()
    }
    setAIChatMessage(
      count > 0
        ? CoreL10n.format("已撤销 %lld 项自动化修改。", count)
        : CoreL10n.text("这条执行记录没有可自动撤销的本地修改。")
    )
    return count
  }

  private func recordAutomationRun(_ record: WorkbenchAutomationRunRecord) {
    guard record.steps.contains(where: { $0.status.isTerminal }) else { return }
    aiWorkspaceStore.automationRunRecords.insert(record, at: 0)
    if aiWorkspaceStore.automationRunRecords.count > WorkbenchAutomationRunRecord.maximumHistoryCount {
      aiWorkspaceStore.automationRunRecords = Array(
        aiWorkspaceStore.automationRunRecords.prefix(WorkbenchAutomationRunRecord.maximumHistoryCount)
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
