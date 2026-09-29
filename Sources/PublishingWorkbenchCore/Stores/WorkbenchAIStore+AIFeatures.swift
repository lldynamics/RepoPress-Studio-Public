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

  @discardableResult
  public func performAIAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil,
    convergence: AIPublishingActionConvergence? = nil
  ) async -> AIPublishingActionResult? {
    guard !Task.isCancelled else { return nil }
    let effectiveKind = convergence?.canonicalActionKind ?? kind
    let actionName = convergence?.displayName ?? effectiveKind.displayName
    let lane: AIGenerationLane =
      effectiveKind.producesMetadataSuggestion
      ? .metadata(draft.id) : .action
    let generation = beginPublishingAIRequest(lane)
    let authorization = bindNonStreamingAuthorization(
      lane, profile: store.profile(for: store.draft(for: draft.id) ?? draft)
    )
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
        try checkNonStreamingAuthorization(
          authorization, apiKey: token, lane: lane, generation: generation
        )
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
          try self.checkNonStreamingAuthorization(
            authorization, apiKey: token, lane: lane, generation: generation
          )
        }
        return try await assistant.perform(
          request,
          config: authorization.config,
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
}
