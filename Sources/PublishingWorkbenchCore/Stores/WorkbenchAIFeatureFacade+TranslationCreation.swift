import Foundation
import PublishingCoreSupport

extension WorkbenchAIFeatureFacade {
  /// A local-only path preview; creating or dismissing it never edits a draft.
  public func translationCreationPreview(
    source: ArticleDraft,
    target: AIPublishingChatTranslationTarget
  ) throws -> AITranslationDraftPlan {
    try AITranslationDraftPlanningService.plan(
      source: source, profile: store.profile(for: source),
      targetLanguageCode: target.languageCode,
      translatedTitle: source.title.trimmedForPublishing.nilIfEmpty ?? CoreL10n.text("译文"),
      translatedSummary: source.summary, translatedBodyMarkdown: source.bodyMarkdown
    )
  }

  public func translationCreationIssue(
    for plan: AITranslationDraftPlan
  ) -> String? {
    guard let source = store.drafts.first(where: { $0.id == plan.sourceDraftID }) else {
      return CoreL10n.text("找不到翻译计划对应的原稿。")
    }
    do {
      _ = try AITranslationDraftPlanningService.materializeCreation(
        plan, currentSource: source, profile: store.profile(for: source),
        existingDrafts: store.drafts
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  @discardableResult
  public func generateTranslationDraftPlan(
    sourceDraftID: UUID,
    target: AIPublishingChatTranslationTarget,
    ownerToken: UUID
  ) async -> AITranslationDraftPlan? {
    guard !isChatRunning,
      let command = AIPublishingChatTranslationDraftService.creationRequest(target: target)
    else {
      store.setAIChatMessage(CoreL10n.text("请等待当前 AI 请求结束后再生成译文。"))
      return nil
    }
    store.flushDraftBodyEditorBuffer(for: sourceDraftID)
    guard let source = store.drafts.first(where: { $0.id == sourceDraftID }) else { return nil }
    do {
      let preview = try translationCreationPreview(source: source, target: target)
      if let issue = translationCreationIssue(for: preview) {
        store.setAIChatMessage(issue)
        return nil
      }
    } catch {
      store.setAIChatMessage(error.localizedDescription)
      return nil
    }
    prepareChat(for: source)
    setChatContextMode(.site)
    let reply = await sendChatMessage(
      command, draft: source, ownerToken: ownerToken, expectedContextMode: .site
    )
    guard !Task.isCancelled else { return nil }
    return reply?.translationDraftPlan
  }

  @discardableResult
  public func createLinkedTranslationDraft(
    from plan: AITranslationDraftPlan
  ) -> ArticleDraft? {
    store.flushDraftBodyEditorBuffers()
    guard let source = store.drafts.first(where: { $0.id == plan.sourceDraftID }) else {
      store.setAIChatMessage(CoreL10n.text("找不到翻译计划对应的原稿。"))
      return nil
    }
    if let existing = store.drafts.first(where: { $0.id == plan.translatedDraft.id }) {
      guard let existingLink = existing.translationLink,
        existingLink.sourceDraftID == plan.sourceDraftID,
        existingLink.translatedDraftID == plan.translatedDraft.id,
        existingLink.targetLanguageCode == plan.targetLanguageCode
      else {
        store.setAIChatMessage(
          AITranslationDraftPlanningError.invalidTranslationLink.localizedDescription)
        return nil
      }
      store.selectDraft(existing.id)
      store.setAIChatMessage(CoreL10n.text("这份关联翻译草稿已经创建，已为你打开。"))
      return existing
    }

    do {
      let creation = try AITranslationDraftPlanningService.materializeCreation(
        plan, currentSource: source, profile: store.profile(for: source),
        existingDrafts: store.drafts
      )
      guard !store.persistenceStore.isRecoveryWriteProtected else {
        store.setAIChatMessage(CoreL10n.text("工作台处于恢复保护中，译文未创建。"))
        return nil
      }
      // Save a frozen proposed workspace before publishing either value into
      // memory. A failed primary save therefore leaves drafts, versions,
      // selection and project-file write queues exactly as they were.
      var snapshot = store.persistenceStore.persistence.snapshot(from: store)
      var updatedSource = creation.updatedSource
      if var updated = updatedSource {
        updated.markUpdated(replacing: source)
        updatedSource = updated
        snapshot.drafts = snapshot.drafts.map { $0.id == source.id ? updated : $0 }
        snapshot.draftVersions = DraftLifecycleService().recordingVersion(
          of: source, reason: .beforeBatchProcessing, in: snapshot.draftVersions)
      }
      let translated = creation.translatedDraft
      snapshot.drafts.insert(translated, at: 0)
      store.persistenceStore.markUnsavedChanges()
      _ = store.persistenceStore.flush(snapshot: snapshot)
      guard !store.persistenceStore.isRecoveryWriteProtected,
        !store.persistenceStore.hasUnsavedChanges
      else {
        store.setAIChatMessage(CoreL10n.text("工作台保存失败，译文未创建，原稿保持原样。"))
        return nil
      }
      store.publishingStore.drafts = snapshot.drafts
      store.publishingStore.draftVersions = snapshot.draftVersions
      store.synchronizeDraftBodyEditorBuffer(with: translated)
      store.scheduleDraftWordCountRefresh(
        for: translated.id, bodyMarkdown: translated.bodyMarkdown)
      if let updatedSource {
        store.scheduleSiteDraftFileAutosave(for: updatedSource)
      }
      store.invalidateDraftDerivedCaches()
      store.selectDraft(translated.id)
      store.setAIChatMessage(CoreL10n.text("已创建关联翻译草稿；原稿文字保持不变。"))
      return translated
    } catch {
      store.setAIChatMessage(CoreL10n.format("关联翻译草稿未创建：%@", error.localizedDescription))
      return nil
    }
  }
}
