import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  var editorBufferRevision: UInt64 {
    editorState.draftBodyEditorBuffer(for: draft.id).revision
  }

  func stageEditorBody(replacingBaseBody baseBodyMarkdown: String) {
    guard
      let result = store.stageDraftBody(
        editorBody,
        for: draft.id,
        baseRevision: editorBodyRevision,
        replacingBaseBody: baseBodyMarkdown,
        notifyEditorObservers: false
      )
    else {
      return
    }

    editorBodyRevision = result.buffer.revision
    guard !result.wasAccepted else { return }

    editorBody = result.buffer.bodyMarkdown
    selectionActionMessage = "另一窗口已更新正文，刚才的陈旧修改未写入；已同步到最新版本。"
  }

  func handleEditorBodyChange(
    from previousBody: String,
    to _: String
  ) {
    syncActiveEditorSelection()
    stageEditorBody(replacingBaseBody: previousBody)
    refreshFindMatchSnapshot()
    synchronizeDocumentBodyFromBuffer(previousBody: previousBody)
    scheduleMarkdownAnalysis(isAutomatic: true)
    refreshMarkdownCursorContextSnapshot()
    saveCurrentEditorSession()
  }

  func handleCanonicalFrontMatterChange(_ updatedFrontMatter: String) {
    if ignoredCanonicalFrontMatter == updatedFrontMatter {
      ignoredCanonicalFrontMatter = nil
    } else {
      synchronizeDocumentFrontMatter(updatedFrontMatter)
    }
  }

  func syncEditorBodyFromStore(force: Bool = false) {
    let buffer = editorState.draftBodyEditorBuffer(for: draft.id)
    guard force || buffer.revision != editorBodyRevision else { return }
    editorBody = buffer.bodyMarkdown
    editorBodyRevision = buffer.revision
    refreshFindMatchSnapshot()
    refreshMarkdownCursorContextSnapshot()
  }

  func applyEditorDocument(from previousDocument: String, to document: String) {
    // Keyboard edits normally change only the body. Reuse the previous
    // front-matter boundary instead of normalizing and splitting the entire
    // document once for the document binding and again for the body binding.
    if let bodyOnlyEdit = bodyOnlyDocumentEdit(
      from: previousDocument,
      to: document
    ) {
      editorDocumentBodyOffsetCache = bodyOnlyEdit.bodyUTF16Offset
      if bodyOnlyEdit.bodyMarkdown != editorBody {
        editorBody = bodyOnlyEdit.bodyMarkdown
      }
      return
    }

    guard
      let parts = frontMatterEditingService.splitDocument(
        document,
        profile: activeProfile
      )
    else {
      frontMatterIssue = .invalidDelimiter
      return
    }
    editorDocumentBodyOffsetCache = parts.bodyUTF16Offset

    let metadataResult = frontMatterEditingService.applying(
      parts.frontMatter,
      to: draft,
      profile: activeProfile
    )
    frontMatterIssue = metadataResult.issue
    if metadataResult.isValid, metadataResult.draft != draft {
      ignoredCanonicalFrontMatter = frontMatterEditingService.render(
        draft: metadataResult.draft,
        profile: activeProfile
      )
      draft = metadataResult.draft
    }
    if parts.bodyMarkdown != editorBody {
      editorBody = parts.bodyMarkdown
    }
  }

  private func bodyOnlyDocumentEdit(
    from previousDocument: String,
    to updatedDocument: String
  ) -> (bodyMarkdown: String, bodyUTF16Offset: Int)? {
    let previousSource = previousDocument as NSString
    let currentBody = editorBody as NSString
    guard currentBody.length <= previousSource.length else { return nil }

    let bodyUTF16Offset = previousSource.length - currentBody.length
    let previousBody = previousSource.substring(from: bodyUTF16Offset)
    guard previousBody == editorBody else { return nil }

    let updatedSource = updatedDocument as NSString
    guard updatedSource.length >= bodyUTF16Offset else { return nil }
    guard
      updatedSource.substring(to: bodyUTF16Offset)
        == previousSource.substring(to: bodyUTF16Offset)
    else {
      return nil
    }

    return (
      bodyMarkdown: updatedSource.substring(from: bodyUTF16Offset),
      bodyUTF16Offset: bodyUTF16Offset
    )
  }

  func synchronizeDocumentBodyFromBuffer(previousBody: String? = nil) {
    // Keyboard edits arrive with the exact body that was previously rendered.
    // Replacing that suffix preserves front matter without reparsing the whole
    // document or rebuilding its front-matter model on every keystroke.
    let documentSource = editorDocument as NSString
    if editorDocumentBodyOffsetCache >= 0,
      editorDocumentBodyOffsetCache <= documentSource.length,
      documentSource.substring(from: editorDocumentBodyOffsetCache) == editorBody
    {
      return
    }

    if let previousBody, editorDocument.hasSuffix(previousBody) {
      let updatedDocument = String(editorDocument.dropLast(previousBody.count)) + editorBody
      guard editorDocument != updatedDocument else { return }
      editorDocument = updatedDocument
      return
    }

    // Keep a defensive fallback for external edits, draft switches and an
    // invalid document that no longer has the expected body suffix.
    guard let parts = editorDocumentParts else {
      let updatedDocument = frontMatterEditingService.composeDocument(
        frontMatter: canonicalFrontMatter,
        bodyMarkdown: editorBody
      )
      editorDocumentBodyOffsetCache =
        (updatedDocument as NSString).length
        - (editorBody as NSString).length
      editorDocument = updatedDocument
      return
    }
    guard parts.bodyMarkdown != editorBody else { return }
    let updatedDocument = frontMatterEditingService.composeDocument(
      frontMatter: parts.frontMatter,
      bodyMarkdown: editorBody
    )
    editorDocumentBodyOffsetCache =
      (updatedDocument as NSString).length
      - (editorBody as NSString).length
    editorDocument = updatedDocument
  }

  func synchronizeDocumentFrontMatter(_ frontMatter: String) {
    let body = editorDocumentParts?.bodyMarkdown ?? editorBody
    let updatedDocument = frontMatterEditingService.composeDocument(
      frontMatter: frontMatter,
      bodyMarkdown: body
    )
    guard editorDocument != updatedDocument else {
      frontMatterIssue = nil
      return
    }
    editorDocumentBodyOffsetCache =
      (updatedDocument as NSString).length
      - (body as NSString).length
    editorDocument = updatedDocument
    frontMatterIssue = nil
  }

  func resetEditorDocumentFromDraft() {
    ignoredCanonicalFrontMatter = nil
    frontMatterIssue = nil
    isFrontMatterSelection = false
    editorDocument = frontMatterEditingService.renderDocument(
      draft: draft,
      profile: activeProfile,
      bodyMarkdown: editorBody
    )
    editorDocumentBodyOffsetCache =
      (editorDocument as NSString).length
      - (editorBody as NSString).length
  }

  @discardableResult
  func applyDraftUpdate(_ updated: ArticleDraft) -> Bool {
    guard
      let result = store.replaceDraftBody(
        updated.bodyMarkdown,
        for: updated.id,
        expectedRevision: editorBodyRevision,
        notifyEditorObservers: false
      )
    else { return false }
    editorBody = result.buffer.bodyMarkdown
    editorBodyRevision = result.buffer.revision
    refreshMarkdownCursorContextSnapshot()
    guard result.wasAccepted else {
      selectionActionMessage = "另一窗口已更新正文，刚才的编辑命令未应用；已同步到最新版本。"
      return false
    }
    draft = updated
    return true
  }

  /// Routes programmatic body-only changes through the live `NSTextView`.
  /// AppKit then registers the edit in the same undo stack as keyboard input.
  @discardableResult
  func requestUndoableBodyUpdate(
    _ updated: ArticleDraft,
    selectionOverride: NSRange? = nil
  ) -> Bool {
    guard updated.id == draft.id else { return false }
    guard
      let edit = MarkdownTextMutationService.edit(
        from: editorBody,
        to: updated.bodyMarkdown,
        selectedRange: selectionOverride ?? selectedRange
      )
    else {
      return updated.bodyMarkdown == editorBody
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(
      expectedText: editorBody,
      edit: edit
    )
    return true
  }

  @discardableResult
  func insertKnowledgeMarkdown(
    _ markdown: String,
    at range: NSRange,
    citation: KnowledgeCitation? = nil
  ) -> Bool {
    guard requireBodyEditingContext() else { return false }
    let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = editorBody as NSString
    guard !normalized.isEmpty,
      range.location >= 0,
      range.length >= 0,
      range.location <= source.length,
      NSMaxRange(range) <= source.length
    else {
      return false
    }

    let before = source.substring(with: NSRange(location: 0, length: range.location))
    let afterStart = NSMaxRange(range)
    let after = source.substring(
      with: NSRange(location: afterStart, length: source.length - afterStart)
    )
    let leadingSeparator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n"
    let trailingSeparator = after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n"
    let replacement = leadingSeparator + normalized + trailingSeparator
    var updated = draft
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    let insertionEndRange = NSRange(
      location: range.location
        + (leadingSeparator as NSString).length
        + (normalized as NSString).length,
      length: 0
    )
    guard requestUndoableBodyUpdate(updated, selectionOverride: range) else { return false }
    selectedRange = insertionEndRange
    if let citation {
      store.knowledge.recordBacklinks(
        citations: [citation],
        target: KnowledgeBacklinkTarget(
          kind: .articleDraft,
          id: draft.id.uuidString,
          title: draft.title.nilIfEmpty ?? "当前文章",
          location: "正文"
        )
      )
    }
    selectionActionMessage = "已从资料库插入引用块。"
    return true
  }

  func applyEditorFocusRequest() {
    guard let request = editorState.editorFocusRequest, request.draftID == draft.id else {
      return
    }

    guard request.field == nil || request.field == "body" else {
      selectionActionMessage = "问题在 \(request.field ?? "元数据") 字段，右侧可直接处理。"
      return
    }

    let text = editorBody as NSString
    if let requestedRange = request.selectedRange,
      requestedRange.location >= 0,
      NSMaxRange(requestedRange) <= text.length
    {
      let expectedQuery = request.query?.trimmedForPublishing
      let selectedText = text.substring(with: requestedRange)
      if expectedQuery?.isEmpty != false
        || selectedText.compare(
          expectedQuery ?? "",
          options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) == .orderedSame
      {
        focusMarkdownText(
          for: request.id,
          selectedRange: requestedRange,
          message: "已定位到正文匹配内容。"
        )
        return
      }
    }

    if let query = request.query?.trimmedForPublishing, !query.isEmpty {
      let range = text.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
      )
      if range.location != NSNotFound {
        focusMarkdownText(
          for: request.id,
          selectedRange: range,
          message: "已定位到正文匹配内容。"
        )
        return
      }
    }

    focusMarkdownText(
      for: request.id,
      selectedRange: NSRange(location: 0, length: 0),
      message: "已定位到正文。"
    )
  }

  func focusMarkdownText(
    for requestID: UUID,
    selectedRange: NSRange,
    message: String,
    isAnimated: Bool = false
  ) {
    self.selectedRange = selectedRange
    markdownTextFocusRequest = MarkdownTextFocusRequest(
      id: requestID,
      selectedRange: selectedRange,
      isAnimated: isAnimated
    )
    selectionActionMessage = message
  }
}
