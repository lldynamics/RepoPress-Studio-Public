import Foundation

extension WorkbenchAIStore {
  @discardableResult
  public func applyAIMetadataSuggestion(
    field: AIPublishingMetadataField,
    value: String,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    let suggestion: AIPublishingMetadataSuggestion
    switch field {
    case .title:
      suggestion = AIPublishingMetadataSuggestion(titles: [value])
    case .slug:
      suggestion = AIPublishingMetadataSuggestion(slugs: [value])
    case .summary:
      suggestion = AIPublishingMetadataSuggestion(summary: value)
    case .tags:
      suggestion = AIPublishingMetadataSuggestion(
        tags: AIPublishingMetadataSuggestionParser.parseTagCandidates(value))
    }
    guard let updated = applyAIMetadataSuggestion(suggestion, draft: draft) else {
      if value.trimmedForPublishing.isEmpty {
        aiActionMessage = "AI \(field.displayName)建议为空，未应用。"
      }
      return nil
    }
    aiActionMessage = "已应用 AI \(field.displayName)建议。"
    return updated
  }

  @discardableResult
  public func applyAIMetadataSuggestion(
    _ suggestion: AIPublishingMetadataSuggestion,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    var updated = draft
    var fields: [AIPublishingMetadataField] = []
    var previousTitle: String?
    var newTitle: String?
    var previousSlug: String?
    var newSlug: String?
    var previousSummary: String?
    var newSummary: String?
    var previousTags: [String]?
    var newTags: [String]?

    if let title = suggestion.titles.first?.trimmedForPublishing.nilIfEmpty,
      title != updated.title
    {
      previousTitle = updated.title
      newTitle = title
      updated.title = title
      fields.append(.title)
    }
    if let rawSlug = suggestion.slugs.first?.trimmedForPublishing.nilIfEmpty {
      let slug = SlugService.slug(
        from:
          rawSlug
          .replacingOccurrences(of: ".markdown", with: "")
          .replacingOccurrences(of: ".md", with: "")
      )
      if !slug.isEmpty, slug != updated.slug {
        previousSlug = updated.slug
        newSlug = slug
        updated.slug = slug
        fields.append(.slug)
      }
    }
    if let rawSummary = suggestion.summary {
      let summary = rawSummary.trimmedForPublishing
      if !summary.isEmpty, summary != updated.summary {
        previousSummary = updated.summary
        newSummary = summary
        updated.summary = summary
        fields.append(.summary)
      }
    }
    let tags =
      suggestion.tags.isEmpty
      ? []
      : AIPublishingMetadataSuggestionParser.parseTagCandidates(
        suggestion.tags.joined(separator: "\n"))
    if !tags.isEmpty, tags != updated.tags {
      previousTags = updated.tags
      newTags = tags
      updated.tags = tags
      fields.append(.tags)
    }

    guard !fields.isEmpty else {
      if suggestion.summary?.trimmedForPublishing.isEmpty == true,
        suggestion.titles.isEmpty,
        suggestion.slugs.isEmpty,
        suggestion.tags.isEmpty
      {
        aiActionMessage = "AI 摘要建议为空，未应用。"
      } else {
        aiActionMessage = "AI 元数据建议没有可应用的新内容。"
      }
      return nil
    }

    updated.updatedAt = Date()
    store.updateDraft(updated)
    removeAIMetadataSuggestion(for: updated.id)
    aiMetadataApplicationRecords.insert(
      AIPublishingMetadataApplicationRecord(
        siteProfileID: updated.siteProfileID,
        draftID: updated.id,
        draftTitle: updated.title,
        fields: fields,
        previousTitle: previousTitle,
        newTitle: newTitle,
        previousSlug: previousSlug,
        newSlug: newSlug,
        previousSummary: previousSummary,
        newSummary: newSummary,
        previousTags: previousTags,
        newTags: newTags
      ),
      at: 0
    )
    aiActionMessage = "已应用 AI 元数据建议：\(fields.map(\.displayName).joined(separator: "、"))。"
    refreshSEOSocialPreview(
      for: updated,
      message: "AI 元数据变更后，SEO 社交预览已同步刷新。"
    )
    store.save()
    return updated
  }

