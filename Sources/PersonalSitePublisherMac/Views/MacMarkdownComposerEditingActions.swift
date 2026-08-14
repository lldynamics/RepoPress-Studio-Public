import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  func showOutline() {
    showWritingContextPanel(.outline)
  }

  func showDiagnostics() {
    isDiagnosticsPresented = true
    guard appliedMarkdownAnalysisGeneration != markdownAnalysisGeneration else { return }
    scheduleMarkdownAnalysis(immediate: true)
  }

  func scheduleMarkdownAnalysis(
    immediate: Bool = false,
    includeOutline: Bool? = nil,
    isAutomatic: Bool = false
  ) {
    if isAutomatic,
      !MarkdownEditorAutomationPolicy.allows(
        isAutomatic: true,
        isEnabled: isRealtimeAnalysisEnabled
      )
    {
      invalidateMarkdownAnalysis()
      return
    }
    markdownAnalysisTask?.cancel()
    markdownAnalysisTask = nil
    markdownAnalysisTaskIsAutomatic = false
    markdownAnalysisGeneration &+= 1
    let generation = markdownAnalysisGeneration
    let requestedMarkdown = editorBody
    let requestedDraftID = draft.id
    let shouldIncludeOutline = includeOutline ?? true
    let diagnosticContext = MarkdownInlineDiagnosticContext(
      knownArticleTitles: store.knownArticleTitlesForMarkdownDiagnostics,
      attachmentPaths: Set(
        draft.attachments.flatMap {
          [$0.relativePublishPath, $0.repositoryPath]
            .compactMap { $0.trimmedForPublishing.nilIfEmpty }
        }
      )
    )

    markdownAnalysisTaskIsAutomatic = isAutomatic
    markdownAnalysisTask = Task { @MainActor in
      defer {
        if markdownAnalysisGeneration == generation {
          markdownAnalysisTask = nil
          markdownAnalysisTaskIsAutomatic = false
        }
      }
      if !immediate {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      let snapshot = await markdownAnalysisService.analyzeInBackground(
        requestedMarkdown,
        diagnosticContext: diagnosticContext,
        includeOutline: shouldIncludeOutline
      )
      guard !Task.isCancelled,
            markdownAnalysisGeneration == generation,
            draft.id == requestedDraftID,
            editorBody == requestedMarkdown else { return }
      markdownAnalysis = snapshot
      appliedMarkdownAnalysisGeneration = generation
    }
  }

  func invalidateMarkdownAnalysis() {
    guard markdownAnalysisTask == nil || markdownAnalysisTaskIsAutomatic else { return }
    markdownAnalysisTask?.cancel()
    markdownAnalysisTask = nil
    markdownAnalysisTaskIsAutomatic = false
    markdownAnalysisGeneration &+= 1
  }

  func selectOutlineItem(_ item: MarkdownOutlineItem) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }

    let bodyLength = (editorBody as NSString).length
    selectedRange = NSRange(
      location: min(max(item.headingLocation, 0), bodyLength),
      length: 0
    )
    selectionActionMessage = ""
    focusMarkdownText(
      for: UUID(),
      selectedRange: selectedRange,
      message: "已平滑定位到「\(item.title)」。",
      isAnimated: true
    )
  }

  func performOutlineAction(
    _ action: MarkdownOutlineSectionAction,
    item: MarkdownOutlineItem
  ) {
    switch action {
    case .moveUp:
      applyOutlineEdit(
        outlineService.moveSectionEdit(in: editorBody, item: item, direction: .up),
        message: "已上移章节「\(item.title)」。"
      )
    case .moveDown:
      applyOutlineEdit(
        outlineService.moveSectionEdit(in: editorBody, item: item, direction: .down),
        message: "已下移章节「\(item.title)」。"
      )
    case .duplicate:
      applyOutlineEdit(
        outlineService.duplicateSectionEdit(in: editorBody, item: item),
        message: "已创建章节「\(item.title)」的副本。"
      )
    case .delete:
      applyOutlineEdit(
        outlineService.deleteSectionEdit(in: editorBody, item: item),
        message: "已删除章节「\(item.title)」，可撤销。"
      )
    case .copyAnchorLink:
      guard let anchorLink = outlineService.anchorLink(for: item, in: editorBody) else {
        selectionActionMessage = "章节已变化，请刷新大纲后重试。"
        return
      }
      ClipboardWriter.copy(
        anchorLink,
        successMessage: "已复制锚点链接：\(anchorLink)"
      ) { selectionActionMessage = $0 }
    }
  }

  func applyOutlineEdit(_ edit: MarkdownSmartEdit?, message: String) {
    guard let edit else {
      selectionActionMessage = "章节已变化，请刷新大纲后重试。"
      return
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    selectionActionMessage = message
  }

  func showFindReplace() {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    let selected = selectedText(in: editorBody).trimmedForPublishing
    if !selected.isEmpty, !selected.contains("\n") {
      findQuery = selected
    }
    isFindReplacePresented = true
    findReplaceMessage = findQuery.isEmpty ? "输入查找内容。" : ""
  }

  func findNext() {
    find(.next)
  }

  func findPrevious() {
    find(.previous)
  }

  func find(_ direction: MarkdownFindDirection) {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      EditorAccessibilityAnnouncementCenter.announceFindMessage(
        String(localized: "输入查找内容。")
      )
      return
    }

    do {
      if let errorMessage = findMatchSnapshot.errorMessage {
        throw MarkdownFindReplaceError.invalidRegularExpression(errorMessage)
      }
      guard let result = findMatchSnapshot.result(
        selectedRange: selectedRange,
        direction: direction
      ) else {
        findReplaceMessage = "没有找到匹配。"
        EditorAccessibilityAnnouncementCenter.announceFindMessage(
          String(localized: "没有找到匹配。")
        )
        return
      }

      selectedRange = result.range
      if result.didWrap {
        findReplaceMessage = direction == .next
          ? "已从开头继续查找。"
          : "已从末尾继续查找。"
      } else {
        findReplaceMessage = ""
      }
      EditorAccessibilityAnnouncementCenter.announceFindResult(
        result,
        direction: direction
      )
    } catch {
      findReplaceMessage = error.localizedDescription
      EditorAccessibilityAnnouncementCenter.announceFindMessage(
        error.localizedDescription,
        isError: true
      )
    }
  }

  func replaceCurrentOrNext() {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    do {
      let mutation = try findReplaceService.replaceCurrentOrNext(
        in: editorBody,
        query: findQuery,
        replacement: replacementText,
        selectedRange: selectedRange,
        options: findOptions
      )

      guard mutation.replacementCount > 0 else {
        findReplaceMessage = "没有找到可替换内容。"
        return
      }

      applyFindReplaceMutation(mutation)
      findReplaceMessage = "已替换 1 处。"
    } catch {
      findReplaceMessage = error.localizedDescription
    }
  }

  func replaceAll() {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    do {
      let mutation = try findReplaceService.replaceAll(
        in: editorBody,
        query: findQuery,
        replacement: replacementText,
        options: findOptions
      )

      guard mutation.replacementCount > 0 else {
        findReplaceMessage = "没有找到可替换内容。"
        return
      }

      applyFindReplaceMutation(mutation)
      findReplaceMessage = "已替换 \(mutation.replacementCount) 处，可撤销。"
    } catch {
      findReplaceMessage = error.localizedDescription
    }
  }

  func applyFindReplaceMutation(_ mutation: MarkdownFindReplaceMutation) {
    if let edit = mutation.edit {
      editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
      return
    }

    var updated = previewDraft
    updated.bodyMarkdown = mutation.text
    requestUndoableBodyUpdate(updated)
    selectedRange = mutation.selectedRange
  }

  func replacingSelection(in draft: ArticleDraft, with markdown: String) -> ArticleDraft {
    let mutation = selectionEditingService.replacingSelection(
      in: draft,
      selectedRange: selectedRange,
      with: markdown
    )
    selectedRange = mutation.selectedRange
    return mutation.draft
  }

  func replacingRawSelection(in draft: ArticleDraft, with text: String) -> ArticleDraft {
    let mutation = selectionEditingService.replacingRawSelection(
      in: draft,
      selectedRange: selectedRange,
      with: text
    )
    selectedRange = mutation.selectedRange
    return mutation.draft
  }

  func applyMarkdownFormatting(_ command: MarkdownFormattingCommand) {
    guard requireBodyEditingContext() else { return }
    guard !MarkdownFormattingResponderBridge.perform(command) else { return }
    let service = MarkdownFormattingService()
    guard let edit = service.edit(
      in: editorBody,
      selectedRange: selectedRange,
      command: command
    ) else { return }

    var updated = previewDraft
    updated.bodyMarkdown = (editorBody as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
    selectedRange = edit.selectedRange
    requestUndoableBodyUpdate(updated)
  }

  func applyAdvancedMarkdownFormatting(
    _ command: MarkdownAdvancedFormattingCommand
  ) {
    guard requireBodyEditingContext() else { return }
    guard
      let edit = MarkdownAdvancedEditingService().formattingEdit(
        in: editorBody,
        selectedRange: selectedRange,
        command: command
      )
    else {
      return
    }
    applyAdvancedMarkdownEdit(edit)
  }

  func applyMarkdownLineEditing(_ command: MarkdownLineEditingCommand) {
    guard requireBodyEditingContext() else { return }
    guard
      let edit = MarkdownAdvancedEditingService().lineEdit(
        in: editorBody,
        selectedRange: selectedRange,
        command: command
      )
    else {
      selectionActionMessage = "当前选区不能执行这项行操作。"
      return
    }
    applyAdvancedMarkdownEdit(edit)
  }

  private func applyAdvancedMarkdownEdit(_ edit: MarkdownSmartEdit) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    selectedRange = edit.selectedRange
    editorEditRequest = MarkdownTextEditRequest(
      expectedText: editorBody,
      edit: edit
    )
  }

  func wrapSelection(prefix: String, suffix: String, placeholder: String) {
    guard requireBodyEditingContext() else { return }
    let mutation = selectionEditingService.wrappingSelection(
      in: previewDraft,
      selectedRange: selectedRange,
      prefix: prefix,
      suffix: suffix,
      placeholder: placeholder
    )
    selectedRange = mutation.selectedRange
    _ = requestUndoableBodyUpdate(mutation.draft)
  }

  func prefixCurrentLine(_ prefix: String) {
    guard requireBodyEditingContext() else { return }
    replaceCurrentLines { line in
      line.hasPrefix(prefix) ? line : prefix + line
    }
  }

  func replaceCurrentLines(_ transform: (String) -> String) {
    let mutation = selectionEditingService.replacingCurrentLines(
      in: previewDraft,
      selectedRange: selectedRange,
      transform: transform
    )
    selectedRange = mutation.selectedRange
    _ = requestUndoableBodyUpdate(mutation.draft)
  }

  func insertCodeBlock() {
    guard requireBodyEditingContext() else { return }
    let selected = selectedText(in: editorBody).trimmedForPublishing
    let body = selected.isEmpty ? "code" : selected
    requestUndoableBodyUpdate(
      replacingSelection(in: previewDraft, with: "```\n\(body)\n```")
    )
  }

  func insertTable() {
    guard requireBodyEditingContext() else { return }
    let table = """
    | 列 1 | 列 2 |
    | --- | --- |
    | 内容 | 内容 |
    """
    let source = editorBody as NSString
    let insertionRange = editingRange(in: source)
    let updated = replacingSelection(in: previewDraft, with: table)

    let updatedSource = updated.bodyMarkdown as NSString
    let searchStart = min(insertionRange.location, updatedSource.length)
    let searchRange = NSRange(
      location: searchStart,
      length: min(
        updatedSource.length - searchStart,
        (table as NSString).length + 2
      )
    )
    let insertedTableRange = updatedSource.range(of: table, options: [], range: searchRange)
    if insertedTableRange.location != NSNotFound {
      let firstHeaderRange = updatedSource.range(
        of: "列 1",
        options: [],
        range: insertedTableRange
      )
      if firstHeaderRange.location != NSNotFound {
        selectedRange = firstHeaderRange
      }
    }
    _ = requestUndoableBodyUpdate(updated)
  }

  func insertHorizontalRule() {
    guard requireBodyEditingContext() else { return }
    requestUndoableBodyUpdate(replacingSelection(in: previewDraft, with: "---"))
  }

  func insertInternalLink(_ suggestion: MarkdownInternalLinkSuggestion) {
    guard requireBodyEditingContext() else { return }
    let markdown = MarkdownInternalLinkService.markdownLink(
      to: suggestion,
      selectedText: selectedText(in: editorBody)
    )
    guard requestUndoableBodyUpdate(
      replacingRawSelection(in: previewDraft, with: markdown)
    ) else { return }
    selectionActionMessage = "已插入站内链接：\(suggestion.title)"
  }

  func insertSnippet(_ snippet: MarkdownSnippet) {
    guard requireBodyEditingContext() else { return }
    let markdown = MarkdownSnippetLibraryService.expandedMarkdown(for: snippet, draft: previewDraft)
    guard requestUndoableBodyUpdate(
      replacingSelection(in: previewDraft, with: markdown)
    ) else { return }
    let kindName = snippet.kind == .articleTemplate ? "文章模板" : "正文片段"
    selectionActionMessage = "已插入\(kindName)：\(snippet.title)"
  }

  @discardableResult
  func requireBodyEditingContext() -> Bool {
    guard isFrontMatterSelection else { return true }
    let message = String(localized: "请先将光标移到 Markdown 正文。")
    selectionActionMessage = message
    EditorAccessibilityAnnouncementCenter.announce(message, priority: .high)
    NSSound.beep()
    return false
  }

  func selectDiagnostic(_ diagnostic: MarkdownInlineDiagnostic) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    selectedRange = clamped(diagnostic.range, length: (editorBody as NSString).length)
    EditorAccessibilityAnnouncementCenter.announce(
      "已定位：\(diagnostic.title)",
      priority: .high
    )
  }

  func applyDiagnosticQuickFix(_ diagnostic: MarkdownInlineDiagnostic) {
    guard let edit = MarkdownInlineDiagnosticService.quickFix(for: diagnostic, in: editorBody) else {
      selectionActionMessage = "这项诊断没有可自动应用的修复。"
      return
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    selectionActionMessage = "已修复：\(diagnostic.title)"
  }

  func selectedText(in text: String) -> String {
    selectionEditingService.selectedText(in: text, selectedRange: selectedRange)
  }

  func editingRange(in source: NSString) -> NSRange {
    selectionEditingService.editingRange(in: source, selectedRange: selectedRange)
  }

  func syncActiveEditorSelection() {
    guard !isFrontMatterSelection else {
      store.clearActiveEditorSelection(for: draft.id)
      return
    }
    let source = editorBody as NSString
    let range = clamped(selectedRange, length: source.length)
    let selectedText = range.length > 0 ? source.substring(with: range) : ""
    store.updateActiveEditorSelection(
      draftID: draft.id,
      selectedRange: range,
      selectedText: selectedText,
      bodyUTF16Count: source.length
    )
  }

  func clamped(_ range: NSRange, length: Int) -> NSRange {
    selectionEditingService.clamped(range, length: length)
  }

  func formatChineseTypography() {
    guard requireBodyEditingContext() else { return }
    let service = ChineseTypographyFormattingService()
    let edit = service.formattingEdit(in: editorBody, selectedRange: selectedRange)
    guard let edit else {
      selectionActionMessage = "当前正文排版已符合规范。"
      return
    }
    applyAdvancedMarkdownEdit(edit)
    selectionActionMessage = "已完成中英文排版规范化（盘古间距）。"
    EditorAccessibilityAnnouncementCenter.announce("已完成中英文排版规范化。")
  }

  func copyForWeChatAndZhihu() {
    let success = WeChatRichTextCopyService.copyToPasteboard(
      markdown: editorBody,
      title: draft.title
    )
    if success {
      selectionActionMessage = "已复制微信公众号/知乎排版富文本，可直接粘贴！"
      EditorAccessibilityAnnouncementCenter.announce("已复制微信公众号与知乎排版格式到剪贴板。")
    } else {
      selectionActionMessage = "富文本复制失败，请重试。"
    }
  }
}
