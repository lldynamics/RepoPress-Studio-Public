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
          // A model-proposed mutation is a hard barrier for the rest of the
          // plan. Running a later read-only step against the pre-mutation
          // state would give the model a stale observation and make the
          // eventual confirmed continuation ambiguous. The caller can resume
          // one step at a time after confirmation.
          break
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
        let stepRecord = try await executeStep(step, source: plan.source, in: store)
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
      let currentDraft = step.targetDraftID.flatMap { draftID in
        store.drafts.first(where: { $0.id == draftID })
      }
      let postcondition = WorkbenchAutomationRollbackPostcondition(
        draftID: step.targetDraftID,
        fingerprint: step.postMutationDraftFingerprint,
        updatedAt: step.postMutationDraftUpdatedAt,
        rollbackVersionID: step.rollbackVersionID
      )
      switch step.command {
      case .createDraft:
        switch WorkbenchAutomationRollbackSafetyService.evaluate(
          command: step.command,
          postcondition: postcondition,
          currentDraft: currentDraft
        ) {
        case .safeToMoveCreatedDraftToTrash:
          guard let draftID = step.targetDraftID else { continue }
          store.deleteDraft(id: draftID)
          if !store.drafts.contains(where: { $0.id == draftID }) {
            restoredCount += 1
          } else {
            failureMessages.append(CoreL10n.text("无法将自动化创建的文章移入回收站。"))
          }
        case .safeToRestoreVersion:
          failureMessages.append(CoreL10n.text("新建文章的撤销不能恢复其他文章版本。"))
        case .conflict(let reason):
          failureMessages.append(reason.displayMessage)
        }
      case .deleteDraft:
        guard let draftID = step.targetDraftID else { continue }
        if store.restoreRecycledDraft(draftID) {
          restoredCount += 1
        } else {
          failureMessages.append(CoreL10n.text("无法从回收站恢复自动化删除的文章。"))
        }
      case .updateMetadata, .appendToBody, .replaceBody, .applyDiff, .generateFrontmatter:
        switch WorkbenchAutomationRollbackSafetyService.evaluate(
          command: step.command,
          postcondition: postcondition,
          currentDraft: currentDraft
        ) {
        case .safeToRestoreVersion:
          guard let versionID = step.rollbackVersionID else { continue }
          if store.restoreDraftVersion(versionID) {
            restoredCount += 1
          } else {
            failureMessages.append(
              CoreL10n.format("无法恢复步骤 %@ 的修改前版本。", step.command.rawValue)
            )
          }
        case .safeToMoveCreatedDraftToTrash:
          failureMessages.append(CoreL10n.text("内容修改的撤销不能移除整篇文章。"))
        case .conflict(let reason):
          failureMessages.append(reason.displayMessage)
        }
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
    source: WorkbenchAutomationPlanSource,
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
      if source == .agentLoop {
        store.createGeneralDraft()
      } else {
        store.createDraft()
      }
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
        _ = store.flushPendingChanges()
        throw saveError
      }
      guard let savedDraft = store.drafts.first(where: { $0.id == draft.id }) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      return WorkbenchAutomationStepRecord(
        command: step.command,
        status: .succeeded,
        message: CoreL10n.format("已新建文章“%@”。", draft.title.nilIfEmpty ?? CoreL10n.text("未命名文章")),
        targetDraftID: draft.id,
        postMutationDraftFingerprint: savedDraft.repositoryContentFingerprint,
        postMutationDraftUpdatedAt: savedDraft.updatedAt
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
      guard let result = await store.runPreflight(for: draft.id) else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          CoreL10n.text("文章在检查期间发生变化或已不存在，未完成发布检查。")
        )
      }
      return success(step, CoreL10n.format("发布检查完成：%lld 个问题。", result.issues.count))

    case .refreshPublishPreview:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard await store.refreshPublishPreview(for: draft.id) != nil else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          CoreL10n.text("文章在刷新期间发生变化或已不存在，未完成发布预览。")
        )
      }
      return success(step, CoreL10n.text("已刷新发布预览。"))

    case .saveWorkbench:
      try saveWorkbenchOrThrow(in: store)
      return success(step, CoreL10n.text("工作台已保存。"))

    case .updateMetadata, .appendToBody, .replaceBody, .applyDiff, .generateFrontmatter:
      let draft = try targetDraft(for: step, in: store, checksVersion: true)
      let preview = try WorkbenchAutomationDraftMutationService.preview(step: step, draft: draft)
      let rollbackVersionID = makeRollbackVersionID(
        for: draft,
        in: store
      )
      guard let rollbackVersionID else {
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
      guard let savedDraft = store.drafts.first(where: { $0.id == draft.id }) else {
        throw WorkbenchAutomationValidationError.draftNotFound
      }
      return WorkbenchAutomationStepRecord(
        command: step.command,
        status: .succeeded,
        message: contentMutationSuccessMessage(step.command),
        targetDraftID: draft.id,
        rollbackVersionID: rollbackVersionID,
        postMutationDraftFingerprint: savedDraft.repositoryContentFingerprint,
        postMutationDraftUpdatedAt: savedDraft.updatedAt
      )

    case .draftRead:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      let mode = step.arguments.mode ?? "full"
      let message: String
      switch mode {
      case "outline":
        let headings = draft.bodyMarkdown
          .components(separatedBy: .newlines)
          .filter { $0.hasPrefix("#") }
          .joined(separator: "\n")
        message = CoreL10n.format(
          "文章《%@》大纲（总计 %lld 字）：\n%@",
          draft.title.nilIfEmpty ?? CoreL10n.text("未命名"),
          draft.bodyMarkdown.count,
          headings.isEmpty ? CoreL10n.text("（无标题层级）") : headings
        )
      case "paragraph_range":
        let paragraphs = draft.bodyMarkdown
          .components(separatedBy: "\n\n")
          .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let selected: [String]
        if !step.arguments.paragraphIndices.isEmpty {
          selected = step.arguments.paragraphIndices.compactMap { idx in
            guard idx >= 0, idx < paragraphs.count else { return nil }
            return "[\(idx)] \(paragraphs[idx])"
          }
        } else {
          selected = paragraphs.enumerated().map { "[\($0)] \($1)" }
        }
        message = CoreL10n.format(
          "文章《%@》选定段落（共 %lld 个段落）：\n%@",
          draft.title.nilIfEmpty ?? CoreL10n.text("未命名"),
          selected.count,
          selected.joined(separator: "\n\n")
        )
      default:
        message = CoreL10n.format(
          "文章《%@》（总计 %lld 字）：\n%@",
          draft.title.nilIfEmpty ?? CoreL10n.text("未命名"),
          draft.bodyMarkdown.count,
          draft.bodyMarkdown
        )
      }
      return success(step, message)

    case .searchDrafts:
      guard store.canUseProtectedWorkbench else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          store.quickHideOperationMessage
        )
      }
      guard let query = step.arguments.query?.trimmedForPublishing.nilIfEmpty else {
        throw WorkbenchAutomationValidationError.missingArgument("query")
      }
      let profileID = store.activeProfile.id
      let searchableDrafts = store.drafts.filter {
        $0.siteProfileID == profileID && !$0.isPrivate
      }
      let hits = WorkbenchAgentDraftSearchService().search(
        query: query,
        drafts: searchableDrafts,
        limit: 8
      )
      let rows = hits.map { hit in
        let title = String(hit.title.prefix(120))
        let snippet = String(hit.snippet.prefix(240))
        return
          "- draftID=\(hit.draftID.uuidString); title=\(title); field=\(hit.field); snippet=\(snippet)"
      }
      let body =
        rows.isEmpty
        ? CoreL10n.text("没有找到匹配的公开文章。")
        : rows.joined(separator: "\n")
      return success(
        step,
        CoreL10n.format(
          "本地文章搜索完成，共返回 %lld 条；私密文章未纳入搜索。\n%@",
          hits.count,
          body
        )
      )

    case .knowledgeSearch:
      guard store.canUseProtectedWorkbench else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          store.quickHideOperationMessage
        )
      }
      guard let query = step.arguments.query?.trimmedForPublishing.nilIfEmpty else {
        throw WorkbenchAutomationValidationError.missingArgument("query")
      }
      let hits = try await WorkbenchAgentKnowledgeService(
        library: store.knowledge.service
      ).search(query: query, limit: 8)
      let rows = hits.map { hit in
        var fields = [
          "documentID=\(hit.documentID.uuidString)",
          "chunkID=\(hit.chunkID.uuidString)",
          "title=\(hit.title)",
        ]
        if let locator = hit.locator?.nilIfEmpty {
          fields.append("locator=\(locator)")
        }
        if !hit.signals.isEmpty {
          fields.append("signals=\(hit.signals.joined(separator: ","))")
        }
        if let sourceURL = hit.sourceURL {
          fields.append("sourceURL=\(sourceURL.absoluteString)")
        }
        fields.append("excerpt=\(hit.excerpt)")
        return "- " + fields.joined(separator: "; ")
      }
      let body =
        rows.isEmpty
        ? CoreL10n.text("没有找到允许远程 AI 使用的匹配资料。")
        : rows.joined(separator: "\n")
      return success(
        step,
        String(
          CoreL10n.format(
            "本地资料库搜索完成，共返回 %lld 条；仅检索明确允许远程 AI 使用且未归档的资料。\n%@",
            hits.count,
            body
          ).prefix(3_800)
        )
      )

    case .knowledgeRead:
      guard store.canUseProtectedWorkbench else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          store.quickHideOperationMessage
        )
      }
      guard let documentID = step.arguments.documentID else {
        throw WorkbenchAutomationValidationError.missingArgument("documentID")
      }
      let document = try await WorkbenchAgentKnowledgeService(
        library: store.knowledge.service
      ).read(documentID: documentID)
      let maximumTextCharacters = 3_400
      let text = String(document.text.prefix(maximumTextCharacters))
      let toolOutputWasTruncated = document.isTruncated || document.text.count > text.count
      return success(
        step,
        """
        已读取允许远程 AI 使用的本地资料；未访问网络，也未读取原始文件。
        documentID=\(document.documentID.uuidString); title=\(document.title); truncated=\(toolOutputWasTruncated)
        \(text)
        """
      )

    case .auditContent:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard
        let summary = WorkbenchAgentContentAuditService().audit(
          draft: draft,
          profile: store.profile(for: draft)
        )
      else {
        throw CancellationError()
      }
      let findings = summary.findings.prefix(8).map { finding in
        let field = finding.field.map { " [\($0)]" } ?? ""
        return
          "- \(finding.severity.rawValue)\(field): \(String(finding.title.prefix(100))) — \(String(finding.message.prefix(220)))"
      }
      let findingText =
        findings.isEmpty
        ? CoreL10n.text("没有可报告的问题。")
        : findings.joined(separator: "\n")
      return success(
        step,
        """
        本地内容审计完成；未修改文章，也未访问网络。
        draftID=\(summary.draftID.uuidString); status=\(summary.status.rawValue); errors=\(summary.errorCount); warnings=\(summary.warningCount); informational=\(summary.informationalCount); partial=\(summary.isPartial)
        \(findingText)
        """
      )

    case .webFetch:
      guard let urlString = step.arguments.url?.trimmedForPublishing.nilIfEmpty,
        let url = URL(string: urlString)
      else {
        throw WorkbenchAutomationValidationError.missingArgument("url")
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      let response = try await KnowledgeWebDownloadClient().download(
        request: request,
        maximumByteCount: 500_000
      )
      let rawHTML = String(decoding: response.data, as: UTF8.self)
      let cleanText =
        rawHTML
        .replacingOccurrences(
          of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression
        )
        .replacingOccurrences(
          of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression
        )
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let sample = String(cleanText.prefix(3_000))
      return success(step, CoreL10n.format("已抓取网页内容（约 %lld 字符）：\n%@", sample.count, sample))

    case .webSearch:
      guard step.arguments.query?.trimmedForPublishing.nilIfEmpty != nil else {
        throw WorkbenchAutomationValidationError.missingArgument("query")
      }
      throw WorkbenchAutomationExecutionError.operationDidNotComplete(
        CoreL10n.text("联网搜索服务尚未配置，未执行搜索。请改用已授权的网页抓取或资料库来源。")
      )

    case .siteCheckLinks:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      guard
        let inspection = WorkbenchAgentStaticLinkInspectionService().inspect(
          markdown: draft.bodyMarkdown
        )
      else {
        throw CancellationError()
      }
      let diagnostics = inspection.diagnostics.prefix(12).map { diagnostic in
        "- offset=\(diagnostic.sourceOffset); kind=\(diagnostic.kind.rawValue); \(String(diagnostic.message.prefix(220)))"
      }
      let diagnosticText =
        diagnostics.isEmpty
        ? CoreL10n.text("未发现 Markdown 链接格式问题。")
        : diagnostics.joined(separator: "\n")
      return success(
        step,
        """
        本地静态链接检查完成：链接 \(inspection.discoveredLinkCount) 个，图片引用 \(inspection.discoveredImageCount) 个，格式诊断 \(inspection.formatDiagnosticCount) 个，输入截断=\(inspection.inputWasTruncated)。
        网络可用性未验证；不得据此声称链接可访问。
        \(diagnosticText)
        """
      )

    case .siteOptimizeImages:
      let draft = try targetDraft(for: step, in: store, checksVersion: false)
      await store.refreshImageWorkbenchReportInBackground(for: draft)
      let report = store.cachedImageWorkbenchReport(for: draft)
      let summary = WorkbenchAgentImageReportFormatter.summary(for: report)
      guard summary.availability == .available else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          summary.unavailableReason ?? CoreL10n.text("没有可用的真实图片检查报告。")
        )
      }
      let issues = summary.issues.prefix(8).map { issue in
        "- \(issue.severity.rawValue): \(String(issue.title.prefix(100))) — \(String(issue.message.prefix(220)))"
      }
      let issueText =
        issues.isEmpty
        ? CoreL10n.text("真实图片报告未发现问题。")
        : issues.joined(separator: "\n")
      return success(
        step,
        """
        真实图片报告读取完成；未优化或修改任何文件。
        images=\(summary.imageCount); issues=\(summary.issueCount); errors=\(summary.errorCount); warnings=\(summary.warningCount); missingAlt=\(summary.missingAltTextCount); missingSource=\(summary.missingSourceCount); optimizableJPEG=\(summary.optimizableJPEGCount); webPConvertible=\(summary.webPConvertibleCount); omittedIssues=\(summary.omittedIssueCount)
        \(issueText)
        """
      )

    case .siteDeployStatus:
      guard let release = store.activeProfileReleaseRecords.first else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          CoreL10n.text("当前站点没有可检查的发布记录，未执行部署状态检查。")
        )
      }
      guard store.canCheckDeploymentStatus(for: release) else {
        let readiness = store.deploymentStatusReadiness(for: release)
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          readiness.fallbackMessage.nilIfEmpty
            ?? CoreL10n.text("当前发布记录未配置可用的部署状态来源。")
        )
      }
      guard
        let snapshot = await store.refreshDeploymentStatus(
          for: release,
          updatesMessage: false
        )
      else {
        throw WorkbenchAutomationExecutionError.operationDidNotComplete(
          CoreL10n.text("部署状态服务没有返回经过验证的结果。")
        )
      }
      let signals = snapshot.signals.prefix(8).map { signal in
        "- \(signal.level.rawValue): \(String(signal.title.prefix(100))) — \(String(signal.message.prefix(220)))"
      }
      return success(
        step,
        """
        已从配置的部署状态来源完成真实检查。
        provider=\(snapshot.provider.rawValue); level=\(snapshot.level.rawValue); title=\(String(snapshot.title.prefix(160))); message=\(String(snapshot.message.prefix(360)))
        \(signals.joined(separator: "\n"))
        """
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
      // Rebuild and validate the exact current package before entering the
      // batch publisher. The publisher returns validation failures as nil
      // plus UI state, which is too lossy for the automation executor to
      // distinguish scope drift from a real operation failure. This guard
      // keeps all authorization/scope drift on the awaiting-confirmation
      // path and therefore guarantees zero transport.
      try await validatePublishAuthorizationBeforeExecution(
        authorization,
        in: store
      )
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

  private static func validatePublishAuthorizationBeforeExecution(
    _ authorization: AIPublishAuthorizationSnapshot,
    in store: WorkbenchStore
  ) async throws {
    try AIPublishAuthorizationService.validateTarget(
      authorization,
      profile: store.activeProfile
    )

    await store.refreshBatchPublishPlanAsync()
    let profile = store.activeProfile
    guard let plan = store.batchPublishPlan,
      plan.profileID == profile.id,
      let package = store.remotePublishPackage(for: plan)
    else {
      throw AIPublishAuthorizationError.changed(
        CoreL10n.text("执行前复核发现授权范围已变化")
      )
    }

    let preview = store.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: store.preferredRemoteRepositoryPublishMode(for: profile),
      extraWarningIssues: store.batchRemoteRepositoryPublishWarningIssues(for: plan)
    )
    try AIPublishAuthorizationService.validate(
      authorization,
      package: package,
      preview: preview,
      profile: profile,
      repositoryReport: store.repositoryReport(for: profile)
    )
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

  private static func makeRollbackVersionID(
    for draft: ArticleDraft,
    in store: WorkbenchStore
  ) -> UUID? {
    let existingVersions = store.versions(for: draft.id)
    if let equivalentVersion = existingVersions.first(where: {
      equivalentDraftContent($0.draft, draft)
    }) {
      return equivalentVersion.id
    }

    guard store.createManualVersion(for: draft.id) else {
      // A concurrent/manual snapshot may have become equivalent between the
      // first lookup and createManualVersion's de-duplication check. Re-read
      // before declaring the mutation unsafe.
      return store.versions(for: draft.id)
        .first(where: { equivalentDraftContent($0.draft, draft) })?.id
    }
    return store.versions(for: draft.id)
      .first(where: { !existingVersions.contains($0) })?.id
  }

  private static func equivalentDraftContent(
    _ lhs: ArticleDraft,
    _ rhs: ArticleDraft
  ) -> Bool {
    var normalizedLHS = lhs
    var normalizedRHS = rhs
    normalizedLHS.updatedAt = .distantPast
    normalizedRHS.updatedAt = .distantPast
    return normalizedLHS == normalizedRHS
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
    case .applyDiff:
      return CoreL10n.text("局部修改已应用，并已保存修改前版本。")
    case .generateFrontmatter:
      return CoreL10n.text("Frontmatter 元数据已更新，并已保存修改前版本。")
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
