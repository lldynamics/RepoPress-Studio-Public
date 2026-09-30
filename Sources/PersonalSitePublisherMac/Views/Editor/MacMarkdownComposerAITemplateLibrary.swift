import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  var aiTemplateLibrary: some View {
    AIPublishingTemplateLibraryView(
      draft: previewDraft,
      selectedText: selectedText(in: editorBody),
      availabilityForAction: { kind in
        if isSelectionAIAction(kind) {
          selectionAIActionAvailability(kind, respectActiveAction: false)
        } else {
          articleAIActionAvailability(kind, respectActiveAction: false)
        }
      },
      onPerformAction: performTemplateLibraryAction,
      onUsePrompt: openTemplateLibraryPrompt
    )
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
      let open =
        aiChatWorkspaceCommandAction.openAfterSheetDismissal
        ?? aiChatWorkspaceCommandAction.open
      open(draft.id, prompt)
    } else {
      aiActions.openChatWorkspace(
        for: draft.id, quickPrompt: prompt, ownerWindowID: workspaceWindowSession?.windowID)
    }
  }

}
