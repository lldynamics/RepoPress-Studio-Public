import Foundation
import PublishingWorkbenchCore

extension MacMarkdownComposerView {
  func replaceCurrentOrNext() {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }
    guard let scopeRange = currentFindScopeRange else {
      findReplaceMessage = String(localized: "选区已变化，请重新打开查找。")
      return
    }
    let body = editorBody
    let bodyRevision = editorBodyRevision
    let query = findQuery
    let replacement = replacementText
    let options = findOptions
    let requestedDraftID = draft.id
    let requestedSelection = selectedRange
    findReplaceMessage = String(localized: "正在计算替换…")
    editorSessionState.findReplacePlanningCoordinator.schedule(
      .init(
        kind: .current(selectedRange: requestedSelection), body: body,
        scopeRange: scopeRange, query: query, replacement: replacement, options: options
      )
    ) { [weak editorSessionState] result in
      guard let editorSessionState,
        requestedDraftID == draft.id,
        selectedRange == requestedSelection,
        editorSessionState.liveBodyRevision == bodyRevision,
        editorBody == body,
        findQuery == query,
        replacementText == replacement,
        findOptions == options,
        currentFindScopeRange == scopeRange
      else { return }
      switch result {
      case .current(let mutation):
        guard let mutation else {
          findReplaceMessage = "没有找到可替换内容。"
          return
        }
        enqueueFindReplacement(edit: mutation.edit, count: 1, expectedBody: body)
      case .failure(let message):
        findReplaceMessage = message
      case .preview:
        return
      }
    }
  }

  func replaceAll() {
    guard editorSessionState.liveBodyRevision == editorBodyRevision else {
      findReplaceMessage = String(localized: "正文正在同步，请稍后重试。")
      return
    }
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }
    guard let scopeRange = currentFindScopeRange else {
      findReplaceMessage = String(localized: "选区已变化，请重新打开查找。")
      return
    }
    let body = editorBody
    let bodyRevision = editorBodyRevision
    let query = findQuery
    let replacement = replacementText
    let options = findOptions
    let scope = findScope
    let requestedDraftID = draft.id
    findReplaceMessage = String(localized: "正在计算替换…")
    editorSessionState.findReplacePlanningCoordinator.schedule(
      .init(
        kind: .all(draftID: requestedDraftID, bodyRevision: bodyRevision, scope: scope),
        body: body, scopeRange: scopeRange, query: query,
        replacement: replacement, options: options
      )
    ) { [weak editorSessionState] result in
      guard let editorSessionState,
        requestedDraftID == draft.id,
        editorSessionState.liveBodyRevision == bodyRevision,
        editorBody == body,
        findQuery == query,
        replacementText == replacement,
        findOptions == options,
        findScope == scope,
        currentFindScopeRange == scopeRange
      else { return }
      switch result {
      case .preview(let preview):
        guard preview.replacementCount > 0 else {
          findReplaceMessage = "没有找到可替换内容。"
          return
        }
        pendingFindReplacePreview = preview
        findReplaceMessage = String(
          format: String(localized: "请检查 %d 处变化后确认。"), preview.replacementCount
        )
      case .failure(let message):
        findReplaceMessage = message
      case .current:
        return
      }
    }
  }
}
