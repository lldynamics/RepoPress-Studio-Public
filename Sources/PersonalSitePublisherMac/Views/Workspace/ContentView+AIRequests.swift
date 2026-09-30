import PublishingWorkbenchCore
import SwiftUI

extension ContentView {
  var aiChatWorkspaceCommandAction: AIChatWorkspaceCommandAction {
    AIChatWorkspaceCommandAction(
      isAvailable: canRequestInspectorInCurrentLayout,
      unavailableReason: canRequestInspectorInCurrentLayout
        ? nil
        : String(localized: "扩大窗口后可使用详情栏"),
      open: { draftID, quickPrompt in
        openAIAssistantWorkspace(for: draftID, quickPrompt: quickPrompt)
      },
      openAfterSheetDismissal: { draftID, quickPrompt in
        deferredPaletteAIRequest.enqueue(draftID: draftID, quickPrompt: quickPrompt)
      },
      sheetDidDismiss: {
        deferredPaletteAIRequest.sheetDidDismiss()
        performDeferredPaletteAIRequestIfReady()
      }
    )
  }

  @discardableResult
  func openAIAssistantWorkspace(
    for draftID: UUID?,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    guard prepareInspectorForUserRequest()
    else { return false }
    guard activateCurrentWindowSharedContext() else { return false }
    if effectiveFocusMode {
      isFocusMode = false
    }
    return store.ai.openChatWorkspace(
      for: draftID, quickPrompt: quickPrompt, ownerWindowID: windowSession.windowID)
  }

  func performDeferredPaletteAIRequestIfReady() {
    guard controlActiveState == .key, modalPresentation.presented == nil,
      let request = deferredPaletteAIRequest.consume(isKeyWindow: windowSession.isKeyWindow)
    else { return }
    if let draftID = request.draftID {
      guard store.drafts.contains(where: { $0.id == draftID }) else { return }
      focusWindowDraft(draftID, section: .writing)
    }
    _ = openAIAssistantWorkspace(for: request.draftID, quickPrompt: request.quickPrompt)
  }

}
