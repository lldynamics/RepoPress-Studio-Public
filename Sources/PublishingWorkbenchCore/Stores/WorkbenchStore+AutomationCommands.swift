import Foundation

@MainActor
public enum WorkbenchAutomationExecutor {
  public static func execute(
    plan: WorkbenchAutomationPlan,
    in store: WorkbenchStore,
    onlyStepID: UUID? = nil,
    confirmedStepIDs: Set<UUID> = [],
    shouldCancel: () -> Bool = { false }
  ) async -> WorkbenchAutomationExecutionResult {
    let startedAt = Date()
    var updatedPlan = plan
    var records: [WorkbenchAutomationStepRecord] = []

    do {
      try WorkbenchAutomationPlanValidator.validateStructure(plan)
    } catch {
      if let index = updatedPlan.steps.indices.first {
        updatedPlan.steps[index].status = .failed
        updatedPlan.steps[index].resultMessage = error.localizedDescription
      }
      records.append(
        WorkbenchAutomationStepRecord(
          command: updatedPlan.steps.first?.command ?? .openSection,
          status: .failed,
          message: error.localizedDescription
        )
      )
      return result(plan: updatedPlan, startedAt: startedAt, records: records)
    }

    for index in updatedPlan.steps.indices {
      if let onlyStepID, updatedPlan.steps[index].id != onlyStepID {
        continue
      }
      if updatedPlan.steps[index].status == .succeeded
        || updatedPlan.steps[index].status == .cancelled {
        continue
      }
      if shouldCancel() || Task.isCancelled {
        updatedPlan.steps[index].status = .cancelled
        updatedPlan.steps[index].resultMessage = CoreL10n.text("已取消，未执行。")
        records.append(
          WorkbenchAutomationStepRecord(
            command: updatedPlan.steps[index].command,
            status: .cancelled,
            message: CoreL10n.text("已取消，未执行。"),
            targetDraftID: updatedPlan.steps[index].arguments.draftID
          )
        )
        continue
      }

      let step = updatedPlan.steps[index]
      guard let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command) else {
        updatedPlan.steps[index].status = .failed
        updatedPlan.steps[index].resultMessage = WorkbenchAutomationValidationError.unsupportedCommand.localizedDescription
        records.append(
          WorkbenchAutomationStepRecord(
            command: step.command,
            status: .failed,
            message: WorkbenchAutomationValidationError.unsupportedCommand.localizedDescription,
            targetDraftID: step.arguments.draftID
          )
        )
        break
      }

      if descriptor.risk.requiresExplicitConfirmation,
         !confirmedStepIDs.contains(step.id) {
        updatedPlan.steps[index].status = .awaitingConfirmation
        updatedPlan.steps[index].resultMessage = CoreL10n.text("等待你确认后执行。")
        records.append(
          WorkbenchAutomationStepRecord(
            command: step.command,
            status: .awaitingConfirmation,
            message: CoreL10n.text("等待用户确认。"),
            targetDraftID: step.arguments.draftID
          )
        )
        continue
      }

      updatedPlan.steps[index].status = .running
      do {
        let stepRecord = try await executeStep(step, in: store)
        updatedPlan.steps[index].status = .succeeded
        updatedPlan.steps[index].resultMessage = stepRecord.message
        records.append(stepRecord)
      } catch {
        updatedPlan.steps[index].status = .failed
        updatedPlan.steps[index].resultMessage = error.localizedDescription
        records.append(
          WorkbenchAutomationStepRecord(
            command: step.command,
            status: .failed,
            message: error.localizedDescription,
            targetDraftID: step.arguments.draftID
          )
        )
        break
      }
    }

