import PublishingWorkbenchCore

struct MarkdownEditorToolbarActions {
  let onSetWritingToolDensity: (MarkdownWritingToolDensity) -> Void
  let onShowFindReplace: () -> Void
  let onShowOutline: () -> Void
  let onOpenWritingContextPanel: (MarkdownWritingContextPanel) -> Void
  let onShowShortcutHelp: () -> Void
  let onPreparePublish: () -> Void
  let onOpenAIContextInspector: () -> Void
  let onOpenAITemplateLibrary: () -> Void
  let onRequestInlineAICompletion: () -> Void
  let onExportDocument: (MarkdownDocumentExportFormat) -> Void
  let selectionAIActionAvailability:
    (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let articleAIActionAvailability:
    (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformArticleAIAction: (AIPublishingActionKind) -> Void
  let onPerformConvergedSelectionAIAction: (AIPublishingActionConvergence) -> Void
  let onPerformConvergedArticleAIAction: (AIPublishingActionConvergence) -> Void
  let onPasteAIPromptToClipboard: () -> Void
  var onFormatChineseTypography: (() -> Void)? = nil
  var onCopyForWeChatAndZhihu: (() -> Void)? = nil
}
