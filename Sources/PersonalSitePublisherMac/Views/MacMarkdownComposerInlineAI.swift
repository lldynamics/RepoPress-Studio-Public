import Foundation
import PublishingWorkbenchCore

extension MacMarkdownComposerView {
  private var inlineAIContextService: MarkdownInlineAIContextService {
    MarkdownInlineAIContextService()
  }

  var shouldShowInlineSelectionPalette: Bool {
    activeWritingContextPanel == nil
      && !isInlineSelectionPaletteDismissed
      && (isInlineSelectionAIAction || (hasSelectedText && selectionEditPreview == nil))
  }

  func inlineSelectionAIActionAvailability(
    _ kind: AIPublishingActionKind
  ) -> AIPublishingActionAvailabilityPresentation {
    selectionAIActionAvailability(kind, respectActiveAction: false)
  }

  func performInlineSelectionAIAction(_ kind: AIPublishingActionKind) {
    isInlineSelectionPaletteDismissed = false
    performSelectionAIAction(kind, presentsInlineResult: true)
  }

  func performInlineConvergedSelectionAIAction(_ convergence: AIPublishingActionConvergence) {
    isInlineSelectionPaletteDismissed = false
    performSelectionAIAction(
      convergence.canonicalActionKind,
      convergence: convergence,
      presentsInlineResult: true
    )
  }

  func scheduleInlineGhostText() {
    cancelInlineGhostText()
    guard isAutomaticInlineAICompletionEnabled,
          !isFrontMatterSelection,
          selectedRange.length == 0,
          !isSelectionAIActionRunning,
          isAIEnabledForDraft else {
      return
    }

    let requestedBody = editorBody
    let cursor = selectedRange.location
    guard let context = inlineAIContextService.context(
      in: requestedBody,
      cursorUTF16Location: cursor
    ) else {
      return
    }

    let requestedDraft = previewDraft
    let requestID = UUID()
    inlineGhostRequestID = requestID
    inlineGhostTask = Task { @MainActor in
      defer {
        if inlineGhostRequestID == requestID {
          inlineGhostTask = nil
          inlineGhostRequestID = nil
        }
      }
      do {
        try await Task.sleep(for: .milliseconds(850))
      } catch {
        return
      }
      guard !Task.isCancelled,
            inlineGhostRequestID == requestID,
            draft.id == requestedDraft.id,
            editorBody == requestedBody,
            selectedRange.length == 0,
            selectedRange.location == cursor else {
        return
      }

      let result = await aiActions.performAction(
        .continueAfterSelection,
        draft: requestedDraft,
        selectedText: context
      )
      guard !Task.isCancelled,
            inlineGhostRequestID == requestID,
            draft.id == requestedDraft.id,
            editorBody == requestedBody,
            selectedRange.length == 0,
            selectedRange.location == cursor,
            let content = result?.content,
            let normalized = inlineAIContextService.normalizedContinuation(content) else {
        return
      }
      inlineGhostText = normalized
    }
  }

  func cancelInlineGhostText() {
    inlineGhostTask?.cancel()
    inlineGhostTask = nil
    inlineGhostRequestID = nil
    inlineGhostText = ""
  }

  func acceptInlineGhostText() {
    let textToInsert = inlineGhostText
    cancelInlineGhostText()
    guard !textToInsert.isEmpty else { return }
    let edit = MarkdownSmartEdit(
      replacedRange: selectedRange,
      replacement: textToInsert,
      selectedRange: NSRange(
        location: selectedRange.location + (textToInsert as NSString).length,
        length: 0
      )
    )
    editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    EditorAccessibilityAnnouncementCenter.announce("已采纳 AI 续写。")
  }

  func dismissInlineGhostText() {
    cancelInlineGhostText()
  }
}