    return result(plan: updatedPlan, startedAt: startedAt, records: records)
  }

  public static func draftPreview(
    for step: WorkbenchAutomationStep,
    in store: WorkbenchStore
  ) throws -> WorkbenchAutomationDraftPreview {
    try WorkbenchAutomationPlanValidator.validateArguments(step)
    guard let draftID = step.arguments.draftID else {
      throw WorkbenchAutomationValidationError.missingArgument("draftID")
    }
    store.flushDraftBodyEditorBuffer(for: draftID)
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
      throw WorkbenchAutomationValidationError.draftNotFound
    }
    return try WorkbenchAutomationDraftMutationService.preview(step: step, draft: draft)
  }

  public static func rollback(
    record: WorkbenchAutomationRunRecord,
    in store: WorkbenchStore
  ) -> Int {
    var restoredCount = 0
    for step in record.steps.reversed() where step.status == .succeeded {
      if let versionID = step.rollbackVersionID,
         store.restoreDraftVersion(versionID) {
        restoredCount += 1
        continue
      }
      guard let draftID = step.targetDraftID else { continue }
      switch step.command {
      case .createDraft:
        if store.drafts.contains(where: { $0.id == draftID }) {
          store.deleteDraft(id: draftID)
          restoredCount += 1
        }
      case .deleteDraft:
        if store.restoreRecycledDraft(draftID) {
          restoredCount += 1
        }
      default:
        break
      }
    }
    if restoredCount > 0 {
      store.save()
    }
    return restoredCount
  }

  private static func executeStep(
    _ step: WorkbenchAutomationStep,
    in store: WorkbenchStore
  ) async throws -> WorkbenchAutomationStepRecord {
    try WorkbenchAutomationPlanValidator.validateArguments(step)

    switch step.command {
    case .openSection:
      guard let section = step.arguments.section,
            WorkspaceVisibilityPolicy.commandPaletteSections.contains(section) else {
        throw WorkbenchAutomationValidationError.missingArgument("section")
      }
      store.selectSection(section)
      return success(step, CoreL10n.text("已切换到目标工作区。"))

    case .selectDraft:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard store.focusDraft(draft.id, section: .writing) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      return success(step, CoreL10n.format("已打开文章“%@”。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")))

    case .createDraft:
      store.createDraft()
      guard var draft = store.selectedDraft else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      if let title = step.arguments.value?.trimmedForPublishing.nilIfEmpty {
        draft.title = title
        store.updateDraft(draft)
      }
      store.selectSection(.writing)
      store.save()
      return WorkbenchAutomationStepRecord(
        command: step.command,
        status: .succeeded,
        message: CoreL10n.format("已新建文章“%@”。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")),
        targetDraftID: draft.id
      )

    case .focusEditor:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      let allowedFields = Set(["body", "title", "summary", "slug"])
      guard let field = step.arguments.editorField?.trimmedForPublishing,
            allowedFields.contains(field) else {
        throw WorkbenchAutomationValidationError.missingArgument("editorField")
      }
      guard store.focusDraft(draft.id, section: .writing) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      store.requestEditorFocus(draftID: draft.id, field: field)
      return success(step, CoreL10n.text("已聚焦文章编辑器。"))

    case .showInspector:
      store.setInspectorPresented(true)
      return success(step, CoreL10n.text("已打开 Inspector。"))

    case .runPreflight:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard store.focusDraft(draft.id) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      store.runPreflight()
      return success(step, CoreL10n.format("发布检查完成：%lld 个问题。", store.preflightIssues.count))

    case .refreshPublishPreview:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      store.refreshPublishPreview(for: draft)
      return success(step, CoreL10n.text("已刷新发布预览。"))

    case .saveWorkbench:
      store.save()
      return success(step, CoreL10n.text("工作台已保存。"))

    case .updateMetadata, .appendToBody, .replaceBody:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      let preview = try WorkbenchAutomationDraftMutationService.preview(step: step, draft: draft)
      let existingVersionIDs = Set(store.versions(for: draft.id).map(\.id))
      _ = store.createManualVersion(for: draft.id)
      let rollbackVersionID = store.versions(for: draft.id).first { !existingVersionIDs.contains($0.id) }?.id
      store.updateDraft(preview.updatedDraft)
      store.save()
      return WorkbenchAutomationStepRecord(
        command: step.command,
        status: .succeeded,
        message: contentMutationSuccessMessage(step.command),
        targetDraftID: draft.id,
        rollbackVersionID: rollbackVersionID
      )

    case .deleteDraft:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      store.deleteDraft(id: draft.id)
      return success(step, CoreL10n.format("已将“%@”移到回收站。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")))

    case .writeLocalRepository:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      guard store.focusDraft(draft.id, section: .sync) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      await store.writeSelectedDraftToLocalRepository()
      return success(
        step,
        store.publishActionMessage?.nilIfEmpty ?? CoreL10n.text("本地仓库写入流程已完成。")
      )

    case .publishOnline:
      store.selectSection(.sync)
      guard let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy() else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          store.publishActionMessage?.nilIfEmpty ?? CoreL10n.text("全部变更的线上发布未完成。")
        )
      }
      return success(
        step,
        CoreL10n.format("全部变更已发布，共处理 %lld 个文件。", result.changedPaths.count)
      )
    }
  }

  private static func targetDraft(
    for step: WorkbenchAutomationStep,
    in store: WorkbenchStore,
    checksVersion: Bool
  ) throws -> ArticleDraft {
    guard let draftID = step.arguments.draftID else {
      throw WorkbenchAutomationValidationError.missingArgument("draftID")
    }
    store.flushDraftBodyEditorBuffer(for: draftID)
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
      throw WorkbenchAutomationValidationError.draftNotFound
    }
    if checksVersion,
       let expected = step.arguments.expectedDraftUpdatedAt,
       expected != draft.updatedAt {
      throw WorkbenchAutomationValidationError.staleDraft
    }
    return draft
  }

  private static func success(
    _ step: WorkbenchAutomationStep,
    _ message: String
  ) -> WorkbenchAutomationStepRecord {
    WorkbenchAutomationStepRecord(
      command: step.command,
      status: .succeeded,
      message: message,
      targetDraftID: step.arguments.draftID
    )
  }

  private static func contentMutationSuccessMessage(
    _ command: WorkbenchAutomationCommandID
  ) -> String {
    switch command {
    case .updateMetadata:
      return CoreL10n.text("文章元数据已更新，并已保存修改前版本。")
    case .appendToBody:
      return CoreL10n.text("正文已追加，并已保存修改前版本。")
    case .replaceBody:
      return CoreL10n.text("正文已替换，并已保存修改前版本。")
    default:
      return CoreL10n.text("内容已更新。")
    }
  }

  private static func result(
    plan: WorkbenchAutomationPlan,
    startedAt: Date,
    records: [WorkbenchAutomationStepRecord]
  ) -> WorkbenchAutomationExecutionResult {
    WorkbenchAutomationExecutionResult(
      plan: plan,
      record: WorkbenchAutomationRunRecord(
        planID: plan.id,
        goal: plan.goal,
        startedAt: startedAt,
        steps: records
      )
    )
  }
}

public enum WorkbenchAutomationExecutionError: Error, Equatable, LocalizedError, Sendable {
  case operationDidNotComplete(String)

  public var errorDescription: String? {
    switch self {
    case .operationDidNotComplete(let message):
      return message
    }
  }
}
