import Foundation
import PublishingDomainContracts
import PublishingKnowledgeCore

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
    guard
      let currentDraft = currentDraftForAIMetadataApplication(
        suggestion,
        requestedDraft: draft
      )
    else {
      return nil
    }
    var updated = currentDraft
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
    consumeAIMetadataSuggestion(suggestion, for: updated)
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
    guard !Task.isCancelled else { return nil }
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      return nil
    }
    let effectiveKind = convergence?.canonicalActionKind ?? kind
    let actionName = convergence?.displayName ?? effectiveKind.displayName
    let lane: AIGenerationLane =
      effectiveKind.producesMetadataSuggestion
      ? .metadata(draft.id) : .action
    let generation = beginPublishingAIRequest(lane)
    let knowledgePolicy = aiChatKnowledgePolicy
    defer { finishAIRequest(lane, generation: generation) }
    do {
      let result = try await awaitAIRequest(lane, generation: generation) {
        [self]
        () async throws -> AIPublishingActionResult? in
        guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
          if canPresentAIRequest(lane, generation: generation) {
            aiActionMessage = "找不到要执行 AI 操作的文章。"
          }
          return nil
        }
        try checkAIRequest(lane, generation: generation)
        let profile = store.profile(for: baseline.draft)
        bindAIRequest(lane, baseline: baseline, profile: profile)
        let token = try aiChatAvailableAPIKey(for: profile)
        let artifacts = await store.aiPublishingRequestArtifacts(for: baseline.draft)
        try checkAIRequest(lane, generation: generation)
        let knowledgeContext = await store.knowledgeContext(
          query: knowledgeQuery(
            draft: artifacts.draft,
            selectedText: selectedText,
            instruction: actionName
          ),
          policy: knowledgePolicy
        )
        try await checkPublishingKnowledgeAuthorization(
          knowledgeContext, policy: knowledgePolicy, lane: lane, generation: generation
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
        let assistant = aiPublishingAssistantService.authorizingNonStreamingRequests {
          @MainActor [weak self] in
          guard let self else { throw CancellationError() }
          try await self.checkPublishingKnowledgeAuthorization(
            knowledgeContext, policy: knowledgePolicy, lane: lane, generation: generation
          )
        }
        let requestConfig = store.aiProviderConfig(for: profile)
        return try await assistant.perform(
          request,
          config: requestConfig,
          apiKey: token
        )
      }
      guard let result else { return nil }
      if let suggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(from: result),
        effectiveKind.producesMetadataSuggestion
      {
        guard
          installAIMetadataSuggestion(
            suggestion,
            for: draft.id,
            generation: generation
          )
        else {
          return nil
        }
      }
      if canPresentAIRequest(lane, generation: generation) {
        aiActionResult = result
        aiActionMessage = CoreL10n.text("AI 操作已完成。")
      }
      return result
    } catch {
      if !(error is CancellationError), canPresentAIRequest(lane, generation: generation) {
        store.setAIActionFailureMessage(
          CoreL10n.format("AI 操作失败：%@", error.localizedDescription)
        )
      }
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

  public func translateRSSTitles(
    _ titles: [RSSArticleTranslationTextRequest],
    target: RSSArticleTranslationTarget
  ) async throws -> [String: String] {
    guard store.canUseProtectedWorkbench else {
      throw RSSArticleTranslationError.protectedWorkbenchUnavailable
    }
    let profile = store.activeProfile
    let config = store.aiProviderConfig(for: profile)
    let apiKey = try aiChatAvailableAPIKey(for: profile)
    return try await aiPublishingAssistantService.translateRSSTitles(
      titles,
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
    guard !Task.isCancelled else { return nil }
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      return nil
    }
    let lane = AIGenerationLane.metadata(draft.id)
    let generation = beginAIRequest(lane)
    let knowledgePolicy = aiChatKnowledgePolicy
    defer { finishAIRequest(lane, generation: generation) }
    do {
      let suggestion = try await awaitAIRequest(lane, generation: generation) {
        [self]
        () async throws -> AIPublishingMetadataSuggestion? in
        guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
          if canPresentAIRequest(lane, generation: generation) {
            aiActionMessage = "找不到要生成 AI 建议的文章。"
          }
          return nil
        }
        try checkAIRequest(lane, generation: generation)
        let profile = store.profile(for: baseline.draft)
        bindAIRequest(lane, baseline: baseline, profile: profile)
        let token = try aiChatAvailableAPIKey(for: profile)
        let artifacts = await store.aiPublishingRequestArtifacts(for: baseline.draft)
        try checkAIRequest(lane, generation: generation)
        let knowledgeContext = await store.knowledgeContext(
          query: knowledgeQuery(draft: artifacts.draft, instruction: "标题 摘要 标签 元数据"),
          policy: knowledgePolicy
        )
        try await checkPublishingKnowledgeAuthorization(
          knowledgeContext, policy: knowledgePolicy, lane: lane, generation: generation
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
        let assistant = aiPublishingAssistantService.authorizingNonStreamingRequests {
          @MainActor [weak self] in
          guard let self else { throw CancellationError() }
          try await self.checkPublishingKnowledgeAuthorization(
            knowledgeContext, policy: knowledgePolicy, lane: lane, generation: generation
          )
        }
        return try await assistant.suggestMetadata(
          for: request,
          config: store.aiProviderConfig(for: profile),
          apiKey: token
        )
      }
      guard let suggestion,
        installAIMetadataSuggestion(suggestion, for: draft.id, generation: generation)
      else { return nil }
      if canPresentAIRequest(lane, generation: generation) {
        aiActionMessage = "AI 元数据建议已生成。"
      }
      return suggestion
    } catch {
      if !(error is CancellationError), canPresentAIRequest(lane, generation: generation) {
        store.setAIActionFailureMessage(
          CoreL10n.format("AI 元数据建议生成失败：%@", error.localizedDescription)
        )
      }
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
  public func generateAIImageTextSuggestions(draft: ArticleDraft) async
    -> [AIPublishingImageTextSuggestion]
  {
    guard !Task.isCancelled else { return [] }
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.quickHideOperationMessage
      store.setImageActionMessage(store.quickHideOperationMessage)
      return []
    }
    let lane = AIGenerationLane.imageText(draft.id)
    let generation = beginAIRequest(lane)
    defer { finishAIRequest(lane, generation: generation) }
    do {
      let result = try await awaitAIRequest(lane, generation: generation) {
        [self]
        () async throws -> ([AIPublishingImageTextSuggestion], Int)? in
        guard let baseline = await prepareDraftOperationBaseline(for: draft.id) else {
          if canPresentAIRequest(lane, generation: generation) {
            aiActionMessage = "找不到要生成图片文案的文章。"
            store.setImageActionMessage(aiActionMessage)
          }
          return nil
        }
        try checkAIRequest(lane, generation: generation)
        let requestDraft = baseline.draft
        let profile = store.profile(for: requestDraft)
        bindAIRequest(lane, baseline: baseline, profile: profile)
        let report = store.imageWorkbenchReport(for: requestDraft)
        let targets = imageWorkbenchService.imageTextTargets(
          draft: requestDraft, profile: profile, report: report)
        guard !targets.isEmpty else {
          if canPresentAIRequest(lane, generation: generation) {
            aiActionMessage = "当前文章没有需要补全 alt/caption 的图片。"
            store.setImageActionMessage(aiActionMessage)
          }
          return nil
        }
        let token = try aiChatAvailableAPIKey(for: profile)
        let requestConfig = store.aiProviderConfig(for: profile)
        let visionCandidates = Array(
          targets
            .prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
            .compactMap { target -> (String, DraftAttachment)? in
              guard
                let attachment = requestDraft.attachments.first(where: {
                  $0.id == target.attachmentID && $0.mediaKind == .image
                })
              else { return nil }
              return (target.id, attachment)
            }
        )
        let visionInputs: [AIPublishingImageTextVisionInput]
        if requestConfig.supportsImageInput {
          let loader = Task.detached(priority: .userInitiated) {
            try visionCandidates.compactMap { candidate -> AIPublishingImageTextVisionInput? in
              try Task.checkCancellation()
              let (targetID, attachment) = candidate
              guard let image = AIChatImageAttachmentLoader.load([attachment]).images.first else {
                return nil
              }
              return AIPublishingImageTextVisionInput(targetID: targetID, attachment: image)
            }
          }
          visionInputs = try await withTaskCancellationHandler {
            try await loader.value
          } onCancel: {
            loader.cancel()
          }
        } else {
          visionInputs = []
        }
        try checkAIRequest(lane, generation: generation)
        let suggestions = try await aiPublishingAssistantService.suggestImageText(
          for: targets,
          visionInputs: visionInputs,
          profile: profile,
          config: requestConfig,
          apiKey: token
        )
        return (suggestions, visionInputs.count)
      }
      guard let (suggestions, visionCount) = result,
        installAIImageTextSuggestions(suggestions, for: draft.id, generation: generation)
      else { return [] }
      if canPresentAIRequest(lane, generation: generation) {
        aiActionMessage =
          visionCount == 0
          ? "已根据文章上下文生成 \(suggestions.count) 条图片文案建议。"
          : "已实际分析 \(visionCount) 张图片，生成 \(suggestions.count) 条图片文案建议。"
        store.setImageActionMessage(aiActionMessage)
      }
      return suggestions
    } catch {
      if !(error is CancellationError), canPresentAIRequest(lane, generation: generation) {
        store.setAIActionFailureMessage(
          CoreL10n.format("图片文案生成失败：%@", error.localizedDescription)
        )
        store.setImageActionMessage(aiActionMessage)
      }
      return []
    }
  }

  public func applyAIImageTextSuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    applyAIImageTextSuggestions([suggestion])
  }

  public func applyAIImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    guard let draftID = suggestions.first?.draftID,
      !suggestions.isEmpty,
      suggestions.allSatisfy({ $0.draftID == draftID })
    else {
      aiActionMessage = "找不到要应用图片文案的文章。"
      return
    }
    guard let draft = currentDraftForAIImageTextApplication(suggestions, draftID: draftID) else {
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

  public func aiChatImageAttachmentLoadResult(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> AIChatImageAttachmentLoadResult {
    let resolvedAttachments = draft.attachments.filter { attachmentIDs.contains($0.id) }
    let resolvedAttachmentIDs = Set(resolvedAttachments.map(\.id))
    let missingAttachmentIDs = attachmentIDs.subtracting(resolvedAttachmentIDs)
      .sorted { $0.uuidString < $1.uuidString }
    let attachmentLimit = AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount
    let attachmentsWithinLimit = Array(resolvedAttachments.prefix(attachmentLimit))
    let overflowAttachments = resolvedAttachments.dropFirst(attachmentLimit)
    let nonImageAttachments = attachmentsWithinLimit.filter { $0.mediaKind != .image }
    let imageAttachments = attachmentsWithinLimit.filter { $0.mediaKind == .image }
    let removedAttachmentName = CoreL10n.text("已移除的图片")

    let result = await Task.detached(priority: .userInitiated) {
      AIChatImageAttachmentLoader.loadResult(imageAttachments)
    }.value
    guard !Task.isCancelled else {
      return AIChatImageAttachmentLoadResult(images: [], failures: [])
    }

    let nonImageFailures = nonImageAttachments.map { attachment in
      AIChatImageAttachmentLoadFailure(
        attachmentID: attachment.id,
        filename: attachment.originalFilename,
        reason: .notImage
      )
    }
    let overflowFailures = overflowAttachments.map { attachment in
      AIChatImageAttachmentLoadFailure(
        attachmentID: attachment.id,
        filename: attachment.originalFilename,
        reason: .exceedsSelectionLimit
      )
    }
    let missingFailures = missingAttachmentIDs.map { attachmentID in
      AIChatImageAttachmentLoadFailure(
        attachmentID: attachmentID,
        filename: removedAttachmentName,
        reason: .removedFromArticle
      )
    }
    return AIChatImageAttachmentLoadResult(
      images: result.images,
      failures: result.failures + nonImageFailures + overflowFailures + missingFailures
    )
  }

  /// Compatibility API for optional vision callers. Interactive chat uses the
  /// detailed result above so it can stop before sending a partial selection.
  public func aiChatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> [AIChatImageAttachment] {
    let result = await aiChatImageAttachmentLoadResult(
      for: draft,
      attachmentIDs: attachmentIDs
    )
    if result.skippedCount > 0 {
      aiChatMessage =
        "已跳过 \(result.skippedCount) 个无法读取、格式不支持或超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()) 的图片附件。"
    }
    return result.images
  }

}
