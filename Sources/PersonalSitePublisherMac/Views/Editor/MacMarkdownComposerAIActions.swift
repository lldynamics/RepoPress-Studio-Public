import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  var markdownComposerAIAvailabilitySnapshot: MarkdownComposerAIAvailabilitySnapshot {
    MarkdownComposerAIAvailabilitySnapshot(
      draft: draft,
      bodyMarkdown: editorBody,
      selectedText: selectedText(in: editorBody),
      isAIEnabled: isAIEnabledForDraft,
      activeAction: activeSelectionAIAction,
      isAIActionRunning: editorState.isAIActionRunning
    )
  }

  var canShowSelectionActions: Bool {
    SelectionActionBarPresentation.shouldShow(
      hasSelectedText: hasSelectedText,
      isSelectionAIActionRunning: isSelectionAIActionRunning,
      selectionActionMessage: selectionActionMessage
    )
  }

  var hasSelectedText: Bool {
    !isFrontMatterSelection
      && !selectedText(in: editorBody).trimmedForPublishing.isEmpty
  }

  var latestAssistantMessageForCurrentDraft: AIPublishingChatMessage? {
    editorState.latestAssistantMessage(for: draft.id)
  }

  var isSelectionAIActionRunning: Bool {
    activeSelectionAIAction != nil || editorState.isAIActionRunning
  }

  var isAIEnabledForDraft: Bool {
    let profile = editorState.profile(for: draft)
    let config = store.aiProviderConfig(for: profile)
    return !config.requiresAPIKey || editorState.aiTokenAvailability.hasToken
  }

  func articleAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      draft: previewDraft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  func selectionAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      selectedText: selectedText(in: editorBody),
      draft: previewDraft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  func activeAIActionForAvailability(fallback kind: AIPublishingActionKind) -> AIPublishingActionKind? {
    activeSelectionAIAction ?? (editorState.isAIActionRunning ? kind : nil)
  }

  func isSelectionAIAction(_ kind: AIPublishingActionKind) -> Bool {
    kind.contextRequirement == .selectedText
  }

  func pasteAIPromptToClipboard() {
    cancelAIPromptClipboardTask()
    let requestedDraft = previewDraft
    let requestedBody = requestedDraft.bodyMarkdown
    let requestID = UUID()
    aiPromptClipboardRequestID = requestID
    store.setPublishActionMessage(
      String(localized: "正在生成 AI Prompt…"),
      status: .inProgress
    )
    aiPromptClipboardTask = Task { @MainActor in
      let prompt = await store.publishingAIPromptInBackground(for: requestedDraft)
      guard !Task.isCancelled,
            aiPromptClipboardRequestID == requestID else {
        return
      }
      aiPromptClipboardTask = nil
      aiPromptClipboardRequestID = nil
      guard draft.id == requestedDraft.id,
            editorBody == requestedBody else {
        store.setPublishActionMessage(
          String(localized: "文章已变化，未复制陈旧 AI Prompt；请重试。"),
          status: .warning
        )
        return
      }
      ClipboardWriter.copy(
        prompt,
        successMessage: String(localized: "已复制 AI Prompt。")
      ) { message, status in
        store.setPublishActionMessage(message, status: status)
      }
    }
  }

  func cancelAIPromptClipboardTask() {
    aiPromptClipboardTask?.cancel()
    aiPromptClipboardTask = nil
    aiPromptClipboardRequestID = nil
  }

  func runPreflightForCurrentDraft() {
    store.runPreflight()
    let issues = editorState.preflightIssues(for: previewDraft)
    EditorAccessibilityAnnouncementCenter.announceDiagnostics(issues)
    _ = store.focusDraft(draft.id, section: .contentHealth)
  }

  func rewriteSelectedText() {
    performSelectionAIAction(.rewriteSelection)
  }

  func performSelectionAIAction(_ kind: AIPublishingActionKind) {
    performSelectionAIAction(kind, convergence: nil, presentsInlineResult: false)
  }

  func performConvergedSelectionAIAction(_ convergence: AIPublishingActionConvergence) {
    performSelectionAIAction(
      convergence.canonicalActionKind,
      convergence: convergence,
      presentsInlineResult: false
    )
  }

  func performSelectionAIAction(
    _ kind: AIPublishingActionKind,
    convergence: AIPublishingActionConvergence? = nil,
    presentsInlineResult: Bool = false
  ) {
    let rawSelectedText = selectedText(in: editorBody)
    let promptSelectedText = rawSelectedText.trimmedForPublishing
    let availability = selectionAIActionAvailability(kind)
    guard availability.isEnabled else {
      selectionActionMessage =
        "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多上下文")"
      return
    }

    cancelInlineGhostText()
    let requestedDraft = previewDraft
    let requestedProfileID = editorState.profile(for: requestedDraft).id
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    isInlineSelectionAIAction = presentsInlineResult
    let actionName = convergence?.localizedDisplayName ?? kind.localizedDisplayName
    selectionActionMessage = "\(actionName)处理中…"
    if !presentsInlineResult {
      showWritingContextPanel(.selectionTools)
    }
    let previewRange = clamped(selectedRange, length: (editorBody as NSString).length)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      defer {
        if selectionAIActionRequestID == requestID {
          if selectionActionMessage == actionName + "处理中…" { selectionActionMessage = "" }
          finishSelectionAIAction(requestID: requestID)
        }
      }
      guard !Task.isCancelled,
        selectionAIActionRequestID == requestID,
        draft.id == requestedDraft.id,
        editorState.profile(for: draft).id == requestedProfileID
      else { return }
      let result: AIPublishingActionResult?
      if let convergence {
        result = await aiActions.performAction(
          convergence,
          draft: requestedDraft,
          selectedText: promptSelectedText
        )
      } else {
        result = await aiActions.performAction(
          kind,
          draft: requestedDraft,
          selectedText: promptSelectedText
        )
      }
      guard selectionAIActionRequestID == requestID else { return }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        let citationPlan = KnowledgeCitationMarkdownService.applicationPlan(
          for: result.content,
          candidates: result.knowledgeCitations,
          existingMarkdown: requestedDraft.bodyMarkdown
        )
        let preview = AIPublishingSelectionEditPreview(
          draftID: requestedDraft.id,
          sourceBodyMarkdown: requestedDraft.bodyMarkdown,
          kind: result.kind,
          range: previewRange,
          originalText: rawSelectedText,
          replacementText: citationPlan.renderedContent,
          application: selectionEditApplication(for: result.kind),
          providerName: result.providerName,
          model: result.model,
          knowledgeCitations: citationPlan.referencedCitations
        )
        selectionEditPreview = preview
        if !presentsInlineResult {
          showWritingContextPanel(.aiReview)
        }
        selectionActionMessage = actionName + "预览已生成。"
        EditorAccessibilityAnnouncementCenter.announceAIPreview(
          kind: result.kind.localizedDisplayName,
          characterCount: (preview.trimmedReplacementText as NSString).length
        )
      } else {
        if selectionActionMessage == "\(actionName)处理中…" {
          selectionActionMessage = ""
        }
      }
    }
  }

  func performArticleAIAction(_ kind: AIPublishingActionKind) {
    performArticleAIAction(kind, convergence: nil)
  }

  func performConvergedArticleAIAction(_ convergence: AIPublishingActionConvergence) {
    performArticleAIAction(convergence.canonicalActionKind, convergence: convergence)
  }

  func performArticleAIAction(
    _ kind: AIPublishingActionKind,
    convergence: AIPublishingActionConvergence?
  ) {
    let availability = articleAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage =
        "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多文章内容")"
      return
    }

    cancelInlineGhostText()
    cancelSelectionAIAction()
    let requestedDraft = previewDraft
    let requestedProfileID = editorState.profile(for: requestedDraft).id
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    let actionName = convergence?.localizedDisplayName ?? kind.localizedDisplayName
    selectionActionMessage = "\(actionName)处理中…"
    let previewRange = articleInsertionRange(for: kind)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      defer {
        if selectionAIActionRequestID == requestID {
          if selectionActionMessage == actionName + "处理中…" { selectionActionMessage = "" }
          finishSelectionAIAction(requestID: requestID)
        }
      }
      guard !Task.isCancelled,
        selectionAIActionRequestID == requestID,
        draft.id == requestedDraft.id,
        editorState.profile(for: draft).id == requestedProfileID
      else { return }
      let result: AIPublishingActionResult?
      if let convergence {
        result = await aiActions.performAction(convergence, draft: requestedDraft)
      } else {
        result = await aiActions.performAction(kind, draft: requestedDraft)
      }
      guard selectionAIActionRequestID == requestID else { return }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        if result.kind.producesMetadataSuggestion, editorState.aiMetadataSuggestion != nil {
          selectionActionMessage = actionName + "已生成，可在元数据建议中应用。"
          EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
        } else {
          let citationPlan = KnowledgeCitationMarkdownService.applicationPlan(
            for: result.content,
            candidates: result.knowledgeCitations,
            existingMarkdown: requestedDraft.bodyMarkdown
          )
          let preview = AIPublishingSelectionEditPreview(
            draftID: requestedDraft.id,
            sourceBodyMarkdown: requestedDraft.bodyMarkdown,
            kind: result.kind,
            range: previewRange,
            originalText: "",
            replacementText: citationPlan.renderedContent,
            application: .insertAtRange,
            providerName: result.providerName,
            model: result.model,
            knowledgeCitations: citationPlan.referencedCitations
          )
          selectionEditPreview = preview
          showWritingContextPanel(.aiReview)
          selectionActionMessage = actionName + "预览已生成。"
          EditorAccessibilityAnnouncementCenter.announceAIPreview(
            kind: result.kind.localizedDisplayName,
            characterCount: (preview.trimmedReplacementText as NSString).length
          )
        }
      } else {
        if selectionActionMessage == "\(actionName)处理中…" {
          selectionActionMessage = ""
        }
      }
    }
  }

  func cancelSelectionAIAction() {
    let ownsProcessingMessage =
      activeSelectionAIAction != nil
      && selectionActionMessage.hasSuffix("处理中…")
    selectionAIActionTask?.cancel()
    selectionAIActionTask = nil
    selectionAIActionRequestID = nil
    activeSelectionAIAction = nil
    isInlineSelectionAIAction = false
    selectionEditPreview = nil
    if activeWritingContextPanel == .aiReview {
      activeWritingContextPanel = hasSelectedText ? .selectionTools : nil
    }
    if ownsProcessingMessage {
      selectionActionMessage = ""
    }
  }

  func finishSelectionAIAction(requestID: UUID) {
    guard selectionAIActionRequestID == requestID else { return }
    selectionAIActionTask = nil
    selectionAIActionRequestID = nil
    activeSelectionAIAction = nil
  }

  func articleInsertionRange(for kind: AIPublishingActionKind) -> NSRange {
    let bodyLength = (editorBody as NSString).length
    switch kind {
    case .continueArticle, .draftArticleFAQ, .draftTroubleshootingSection, .draftReferencesSection:
      return NSRange(location: bodyLength, length: 0)
    case .draftOpening, .draftArticleTLDR:
      return NSRange(location: 0, length: 0)
    default:
      let location = min(max(selectedRange.location, 0), bodyLength)
      return NSRange(location: location, length: 0)
    }
  }

  func selectionEditApplication(for kind: AIPublishingActionKind) -> AIPublishingSelectionEditApplication {
    switch kind {
    case .continueAfterSelection, .explainSelection:
      return .insertAfterRange
    default:
      return .replaceRange
    }
  }

  func checkSelectedPublicRisk() {
    let selectedText = selectedText(in: editorBody).trimmedForPublishing
    guard !selectedText.isEmpty else {
      return
    }

    var probeDraft = previewDraft
    probeDraft.bodyMarkdown = selectedText
    let summary = PublicRiskSummary(issues: PublicRiskScanner().scan(draft: probeDraft))
    let content: String
    if summary.isClear {
      content = "选中文本未命中密钥、私钥、内网地址或本机路径规则。"
      selectionActionMessage = "选区未发现公开风险。"
    } else {
      let issueLines = summary.issues.map {
        "- \($0.severity.localizedDisplayName)：\($0.title) - \($0.message)"
      }
      content = "选中文本公开风险：\n\(issueLines.joined(separator: "\n"))"
      selectionActionMessage = "选区有 \(summary.issueCount) 项公开风险。"
    }
    aiActions.setActionResult(AIPublishingActionResult(kind: .privacyReview, content: content))
    aiActions.setActionMessage(selectionActionMessage)
  }

  func applyLatestAIReplyToSelection() {
    guard let message = latestAssistantMessageForCurrentDraft else {
      selectionActionMessage = "当前文章还没有可应用的 AI 回复。"
      return
    }

    let range = clamped(selectedRange, length: (editorBody as NSString).length)
    guard range.length > 0 else {
      selectionActionMessage = "请先选择要替换的正文。"
      return
    }

    let citationPlan = KnowledgeCitationMarkdownService.applicationPlan(
      for: message.content,
      candidates: message.knowledgeCitations,
      existingMarkdown: previewDraft.bodyMarkdown
    )
    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
        citationPlan.renderedContent,
        to: previewDraft,
      mode: .replaceSelection,
      selectionRange: range
    ) else {
      selectionActionMessage = "AI 回复为空或选区无效。"
      return
    }

    let replacementLength = (citationPlan.renderedContent as NSString).length
    var citedDraft = result.draft
    citedDraft.bodyMarkdown = KnowledgeCitationMarkdownService.appendingMissingDefinitions(
      to: citedDraft.bodyMarkdown,
      citations: citationPlan.referencedCitations
    )
    guard requestUndoableBodyUpdate(citedDraft, selectionOverride: range) else { return }
    selectedRange = NSRange(location: range.location + replacementLength, length: 0)
    recordKnowledgeCitations(
      citationPlan.referencedCitations,
      for: citedDraft
    )
    selectionActionMessage = result.action.statusMessage
  }

  func showAIContextInspector() {
    if let aiChatWorkspaceCommandAction {
      aiChatWorkspaceCommandAction.open(draft.id, nil)
    } else {
      aiActions.openChatWorkspace(for: draft.id)
    }
  }

  func performTemplateLibraryAction(_ kind: AIPublishingActionKind) {
    if isSelectionAIAction(kind) {
      performSelectionAIAction(kind)
    } else {
      performArticleAIAction(kind)
    }
  }

  func openTemplateLibraryPrompt(_ prompt: AIPublishingQuickPrompt) {
    if let aiChatWorkspaceCommandAction {
      aiChatWorkspaceCommandAction.open(draft.id, prompt)
    } else {
      aiActions.openChatWorkspace(for: draft.id, quickPrompt: prompt)
    }
  }

  func applySelectionEditPreview(_ preview: AIPublishingSelectionEditPreview) {
    do {
      let originalLength = (editorBody as NSString).length
      let applied = try AIPublishingSelectionEditPreviewService.apply(preview, to: previewDraft)
      let appliedLength = (applied.bodyMarkdown as NSString).length
      var updated = applied
      updated.bodyMarkdown = KnowledgeCitationMarkdownService.appendingMissingDefinitions(
        to: updated.bodyMarkdown,
        citations: preview.knowledgeCitations
      )
      let insertedLength = max(0, appliedLength - originalLength)
      let newSelectionLocation: Int
      switch preview.application {
      case .replaceRange:
        newSelectionLocation = preview.range.location + (preview.trimmedReplacementText as NSString).length
      case .insertAfterRange:
        newSelectionLocation = preview.range.location + preview.range.length + insertedLength
      case .insertAtRange:
        newSelectionLocation = preview.range.location + insertedLength
      }
      guard requestUndoableBodyUpdate(updated, selectionOverride: preview.range) else { return }
      selectedRange = NSRange(location: newSelectionLocation, length: 0)
      recordKnowledgeCitations(
        preview.knowledgeCitations,
        for: updated
      )
      selectionEditPreview = nil
      isInlineSelectionAIAction = false
      activeWritingContextPanel = hasSelectedText ? .selectionTools : nil
      selectionActionMessage = "\(preview.kind.localizedDisplayName)已应用。"
    } catch {
      selectionActionMessage = error.localizedDescription
    }
  }

  func discardSelectionEditPreview() {
    selectionEditPreview = nil
    isInlineSelectionAIAction = false
    activeWritingContextPanel = hasSelectedText ? .selectionTools : nil
    selectionActionMessage = "已丢弃 AI 预览。"
  }

  private func recordKnowledgeCitations(
    _ citations: [KnowledgeCitation],
    for draft: ArticleDraft
  ) {
    guard !citations.isEmpty else { return }
    let retry = MarkdownComposerCitationBacklinkRetry(
      draftID: draft.id,
      citations: citations,
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: draft.id.uuidString,
        title: draft.title.nilIfEmpty ?? "当前文章",
        location: String(localized: "正文")
      )
    )
    recordKnowledgeCitationBacklinks(retry)
  }

  func retryPendingKnowledgeCitationBacklinks() {
    guard let retry = selectionActionState.pendingCitationBacklinkRetry,
      retry.draftID == draft.id
    else {
      return
    }
    selectionActionMessage = String(localized: "正在重试保存本篇文章的资料引用…")
    recordKnowledgeCitationBacklinks(retry)
  }

  private func recordKnowledgeCitationBacklinks(
    _ retry: MarkdownComposerCitationBacklinkRetry
  ) {
    Task { @MainActor in
      let result = await store.knowledge.recordBacklinks(
        citations: retry.citations,
        target: retry.target
      )
      guard draft.id == retry.draftID else { return }
      switch result {
      case .recorded:
        if selectionActionState.pendingCitationBacklinkRetry?.id == retry.id {
          selectionActionState.pendingCitationBacklinkRetry = nil
        }
      case .failed:
        selectionActionState.pendingCitationBacklinkRetry = retry
        selectionActionMessage = String(localized: "正文已更新，但资料引用记录未保存；可重试。")
        EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage, priority: .high)
      }
    }
  }
}