  public func recentAIMetadataApplicationRecords(
    for draft: ArticleDraft,
    limit: Int = 10
  ) -> [AIPublishingMetadataApplicationRecord] {
    Array(
      aiMetadataApplicationRecords
        .filter { $0.draftID == draft.id }
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(max(0, limit))
    )
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecord(
    _ record: AIPublishingMetadataApplicationRecord
  ) -> ArticleDraft? {
    guard var draft = store.drafts.first(where: { $0.id == record.draftID }) else {
      aiActionMessage = "找不到要回滚的文章。"
      return nil
    }
    guard canRollbackAIMetadataApplicationRecord(record, draft: draft) else {
      aiActionMessage = "AI 元数据应用记录已不匹配，跳过回滚。"
      return nil
    }
    if record.fields.contains(.title), let previousTitle = record.previousTitle {
      draft.title = previousTitle
    }
    if record.fields.contains(.slug), let previousSlug = record.previousSlug {
      draft.slug = previousSlug
    }
    if record.fields.contains(.summary), let previousSummary = record.previousSummary {
      draft.summary = previousSummary
    }
    if record.fields.contains(.tags), let previousTags = record.previousTags {
      draft.tags = previousTags
    }
    draft.updatedAt = Date()
    store.updateDraft(draft)
    refreshSEOSocialPreview(
      for: draft,
      message: "AI 元数据回滚后，SEO 社交预览已同步刷新。"
    )
    aiActionMessage = "已回滚 AI 元数据应用：\(record.fields.map(\.displayName).joined(separator: "、"))。"
    store.save()
    return draft
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecords(
    _ records: [AIPublishingMetadataApplicationRecord]
  ) -> AIPublishingMetadataApplicationBatchRollbackResult {
    var restoredCount = 0
    var skippedCount = 0
    var failures: [AIPublishingMetadataApplicationRollbackFailure] = []
    for record in records {
      if rollbackAIMetadataApplicationRecord(record) != nil {
        restoredCount += 1
      } else if store.drafts.contains(where: { $0.id == record.draftID }) {
        skippedCount += 1
      } else {
        failures.append(
          AIPublishingMetadataApplicationRollbackFailure(
            recordID: record.id,
            draftTitle: record.draftTitle,
            message: "找不到要回滚的文章。"
          )
        )
      }
    }
    let result = AIPublishingMetadataApplicationBatchRollbackResult(
      requestedCount: records.count,
      restoredCount: restoredCount,
      skippedCount: skippedCount,
      failures: failures
    )
    aiActionMessage =
      "AI 元数据批量回滚完成：恢复 \(restoredCount) 条，跳过 \(skippedCount) 条，失败 \(failures.count) 条。"
    store.save()
    return result
  }

  public func clearAIMetadataApplicationRecords(for draft: ArticleDraft) {
    aiMetadataApplicationRecords.removeAll { $0.draftID == draft.id }
    aiActionMessage = "已清空当前文章的 AI 应用记录。"
    store.save()
  }

  private func canRollbackAIMetadataApplicationRecord(
    _ record: AIPublishingMetadataApplicationRecord,
    draft: ArticleDraft
  ) -> Bool {
    if record.fields.contains(.title), record.newTitle != draft.title { return false }
    if record.fields.contains(.slug), record.newSlug != draft.slug { return false }
    if record.fields.contains(.summary), record.newSummary != draft.summary { return false }
    if record.fields.contains(.tags), record.newTags != draft.tags { return false }
    return true
  }

  @discardableResult
  public func performAIAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil,
    convergence: AIPublishingActionConvergence? = nil
  ) async -> AIPublishingActionResult? {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      return nil
    }
    let effectiveKind = convergence?.canonicalActionKind ?? kind
    let actionName = convergence?.displayName ?? effectiveKind.displayName
    guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
      aiActionMessage = "找不到要执行 AI 操作的文章。"
      return nil
    }
    let profile = store.profile(for: baseline.draft)
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      let actionOperationID = beginAIActionOperation()
      defer { finishAIActionOperation(actionOperationID) }
      let metadataGeneration = effectiveKind.producesMetadataSuggestion
        ? beginAIMetadataSuggestionOperation(for: draft.id)
        : nil
      defer {
        if let metadataGeneration {
          finishAIMetadataSuggestionOperation(
            for: draft.id,
            generation: metadataGeneration
          )
        }
      }
      let artifacts = await store.aiPublishingRequestArtifacts(for: baseline.draft)
      let knowledgeContext = await store.knowledge.context(
        query: knowledgeQuery(
          draft: artifacts.draft,
          selectedText: selectedText,
          instruction: actionName
        ),
        policy: aiChatKnowledgePolicy
      )
      let request = AIPublishingActionRequest(
        kind: effectiveKind,
        draft: artifacts.draft,
        profile: artifacts.profile,
        convergence: convergence,
        selectedText: selectedText,
        preflightIssues: artifacts.preflightIssues,
        publishPackage: artifacts.publishPackage,
        remoteReviewDraft: artifacts.remoteReviewDraft,
        workflowContext: artifacts.workflowContext,
        knowledgeContext: knowledgeContext
      )
      let assistant = aiPublishingAssistantService
      let requestConfig = store.aiProviderConfig(for: profile)
      let requestTask = Task {
        try await assistant.perform(
          request,
          config: requestConfig,
          apiKey: token
        )
      }
      if let metadataGeneration {
        registerAIMetadataSuggestionCancellationHandler(
          for: draft.id,
          generation: metadataGeneration
        ) {
          requestTask.cancel()
        }
      }
      let requestResult = await withTaskCancellationHandler {
        await requestTask.result
      } onCancel: {
        requestTask.cancel()
      }
      let result: AIPublishingActionResult
      switch requestResult {
      case .success(let value):
        result = value
      case .failure(let error):
        if error is CancellationError
          || Task.isCancelled
          || (metadataGeneration != nil
            && aiMetadataSuggestionGenerationsByDraftID[draft.id] != metadataGeneration)
        {
          return nil
        }
        throw error
      }
      aiActionResult = result
      if let suggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(from: result),
        let metadataGeneration
      {
        guard draftOperationStillMatches(baseline, profile: profile) else {
          aiActionMessage = "文章在 AI 建议生成期间发生变化，元数据建议未安装。"
          return result
        }
        guard installAIMetadataSuggestion(
          suggestion,
          for: draft.id,
          generation: metadataGeneration
        ) else {
          aiActionMessage = "文章的较新 AI 建议已生成，当前结果已丢弃。"
          return result
        }
      }
      aiActionMessage = "\(actionName)完成。"
      return result
    } catch {
      aiActionMessage = "\(actionName)失败：\(error.localizedDescription)"
      return nil
    }
  }

  /// RSS reuses the editor assistant's client, model routing, consent, and
  /// credential path. It is a presentation-specific result, not a second AI
  /// completion service.
  public func translateRSSArticle(
    _ article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) async throws -> RSSArticleTranslationResult {
    guard store.canUseProtectedWorkbench else {
      throw RSSArticleTranslationError.protectedWorkbenchUnavailable
    }

    let profile = store.activeProfile
    let config = store.aiProviderConfig(for: profile)
    let apiKey = try aiChatAvailableAPIKey(for: profile)
    return try await aiPublishingAssistantService.translateRSSArticle(
      article: article,
      target: target,
      config: config,
      apiKey: apiKey
    )
  }

  @discardableResult
  public func performAIAction(
    _ convergence: AIPublishingActionConvergence,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    await performAIAction(
      convergence.canonicalActionKind,
      draft: draft,
      selectedText: selectedText,
      convergence: convergence
    )
  }

  @discardableResult
  public func generateAIMetadataSuggestions(
    draft: ArticleDraft
  ) async -> AIPublishingMetadataSuggestion? {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      return nil
    }
    guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
      aiActionMessage = "找不到要生成 AI 建议的文章。"
      return nil
    }
    let profile = store.profile(for: baseline.draft)
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      let generation = beginAIMetadataSuggestionOperation(for: draft.id)
      defer {
        finishAIMetadataSuggestionOperation(for: draft.id, generation: generation)
      }
      let artifacts = await store.aiPublishingRequestArtifacts(for: baseline.draft)
      let knowledgeContext = await store.knowledge.context(
        query: knowledgeQuery(draft: artifacts.draft, instruction: "标题 摘要 标签 元数据"),
        policy: aiChatKnowledgePolicy
      )
      let request = AIPublishingActionRequest(
        kind: .draftFrontMatterPack,
        draft: artifacts.draft,
        profile: artifacts.profile,
        preflightIssues: artifacts.preflightIssues,
        publishPackage: artifacts.publishPackage,
        remoteReviewDraft: artifacts.remoteReviewDraft,
        workflowContext: artifacts.workflowContext,
        knowledgeContext: knowledgeContext
      )
      let assistant = aiPublishingAssistantService
      let requestConfig = store.aiProviderConfig(for: profile)
      let requestTask = Task {
        try await assistant.suggestMetadata(
          for: request,
          config: requestConfig,
          apiKey: token
        )
      }
      registerAIMetadataSuggestionCancellationHandler(
        for: draft.id,
        generation: generation
      ) {
        requestTask.cancel()
      }
      let requestResult = await withTaskCancellationHandler {
        await requestTask.result
      } onCancel: {
        requestTask.cancel()
      }
      let suggestion: AIPublishingMetadataSuggestion
      switch requestResult {
      case .success(let value):
        suggestion = value
      case .failure(let error):
        if error is CancellationError
          || Task.isCancelled
          || aiMetadataSuggestionGenerationsByDraftID[draft.id] != generation
        {
          return nil
        }
        throw error
      }
      guard draftOperationStillMatches(baseline, profile: profile) else {
        aiActionMessage = "文章在 AI 建议生成期间发生变化，结果已丢弃。"
        return nil
      }
      guard installAIMetadataSuggestion(suggestion, for: draft.id, generation: generation) else {
        aiActionMessage = "文章的较新 AI 建议已生成，当前结果已丢弃。"
        return nil
      }
      aiActionMessage = "AI 元数据建议已生成。"
      return suggestion
    } catch {
      aiActionMessage = "AI 元数据建议生成失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func prepareAIImageTextSuggestions(for draft: ArticleDraft) {
    // A background caller may prepare a non-selected draft, but the legacy
    // workspace fields are strictly the current-selection projection.
    guard store.selectedDraftID == draft.id else { return }
    restoreDraftSuggestionProjectionForCurrentSelection()
  }

  @discardableResult
  public func generateAIImageTextSuggestions(
    draft: ArticleDraft,
    targetAttachmentIDs: Set<UUID>? = nil
  ) async
    -> [AIPublishingImageTextSuggestion]
  {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      store.setImageActionMessage(store.quickHideOperationMessage)
      return []
    }
    guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
      aiActionMessage = "找不到要生成图片文案的文章。"
      store.setImageActionMessage(aiActionMessage)
      return []
    }
    let requestDraft = baseline.draft
    let profile = store.profile(for: requestDraft)
    let report = store.imageWorkbenchReport(for: requestDraft)
    let availableTargets = imageWorkbenchService.imageTextTargets(
      draft: requestDraft, profile: profile, report: report)
    let targets =
      targetAttachmentIDs.map { requestedIDs in
        availableTargets.filter { requestedIDs.contains($0.attachmentID) }
      } ?? availableTargets
    guard !targets.isEmpty else {
      aiActionMessage = "当前文章没有需要补全 alt/caption 的图片。"
      store.setImageActionMessage(aiActionMessage)
      return []
    }
    let retainedSuggestions =
      targetAttachmentIDs.map { requestedIDs in
        aiImageTextSuggestions(for: draft.id).filter {
          !requestedIDs.contains($0.attachmentID)
        }
      } ?? []
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      let generation = beginAIImageTextSuggestionOperation(for: draft.id)
      defer {
        finishAIImageTextSuggestionOperation(for: draft.id, generation: generation)
      }
      let visionCandidates = Array(
        targets
          .prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
          .compactMap { target -> (String, DraftAttachment)? in
            guard
              let attachment = requestDraft.attachments.first(where: {
                $0.id == target.attachmentID && $0.mediaKind == .image
              })
            else {
              return nil
            }
            return (target.id, attachment)
          }
      )
      let visionInputs: [AIPublishingImageTextVisionInput]
      if store.aiProviderConfig(for: profile).supportsImageInput {
        visionInputs = await Task.detached(priority: .userInitiated) {
          visionCandidates.compactMap { candidate in
            let (targetID, attachment) = candidate
            guard let image = AIChatImageAttachmentLoader.load([attachment]).images.first else {
              return nil
            }
            return AIPublishingImageTextVisionInput(
              targetID: targetID,
              attachment: image
            )
          }
        }.value
      } else {
        visionInputs = []
      }
      let assistant = aiPublishingAssistantService
      let requestConfig = store.aiProviderConfig(for: profile)
      let requestTask = Task {
        try await assistant.suggestImageText(
          for: targets,
          visionInputs: visionInputs,
          profile: profile,
          config: requestConfig,
          apiKey: token
        )
      }
      registerAIImageTextSuggestionCancellationHandler(
        for: draft.id,
        generation: generation
      ) {
        requestTask.cancel()
      }
      let requestResult = await withTaskCancellationHandler {
        await requestTask.result
      } onCancel: {
        requestTask.cancel()
      }
      let suggestions: [AIPublishingImageTextSuggestion]
      switch requestResult {
      case .success(let value):
        suggestions = value
      case .failure(let error):
        if error is CancellationError
          || Task.isCancelled
          || aiImageTextSuggestionGenerationsByDraftID[draft.id] != generation
        {
          return []
        }
        throw error
      }
      guard draftOperationStillMatches(baseline, profile: profile) else {
        aiActionMessage = "文章在图片文案生成期间发生变化，结果已丢弃。"
        store.setImageActionMessage(aiActionMessage)
        return []
      }
      guard
        installAIImageTextSuggestions(
          retainedSuggestions + suggestions,
          for: draft.id,
          generation: generation
        )
      else {
        aiActionMessage = "文章的较新图片文案已生成，当前结果已丢弃。"
        store.setImageActionMessage(aiActionMessage)
        return []
      }
      aiActionMessage =
        visionInputs.isEmpty
        ? "已根据文章上下文生成 \(suggestions.count) 条图片文案建议。"
        : "已实际分析 \(visionInputs.count) 张图片，生成 \(suggestions.count) 条图片文案建议。"
      store.setImageActionMessage(aiActionMessage)
      return suggestions
    } catch {
      aiActionMessage = "图片文案生成失败：\(error.localizedDescription)"
      store.setImageActionMessage(aiActionMessage)
      return []
    }
  }

  public func applyAIImageTextSuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    applyAIImageTextSuggestions([suggestion])
  }

  public func applyAIImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    guard let draftID = suggestions.first?.draftID,
      !suggestions.isEmpty,
      suggestions.allSatisfy({ $0.draftID == draftID }),
      let draft = store.drafts.first(where: { $0.id == draftID })
    else {
      aiActionMessage = "找不到要应用图片文案的文章。"
      return
    }
    let result = imageWorkbenchService.applyImageTextSuggestions(suggestions, to: draft)
    store.updateDraft(result.draft)
    removeAIImageTextSuggestions(
      withIDs: Set(suggestions.map(\.id)),
      for: draftID
    )
    aiActionMessage =
      "已应用图片文案：alt \(result.appliedAltTextCount) 条，caption \(result.appliedCaptionCount) 条。"
  }

  public func clearAIImageTextSuggestions() {
    if let draftID = store.selectedDraftID ?? aiImageTextSuggestionDraftID {
      removeAllAIImageTextSuggestions(for: draftID)
    } else {
      workspace.aiImageTextSuggestionDraftID = nil
      workspace.aiImageTextSuggestions = []
      bumpAIDraftSuggestionStateRevision()
    }
    aiActionMessage = "已清空图片文案建议。"
  }

  @discardableResult
  public func sendMaintenanceActionToAI(_ item: MaintenanceActionItem) async
    -> AIPublishingChatMessage?
  {
    guard
      let draft = item.draftID.flatMap({ id in store.drafts.first(where: { $0.id == id }) })
        ?? store.selectedDraft
    else {
      aiChatMessage = "找不到维护行动对应的文章。"
      return nil
    }
    guard openAIChatWorkspace(for: draft.id) else { return nil }
    let prompt = AIPublishingChatPromptTemplateService.maintenanceActionPrompt(
      for: item,
      draft: draft,
      profile: store.profile(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  @discardableResult
  public func sendReleaseRecoveryPackageToAI(for entry: ReleaseLedgerEntry) async
    -> AIPublishingChatMessage?
  {
    guard
      let draft = entry.record.draftID.flatMap({ id in store.drafts.first(where: { $0.id == id }) })
        ?? store.selectedDraft
    else {
      aiChatMessage = "找不到发布恢复记录对应的文章。"
      return nil
    }
    guard openAIChatWorkspace(for: draft.id) else { return nil }
    let prompt = AIPublishingChatPromptTemplateService.releaseRecoveryPrompt(
      for: entry,
      package: entry.recoveryPackage,
      draft: draft,
      profile: store.profile(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  @discardableResult
  public func sendSEOSocialPreviewToAI(for draft: ArticleDraft? = nil) async
    -> AIPublishingChatMessage?
  {
    guard let draft = draft ?? store.selectedDraft else {
      aiChatMessage = "请先选择一篇文章。"
      return nil
    }
    await store.refreshSiteMaintenanceSnapshot()
    prepareSEOSocialPreview(for: draft)
    guard let snapshot = seoSocialPreviewSnapshot(for: draft),
      openAIChatWorkspace(for: draft.id)
    else {
      return nil
    }
    let prompt = AIPublishingChatPromptTemplateService.seoSocialPreviewPrompt(
      snapshot: snapshot,
      draft: draft,
      profile: store.profile(for: draft),
      relatedSuggestions: store.relatedArticleSuggestions(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  public func aiChatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> [AIChatImageAttachment] {
    let selectedAttachments = Array(
      draft.attachments
        .filter { attachmentIDs.contains($0.id) && $0.mediaKind == .image }
        .prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    let result = await Task.detached(priority: .userInitiated) {
      AIChatImageAttachmentLoader.load(selectedAttachments)
    }.value
    guard !Task.isCancelled else { return [] }
    if result.skippedCount > 0 {
      aiChatMessage =
        "已跳过 \(result.skippedCount) 个无法读取、格式不支持或超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()) 的图片附件。"
    }
    return result.images
  }

}
