import Foundation
import PublishingWorkbenchCore

extension MacMarkdownComposerView {
  var markdownCursorPosition: MarkdownCursorPosition? {
    markdownCursorContextSnapshot?.position
  }

  var activeMarkdownFenceMatch: MarkdownFenceMatch? {
    markdownCursorContextSnapshot?.fenceMatch
  }

  var markdownCursorCompletion: MarkdownCompletionContext? {
    markdownCursorCompletionSnapshot
  }

  /// Refreshes the cursor snapshot only when the body revision or selection
  /// changes.  Completion is intentionally trigger-gated so ordinary cursor
  /// movement never builds the article/snippet candidate list.
  func refreshMarkdownCursorContextSnapshot() {
    guard !isFrontMatterSelection else {
      markdownCursorContextSnapshot = nil
      markdownCursorCompletionSnapshot = nil
      return
    }

    let contextService = MarkdownCursorContextService()
    let snapshot = contextService.snapshot(
      in: editorBody,
      selectedRange: selectedRange,
      revision: editorBodyRevision
    )
    guard markdownCursorContextSnapshot != snapshot else { return }
    markdownCursorContextSnapshot = snapshot
    markdownCursorCompletionSnapshot = nil

    let completionService = MarkdownCursorCompletionService()
    guard
      completionService.shouldBuildCompletion(
        in: editorBody,
        selectedRange: selectedRange
      )
    else {
      return
    }

    let profile = activeProfile
    let articles = editorState.drafts.compactMap { candidate -> MarkdownCompletionArticle? in
      guard candidate.id != draft.id,
        !candidate.isGeneralDraft,
        candidate.belongs(toSiteProfileID: draft.siteProfileID)
      else {
        return nil
      }
      let title = candidate.title.trimmedForPublishing
      let slug = candidate.slug.trimmedForPublishing
      guard !title.isEmpty || !slug.isEmpty else { return nil }
      return MarkdownCompletionArticle(
        id: candidate.id,
        title: title.nilIfEmpty ?? slug,
        slug: slug,
        destination: MarkdownInternalLinkService.destination(
          for: candidate,
          profile: profile
        )
      )
    }
    markdownCursorCompletionSnapshot = completionService.completion(
      in: editorBody,
      selectedRange: selectedRange,
      context: snapshot,
      articles: articles,
      snippets: markdownSSGSnippets
    )
  }

  func jumpToMarkdownLine(_ line: Int) {
    guard
      requireBodyEditingContext(),
      let range = MarkdownCursorContextService().jumpTarget(
        in: editorBody,
        line: line
      )
    else {
      selectionActionMessage = "行号超出正文范围。"
      return
    }
    focusBodyRange(range, message: "已跳转到第 \(line) 行。")
  }

  func jumpToCounterpartFence() {
    guard requireBodyEditingContext(), let match = activeMarkdownFenceMatch else {
      return
    }
    guard let closingRange = match.closingMarkerRange else {
      focusBodyRange(
        match.openingMarkerRange,
        message: "这个代码围栏尚未闭合，已定位到起始标记。"
      )
      return
    }
    let target =
      selectedRange.location <= NSMaxRange(match.openingMarkerRange)
      ? closingRange
      : match.openingMarkerRange
    focusBodyRange(
      target,
      message: "已定位到匹配的代码围栏标记。"
    )
  }

  func applyMarkdownCompletion(_ candidate: MarkdownCompletionCandidate) {
    guard requireBodyEditingContext() else { return }
    guard
      let edit = MarkdownCursorCompletionService().edit(
        applying: candidate,
        in: editorBody
      )
    else {
      selectionActionMessage = "补全上下文已经变化，请重新输入触发词。"
      return
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(
      expectedText: editorBody,
      edit: edit
    )
    selectionActionMessage = "已插入\(candidate.title)。"
  }

  func insertMarkdownCompletionTrigger(_ trigger: MarkdownCompletionTrigger) {
    guard requireBodyEditingContext() else { return }
    let source = editorBody as NSString
    guard selectedRange.location >= 0, NSMaxRange(selectedRange) <= source.length else {
      return
    }
    let insertion = trigger.insertion(
      in: source,
      selectedRange: selectedRange
    )
    let edit = MarkdownSmartEdit(
      replacedRange: selectedRange,
      replacement: insertion.text,
      selectedRange: NSRange(
        location: selectedRange.location + insertion.caretUTF16Offset,
        length: 0
      )
    )
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(
      expectedText: editorBody,
      edit: edit
    )
    selectionActionMessage = trigger.feedbackMessage
  }

  func performMarkdownDocumentExport(_ format: MarkdownDocumentExportFormat) {
    let title = draft.title
    let markdown = editorBody
    Task { @MainActor in
      do {
        let plan = try MarkdownDocumentExportPlanningService().plan(
          title: title,
          markdown: markdown,
          format: format
        )
        let result = try await MarkdownDocumentExportExecutor.execute(plan)
        selectionActionMessage = result.userMessage
        EditorAccessibilityAnnouncementCenter.announce(result.userMessage)
      } catch {
        let message = "导出失败：\(error.localizedDescription)"
        selectionActionMessage = message
        EditorAccessibilityAnnouncementCenter.announce(message)
      }
    }
  }

  private func focusBodyRange(_ range: NSRange, message: String) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    selectedRange = range
    markdownTextFocusRequest = MarkdownTextFocusRequest(
      id: UUID(),
      selectedRange: range
    )
    selectionActionMessage = message
  }
}

enum MarkdownCompletionTrigger: String, CaseIterable, Identifiable {
  case slash
  case internalLink
  case codeLanguage

  var id: String { rawValue }

  var insertedText: String {
    switch self {
    case .slash:
      "/"
    case .internalLink:
      "[["
    case .codeLanguage:
      "```"
    }
  }

  func insertion(
    in source: NSString,
    selectedRange: NSRange
  ) -> (text: String, caretUTF16Offset: Int) {
    let baseText = insertedText
    guard self != .internalLink else {
      return (baseText, (baseText as NSString).length)
    }
    let lineRange = source.lineRange(
      for: NSRange(location: selectedRange.location, length: 0)
    )
    let prefixRange = NSRange(
      location: lineRange.location,
      length: selectedRange.location - lineRange.location
    )
    let prefix = source.substring(with: prefixRange)
    let linePrefix = prefix.trimmingCharacters(in: .whitespaces)
    let leadingNewline = linePrefix.isEmpty ? "" : "\n"
    let text = leadingNewline + baseText
    let caretOffset: Int
    switch self {
    case .slash:
      caretOffset = (text as NSString).length
    case .codeLanguage:
      caretOffset = (leadingNewline as NSString).length + 3
    case .internalLink:
      caretOffset = (text as NSString).length
    }
    return (text, caretOffset)
  }

  var title: String {
    switch self {
    case .slash:
      "块命令（/表格、/代码、/图片、/脚注）"
    case .internalLink:
      "文章链接（[[文章]]）"
    case .codeLanguage:
      "代码语言（```swift）"
    }
  }

  var systemImage: String {
    switch self {
    case .slash:
      "slash.circle"
    case .internalLink:
      "link"
    case .codeLanguage:
      "chevron.left.forwardslash.chevron.right"
    }
  }

  var feedbackMessage: String {
    switch self {
    case .slash:
      "已输入 /；继续输入表格、代码、图片或脚注，然后从工具栏选择补全。"
    case .internalLink:
      "已输入 [[；继续输入文章名，然后从工具栏选择补全。"
    case .codeLanguage:
      "已输入代码围栏；继续输入语言名，然后从工具栏选择补全。"
    }
  }
}
