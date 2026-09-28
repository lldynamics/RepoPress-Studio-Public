import Foundation
import PublishingAICore

extension WorkbenchAIFeatureFacade {
  public func availableGeneralChatContextReferences(
    windowID: UUID? = nil
  ) -> [AIContextReference] {
    store.aiStore.availableGeneralAIChatContextReferences(windowID: windowID)
  }

  /// Applies a chat block against the caller's window-owned selection. A
  /// window-scoped request fails closed if its selection is no longer active;
  /// it must not fall back to the end of the shared draft.
  @discardableResult
  public func applyChatMarkdown(
    _ markdown: String,
    to draft: ArticleDraft,
    mode: AIChatMarkdownInsertionMode,
    originatingWindowID: UUID? = nil
  ) -> Bool {
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = store.drafts.first(where: { $0.id == draft.id }) else {
      store.setPublishActionMessage(
        CoreL10n.text("当前文章已变化，请重新选择后再应用。"), status: .warning
      )
      return false
    }
    let selection = store.activeEditorSelectionRange(
      for: currentDraft, windowID: originatingWindowID
    )
    guard originatingWindowID == nil || selection != nil else {
      store.setPublishActionMessage(
        CoreL10n.text("代码块内容为空或当前编辑位置已失效。"), status: .warning
      )
      return false
    }
    guard
      let insertion = AIChatMarkdownInsertionService.inserting(
        markdown, into: currentDraft.bodyMarkdown, selection: selection, mode: mode
      )
    else {
      store.setPublishActionMessage(
        CoreL10n.text("代码块内容为空或当前编辑位置已失效。"), status: .warning
      )
      return false
    }
    let buffer = store.draftBodyEditorBuffer(for: currentDraft.id)
    guard
      let staged = store.replaceDraftBody(
        insertion.updatedBodyMarkdown, for: currentDraft.id, expectedRevision: buffer.revision
      ), staged.wasAccepted
    else {
      store.setPublishActionMessage(
        CoreL10n.text("当前文章在应用前已被其他窗口修改，请重新尝试。"), status: .warning
      )
      return false
    }
    store.save()
    store.selectSection(.writing)
    store.requestEditorFocus(
      draftID: currentDraft.id, field: "body", selectedRange: insertion.insertedRange
    )
    switch mode {
    case .applyToCurrentEditor:
      store.setPublishActionMessage(CoreL10n.text("已将代码块应用到当前编辑器。"), status: .success)
    case .insertAtCursor:
      store.setPublishActionMessage(CoreL10n.text("已将代码块插入到光标处。"), status: .success)
    }
    return true
  }

  public func availableChatContextReferences(
    for draft: ArticleDraft,
    windowID: UUID? = nil
  ) -> [AIContextReference] {
    store.aiStore.availableAIChatContextReferences(for: draft, windowID: windowID)
  }

}
