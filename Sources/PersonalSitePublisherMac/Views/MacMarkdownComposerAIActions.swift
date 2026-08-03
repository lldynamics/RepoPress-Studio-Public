import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
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
    AIPublishingWritingActionCatalog.selectionActions.contains { $0.kind == kind }
  }

  func pasteAIPromptToClipboard() {
    cancelAIPromptClipboardTask()
    let requestedDraft = previewDraft
    let requestedBody = requestedDraft.bodyMarkdown
    let requestID = UUID()
    aiPromptClipboardRequestID = requestID
    store.setPublishActionMessage(String(localized: "正在生成 AI Prompt…"))
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
        store.setPublishActionMessage(String(localized: "文章已变化，未复制陈旧 AI Prompt；请重试。"))
        return
      }
      ClipboardWriter.copy(
        prompt,
        successMessage: "已复制 AI Prompt。"
      ) { store.setPublishActionMessage($0) }
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
    performSelectionAIAction(kind, presentsInlineResult: false)
  }

  func performSelectionAIAction(
    _ kind: AIPublishingActionKind,
    presentsInlineResult: Bool = false
  ) {
    let rawSelectedText = selectedText(in: editorBody)
    let promptSelectedText = rawSelectedText.trimmedForPublishing
    let availability = selectionAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多上下文")"
      return
    }

    cancelSelectionAIAction()
    let requestedDraft = previewDraft
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    isInlineSelectionAIAction = presentsInlineResult
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    if !presentsInlineResult {
      showWritingContextPanel(.selectionTools)
    }
    let previewRange = clamped(selectedRange, length: (editorBody as NSString).length)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      let result = await aiActions.performAction(
        kind,
        draft: requestedDraft,
        selectedText: promptSelectedText
      )
      guard selectionAIActionRequestID == requestID else { return }
      defer { finishSelectionAIAction(requestID: requestID) }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        let preview = AIPublishingSelectionEditPreview(
          draftID: requestedDraft.id,
          sourceBodyMarkdown: requestedDraft.bodyMarkdown,
          kind: result.kind,
          range: previewRange,
          originalText: rawSelectedText,
          replacementText: result.content,
          application: selectionEditApplication(for: result.kind),
          providerName: result.providerName,
          model: result.model,
          knowledgeCitations: result.knowledgeCitations
        )
        selectionEditPreview = preview
        if !presentsInlineResult {
          showWritingContextPanel(.aiReview)
        }
        selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
        EditorAccessibilityAnnouncementCenter.announceAIPreview(
          kind: result.kind.localizedDisplayName,
          characterCount: (preview.trimmedReplacementText as NSString).length
        )
      } else {
        selectionActionMessage = kind.localizedDisplayName + "失败。"
        EditorAccessibilityAnnouncementCenter.announce(
          selectionActionMessage,
          priority: .high
        )
      }
    }
  }

  func performArticleAIAction(_ kind: AIPublishingActionKind) {
    let availability = articleAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多文章内容")"
      return
    }

    cancelSelectionAIAction()
    let requestedDraft = previewDraft
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    let previewRange = articleInsertionRange(for: kind)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      let result = await aiActions.performAction(kind, draft: requestedDraft)
      guard selectionAIActionRequestID == requestID else { return }
      defer { finishSelectionAIAction(requestID: requestID) }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        if result.kind.producesMetadataSuggestion, editorState.aiMetadataSuggestion != nil {
          selectionActionMessage = result.kind.localizedDisplayName + "已生成，可在元数据建议中应用。"
          EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
        } else {
          let preview = AIPublishingSelectionEditPreview(
            draftID: requestedDraft.id,
            sourceBodyMarkdown: requestedDraft.bodyMarkdown,
            kind: result.kind,
            range: previewRange,
            originalText: "",
            replacementText: result.content,
            application: .insertAtRange,
            providerName: result.providerName,
            model: result.model,
            knowledgeCitations: result.knowledgeCitations
          )
          selectionEditPreview = preview
          showWritingContextPanel(.aiReview)
          selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
          EditorAccessibilityAnnouncementCenter.announceAIPreview(
            kind: result.kind.localizedDisplayName,
            characterCount: (preview.trimmedReplacementText as NSString).length
          )
        }
      } else {
        selectionActionMessage = kind.localizedDisplayName + "失败。"
        EditorAccessibilityAnnouncementCenter.announce(
          selectionActionMessage,
          priority: .high
        )
      }
    }
  }

  func cancelSelectionAIAction() {
    selectionAIActionTask?.cancel()
    selectionAIActionTask = nil
    selectionAIActionRequestID = nil
    activeSelectionAIAction = nil
    isInlineSelectionAIAction = false
    selectionEditPreview = nil
    if activeWritingContextPanel == .aiReview {
      activeWritingContextPanel = hasSelectedText ? .selectionTools : nil
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

    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: previewDraft,
      mode: .replaceSelection,
      selectionRange: range
    ) else {
      selectionActionMessage = "AI 回复为空或选区无效。"
      return
    }

    let replacementLength = (message.content.trimmedForPublishing as NSString).length
    guard requestUndoableBodyUpdate(result.draft, selectionOverride: range) else { return }
    selectedRange = NSRange(location: range.location + replacementLength, length: 0)
    recordKnowledgeCitations(
      message.knowledgeCitations,
      for: result.draft
    )
    selectionActionMessage = result.action.statusMessage
  }

  func showAIContextInspector() {
    aiActions.openChatWorkspace(for: draft.id)
  }

  func performTemplateLibraryAction(_ kind: AIPublishingActionKind) {
    if isSelectionAIAction(kind) {
      performSelectionAIAction(kind)
    } else {
      performArticleAIAction(kind)
    }
  }

  func openTemplateLibraryPrompt(_ prompt: AIPublishingQuickPrompt) {
    aiActions.openChatWorkspace(for: draft.id, quickPrompt: prompt)
  }

  func applySelectionEditPreview(_ preview: AIPublishingSelectionEditPreview) {
    do {
      let originalLength = (editorBody as NSString).length
      let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: previewDraft)
      let updatedLength = (updated.bodyMarkdown as NSString).length
      let insertedLength = max(0, updatedLength - originalLength)
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
    store.knowledge.recordBacklinks(
      citations: citations,
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: draft.id.uuidString,
        title: draft.title.nilIfEmpty ?? "当前文章",
        location: "正文"
      )
    )
  }
}
