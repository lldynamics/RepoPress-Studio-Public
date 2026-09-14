import Foundation
import PublishingMarkdownCore

struct MarkdownPendingFindReplacement {
  let requestID: UUID
  let draftID: UUID
  let selection: MarkdownFindScopeSnapshot?
  let edit: MarkdownSmartEdit
  let count: Int

  func rebasedSelection(bodyRevision: UInt64, body: String) -> MarkdownFindScopeSnapshot? {
    guard let selection, bodyRevision == selection.bodyRevision &+ 1,
      edit.replacedRange.location >= selection.range.location,
      NSMaxRange(edit.replacedRange) <= NSMaxRange(selection.range)
    else { return nil }
    let relativeRange = NSRange(
      location: edit.replacedRange.location - selection.range.location,
      length: edit.replacedRange.length
    )
    let selectedText = (selection.selectedText as NSString).replacingCharacters(
      in: relativeRange, with: edit.replacement
    )
    let newRange = NSRange(
      location: selection.range.location, length: (selectedText as NSString).length)
    let result = MarkdownFindScopeSnapshot(
      draftID: draftID, bodyRevision: bodyRevision, range: newRange, selectedText: selectedText
    )
    return result.isValid(for: draftID, bodyRevision: bodyRevision, body: body) ? result : nil
  }
}

extension MacMarkdownComposerView {
  func enqueueFindReplacement(edit: MarkdownSmartEdit, count: Int, expectedBody: String) {
    guard editorSessionState.liveBodyRevision == editorBodyRevision else {
      findReplaceMessage = String(localized: "正文正在同步，请稍后重试。")
      return
    }
    let request = MarkdownTextEditRequest(expectedText: expectedBody, edit: edit)
    pendingFindReplacement = MarkdownPendingFindReplacement(
      requestID: request.id, draftID: draft.id,
      selection: findScope == .selection ? findScopeSnapshot : nil,
      edit: edit, count: count
    )
    editorEditRequest = request
  }

  func handleFindReplacementOutcome(_ outcome: MarkdownTextEditRequestOutcome) {
    guard let pending = pendingFindReplacement, pending.requestID == outcome.id else { return }
    pendingFindReplacement = nil
    guard pending.draftID == draft.id else { return }
    if outcome.wasApplied {
      // Rebase only after AppKit acknowledges this exact request. An extra
      // live edit advances the revision again and deliberately rejects it.
      if pending.selection != nil {
        findScopeSnapshot = pending.rebasedSelection(
          bodyRevision: editorSessionState.liveBodyRevision,
          body: editorSessionState.liveBodyMarkdown
        )
      }
      syncEditorBodyFromStore()
      refreshFindMatchSnapshot()
      findReplaceMessage = String(format: String(localized: "已替换 %d 处，可撤销。"), pending.count)
    } else {
      findReplaceMessage = String(localized: "正文已变化，未应用替换。请重新预览。")
    }
  }
}
