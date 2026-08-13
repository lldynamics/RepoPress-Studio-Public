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
        || updatedPlan.steps[index].status == .cancelled
      {
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
      guard WorkbenchAutomationRegistry.descriptor(for: step.command) != nil else {
        updatedPlan.steps[index].status = .failed
        updatedPlan.steps[index].resultMessage =
          WorkbenchAutomationValidationError.unsupportedCommand.localizedDescription
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

      let requiresConfirmation = plan.requiresConfirmation(for: step)
      let needsPublishAuthorization =
        step.command == .publishOnline
        && step.publishAuthorization == nil
      if requiresConfirmation,
        !confirmedStepIDs.contains(step.id),
        !(plan.source == .legacy && needsPublishAuthorization)
      {
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
        if plan.source == .agentLoop, onlyStepID == nil {
          continue
        }
        break
      }

      if needsPublishAuthorization {
        do {
          let authorization = try await AIPublishAuthorizationService.prepare(in: store)
          updatedPlan.steps[index].publishAuthorization = authorization
          updatedPlan.steps[index].status = .awaitingConfirmation
          updatedPlan.steps[index].resultMessage = CoreL10n.text("发布目标和完整文件范围已锁定，等待你确认。")
          records.append(
            WorkbenchAutomationStepRecord(
              command: step.command,
              status: .awaitingConfirmation,
              message: CoreL10n.text("已生成不可变的线上发布授权快照。")
            )
          )
        } catch {
          updatedPlan.steps[index].status = .awaitingConfirmation
          updatedPlan.steps[index].resultMessage = error.localizedDescription
          records.append(
            WorkbenchAutomationStepRecord(
              command: step.command,
              status: .awaitingConfirmation,
              message: error.localizedDescription
            )
          )
        }
        break
      }

      updatedPlan.steps[index].status = .running
      do {
        let stepRecord = try await executeStep(step, in: store)
        updatedPlan.steps[index].status = .succeeded
        updatedPlan.steps[index].resultMessage = stepRecord.message
        records.append(stepRecord)
      } catch let error as AIPublishAuthorizationError where error.requiresReconfirmation {
        updatedPlan.steps[index].publishAuthorization = nil
        updatedPlan.steps[index].status = .awaitingConfirmation
        updatedPlan.steps[index].resultMessage = error.localizedDescription
        records.append(
          WorkbenchAutomationStepRecord(
            command: step.command,
            status: .awaitingConfirmation,
            message: error.localizedDescription,
            targetDraftID: step.arguments.draftID
          )
        )
        break
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
    rollbackDetailed(record: record, in: store).restoredCount
  }

  public static func rollbackDetailed(
    record: WorkbenchAutomationRunRecord,
    in store: WorkbenchStore
  ) -> WorkbenchAutomationRollbackResult {
    var restoredCount = 0
    var failureMessages: [String] = []
    for step in record.steps.reversed() where step.status == .succeeded {
      if let versionID = step.rollbackVersionID {
        if store.restoreDraftVersion(versionID) {
          restoredCount += 1
        } else {
          failureMessages.append(
            CoreL10n.format("无法恢复步骤 %@ 的修改前版本。", step.command.rawValue)
          )
        }
        continue
      }
      guard let draftID = step.targetDraftID else { continue }
      switch step.command {
      case .createDraft:
        if store.drafts.contains(where: { $0.id == draftID }) {
          store.deleteDraft(id: draftID)
          if store.permanentlyDeleteRecycledDraft(draftID) {
            restoredCount += 1
          } else {
            failureMessages.append(CoreL10n.text("无法完整移除自动化创建的文章。"))
          }
        }
      case .deleteDraft:
        if store.restoreRecycledDraft(draftID) {
          restoredCount += 1
        } else {
          failureMessages.append(CoreL10n.text("无法从回收站恢复自动化删除的文章。"))
        }
      case .updateMetadata, .appendToBody, .replaceBody:
        failureMessages.append(
          CoreL10n.format("步骤 %@ 缺少可用的修改前版本。", step.command.rawValue)
        )
      default:
        break
      }
    }
    let persistenceSucceeded = restoredCount == 0 || store.flushPendingChanges()
    return WorkbenchAutomationRollbackResult(
      restoredCount: restoredCount,
      failureMessages: failureMessages,
      persistenceSucceeded: persistenceSucceeded
    )
  }

  private static func executeStep(
    _ step: WorkbenchAutomationStep,
    in store: WorkbenchStore
  ) async throws -> WorkbenchAutomationStepRecord {
    try WorkbenchAutomationPlanValidator.validateArguments(step)

    switch step.command {
    case .openSection:
      guard let section = step.arguments.section,
        WorkspaceVisibilityPolicy.commandPaletteSections.contains(section)
      else {
        throw WorkbenchAutomationValidationError.missingArgument("section")
      }
      store.selectSection(section)
      return success(step, CoreL10n.text("已切换到目标工作区。"))

    case .selectDraft:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard store.focusDraft(draft.id, section: .writing) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      return success(
        step, CoreL10n.format("已打开文章“%@”。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")))

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
      do {
        try saveWorkbenchOrThrow(in: store)
      } catch let saveError {
        store.deleteDraft(id: draft.id)
        let didRemoveCreatedDraft = store.permanentlyDeleteRecycledDraft(draft.id)
        _ = store.flushPendingChanges()
        guard didRemoveCreatedDraft else {
          throw WorkbenchAutomationExecutionError.operationDidNotComplete(
            CoreL10n.format(
              "新建文章保存失败：%@；自动回滚也失败，请检查回收站。",
              saveError.localizedDescription
            )
          )
        }
        throw saveError
      }
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
        allowedFields.contains(field)
      else {
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
      await store.runPreflightAndWait()
      return success(step, CoreL10n.format("发布检查完成：%lld 个问题。", store.preflightIssues.count))

    case .refreshPublishPreview:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      store.refreshPublishPreview(for: draft)
      return success(step, CoreL10n.text("已刷新发布预览。"))

    case .saveWorkbench:
      try saveWorkbenchOrThrow(in: store)
      return success(step, CoreL10n.text("工作台已保存。"))

    case .updateMetadata, .appendToBody, .replaceBody:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      let preview = try WorkbenchAutomationDraftMutationService.preview(step: step, draft: draft)
      let existingVersionIDs = Set(store.versions(for: draft.id).map(\.id))
      guard store.createManualVersion(for: draft.id),
        let rollbackVersionID = store.versions(for: draft.id)
          .first(where: { !existingVersionIDs.contains($0.id) })?.id
      else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          CoreL10n.text("无法创建修改前版本，未执行文章变更。")
        )
      }
      store.updateDraft(preview.updatedDraft)
      do {
        try saveWorkbenchOrThrow(in: store)
      } catch let saveError {
        guard store.restoreDraftVersion(rollbackVersionID) else {
          throw WorkbenchAutomationExecutionError.operationDidNotComplete(
            CoreL10n.format(
              "文章保存失败：%@；自动恢复修改前版本也失败。",
              saveError.localizedDescription
            )
          )
        }
        _ = store.flushPendingChanges()
        throw saveError
      }
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
      do {
        try saveWorkbenchOrThrow(in: store)
      } catch let saveError {
        guard store.restoreRecycledDraft(draft.id) else {
          throw WorkbenchAutomationExecutionError.operationDidNotComplete(
            CoreL10n.format(
              "文章移入回收站后保存失败：%@；自动恢复文章也失败。",
              saveError.localizedDescription
            )
          )
        }
        _ = store.flushPendingChanges()
        throw saveError
      }
      return success(
        step, CoreL10n.format("已将“%@”移到回收站。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")))

    case .writeLocalRepository:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      guard store.focusDraft(draft.id, section: .sync) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      let writeResult = await store.writeSelectedDraftToLocalRepository()
      switch writeResult {
      case .succeeded(let writtenPaths, let message):
        return success(
          step,
          message.nilIfEmpty
            ?? CoreL10n.format("已写入本地仓库，共处理 %lld 个文件。", writtenPaths.count)
        )
      case .writtenButRecordSaveFailed(_, let message):
        throw WorkbenchAutomationExecutionError.externalEffectPartiallyCompleted(message)
      case .failed(let message):
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          message.nilIfEmpty ?? CoreL10n.text("本地仓库写入未完成。")
        )
      }

    case .publishOnline:
      guard let authorization = step.publishAuthorization else {
        throw AIPublishAuthorizationError.changed(
          CoreL10n.text("缺少本次确认对应的不可变发布快照")
        )
      }
      store.selectSection(.sync)
      guard
        let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
          expectedChangedPaths: Set(authorization.scope.changedPaths),
          authorization: authorization
        )
      else {
        if AIPublishAuthorizationError.isReconfirmationMessage(store.publishActionMessage) {
          throw AIPublishAuthorizationError.changed(
            CoreL10n.text("执行前复核发现授权范围已变化")
          )
        }
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
    if checksVersion {
      guard let expected = step.arguments.expectedDraftUpdatedAt,
        expected == draft.updatedAt
      else {
        throw WorkbenchAutomationValidationError.staleDraft
      }
    }
    return draft
  }

  private static func saveWorkbenchOrThrow(in store: WorkbenchStore) throws {
    guard store.flushPendingChanges() else {
      throw WorkbenchAutomationExecutionError.operationDidNotComplete(
        CoreL10n.text("工作台保存失败，未将本步骤标记为成功。")
      )
    }
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
  case externalEffectPartiallyCompleted(String)

  public var errorDescription: String? {
    switch self {
    case .operationDidNotComplete(let message):
      return message
    case .externalEffectPartiallyCompleted(let message):
      return message
    }
  }
}

public struct WorkbenchAutomationRollbackResult: Equatable, Sendable {
  public var restoredCount: Int
  public var failureMessages: [String]
  public var persistenceSucceeded: Bool

  public init(
    restoredCount: Int,
    failureMessages: [String],
    persistenceSucceeded: Bool
  ) {
    self.restoredCount = restoredCount
    self.failureMessages = failureMessages
    self.persistenceSucceeded = persistenceSucceeded
  }

  public var completedWithoutFailures: Bool {
    failureMessages.isEmpty && persistenceSucceeded
  }
}
