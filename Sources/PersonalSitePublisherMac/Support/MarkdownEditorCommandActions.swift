import PublishingWorkbenchCore
import SwiftUI

struct MarkdownEditorCommandActions {
  var draftID: UUID
  var canRewriteSelection: Bool
  var canUseFindReplace: Bool
  var showFindReplace: () -> Void
  var showKeyboardShortcuts: () -> Void
  var showSnippets: () -> Void
  var findPrevious: () -> Void
  var findNext: () -> Void
  var replaceCurrentOrNext: () -> Void
  var replaceAll: () -> Void
  var applyFormatting: (MarkdownFormattingCommand) -> Void
  var insertImages: () -> Void
  var runPreflight: () -> Void
  var rewriteSelection: () -> Void
  var openAIAssistant: () -> Void
  var copyAIPrompt: () -> Void
  var openExternalBrowserPreview: () -> Void = {}
}

private struct MarkdownEditorCommandActionsKey: FocusedValueKey {
  typealias Value = MarkdownEditorCommandActions
}

extension FocusedValues {
  var markdownEditorCommandActions: MarkdownEditorCommandActions? {
    get { self[MarkdownEditorCommandActionsKey.self] }
    set { self[MarkdownEditorCommandActionsKey.self] = newValue }
  }
}
