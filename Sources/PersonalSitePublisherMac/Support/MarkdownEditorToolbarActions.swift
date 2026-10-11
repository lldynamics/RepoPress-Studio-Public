import PublishingWorkbenchCore
import SwiftUI

struct MarkdownEditorToolbarActions {
  let onShowFindReplace: () -> Void
  let onShowOutline: () -> Void
  let onShowShortcutHelp: () -> Void
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
  var isAIEnabled = true
  var isBodySelectionActive = true
  var canRequestInlineAICompletion = true
  var onPrepareVersionHistory: () -> Bool = { true }
  var onFormatChineseTypography: (() -> Void)? = nil
  var onCopyForWeChatAndZhihu: (() -> Void)? = nil
  var onShowImageInfo: (() -> Void)? = nil

  func selectionAvailability(
    for kind: AIPublishingActionKind
  ) -> AIPublishingActionAvailabilityPresentation {
    guard isBodySelectionActive else {
      return AIPublishingActionAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: String(localized: "需要先选择正文")
      )
    }
    return selectionAIActionAvailability(kind)
  }
}

enum MarkdownEditorAIConfigurationPresentation {
  static func destination(
    for config: AIProviderConfig,
    isAIEnabled: Bool,
    hasAuthenticatedChatGPTAccount: Bool
  ) -> SettingsDestination? {
    if config.preset == .codexAppServer {
      return hasAuthenticatedChatGPTAccount ? nil : .ai(.connection)
    }
    return config.requiresAPIKey && !isAIEnabled ? .ai(.credentials) : nil
  }
}

/// Installed by the mounted toolbar, so the app command is available before
/// the overflow menu is opened and always targets the focused scene's draft.
struct MarkdownEditorVersionHistoryCommandAction {
  let draftID: UUID
  let prepare: () -> Bool
  let present: () -> Void

  func open() {
    guard prepare() else { return }
    present()
  }
}

private struct MarkdownEditorVersionHistoryCommandActionKey: FocusedValueKey {
  typealias Value = MarkdownEditorVersionHistoryCommandAction
}

extension FocusedValues {
  var markdownEditorVersionHistoryCommandAction: MarkdownEditorVersionHistoryCommandAction? {
    get { self[MarkdownEditorVersionHistoryCommandActionKey.self] }
    set { self[MarkdownEditorVersionHistoryCommandActionKey.self] = newValue }
  }
}
