import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  @State private var selectedRange = NSRange(location: 0, length: 0)
  @State private var activeSelectionAIAction: AIPublishingActionKind?
  @State private var isFindReplacePresented = false
  @State private var findQuery = ""
  @State private var replacementText = ""
  @State private var isFindCaseSensitive = false
  @State private var findReplaceMessage = ""
  @State private var selectionActionMessage = ""
  @State private var selectionEditPreview: AIPublishingSelectionEditPreview?
  @State private var isShortcutHelpPresented = false
  @State private var isRevisionHistoryPresented = false
  @State private var revisionHistory: [MarkdownEditorRevisionSnapshot] = []
  @State private var revisionCursor = -1
  @State private var isRestoringRevision = false
  private let findReplaceService = MarkdownFindReplaceService()
  private let maxRevisionHistoryCount = 120

  var body: some View {
    VStack(spacing: 0) {
      MacMarkdownEditorToolbar(
        title: $draft.title,
        markdownPath: store.profile(for: draft).markdownPath(for: draft),
        lastSaveStatus: store.lastSaveStatus,
        hasUnsavedChanges: store.hasUnsavedChanges,
        editorDisplayMode: store.editorDisplayMode,
        isSelectionAIActionRunning: isSelectionAIActionRunning,
        onSetEditorDisplayMode: { store.setEditorDisplayMode($0) },
        onShowFindReplace: showFindReplace,
        onShowShortcutHelp: {
          isShortcutHelpPresented = true
        },
        onShowRevisionHistory: {
          isRevisionHistoryPresented = true
        },
        onOpenAIContextInspector: showAIContextInspector,
        writingAIActionMenuItems: writingAIActionMenuItems,
        publishingAIActionMenuItems: publishingAIActionMenuItems,
        distributionAIActionMenuItems: distributionAIActionMenuItems,
        maintenanceAIActionMenuItems: maintenanceAIActionMenuItems,
        additionalSelectionAIActionMenuItems: additionalSelectionAIActionMenuItems,
        selectionAIActionAvailability: { kind in
          selectionAIActionAvailability(kind)
        },
        articleAIActionAvailability: { kind in
          articleAIActionAvailability(kind)
        },
        onPerformSelectionAIAction: performSelectionAIAction,
        onPerformArticleAIAction: performArticleAIAction,
        onPasteAIPromptToClipboard: pasteAIPromptToClipboard,
        onRewriteSelection: rewriteSelectedText
      )
      Divider()
      if isFindReplacePresented {
        FindReplaceBar(
          findQuery: $findQuery,
          replacementText: $replacementText,
          isFindCaseSensitive: $isFindCaseSensitive,
          canUseFindReplace: canUseFindReplace,
          findReplaceMessage: findReplaceMessage,
          onFindNext: findNext,
          onReplaceCurrentOrNext: replaceCurrentOrNext,
          onReplaceAll: replaceAll,
          onDismiss: {
            isFindReplacePresented = false
          }
        )
        Divider()
      }
      ZStack(alignment: .top) {
        editorSurface
        if canShowSelectionActions {
          SelectionActionBar(
            selectionAIActionMenuItems: selectionAIActionMenuItems,
            isSelectionAIActionRunning: isSelectionAIActionRunning,
            activeSelectionActionName: activeSelectionAIAction?.displayName,
            hasLatestAssistantMessage: latestAssistantMessageForCurrentDraft != nil,
            selectionActionMessage: selectionActionMessage,
            onSelectSelectionAction: performSelectionAIAction,
            onApplyLatestAIReply: applyLatestAIReplyToSelection,
            onInsertImages: {
              insertImageReferences(ImageSelectionPanel.chooseImages())
            },
            onCheckSelectedPublicRisk: checkSelectedPublicRisk,
            availabilityForSelectionAction: { kind in
              selectionAIActionAvailability(kind)
            }
          )
            .padding(.top, 10)
            .zIndex(1)
        }
        if let selectionEditPreview {
          SelectionEditPreviewPanel(
            preview: selectionEditPreview,
            onApply: applySelectionEditPreview,
            onDiscard: discardSelectionEditPreview
          )
            .padding(.top, hasSelectedText ? 58 : 10)
            .zIndex(2)
        }
      }
    }
    .focusedSceneValue(\.markdownEditorCommandActions, commandActions)
    .onAppear {
      setupRevisionHistory()
      syncActiveEditorSelection()
    }
    .onChange(of: store.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { _, _ in
      syncActiveEditorSelection()
    }
    .onChange(of: draft.bodyMarkdown) { _, _ in
      syncActiveEditorSelection()
      appendRevisionIfNeeded()
    }
    .onChange(of: draft.id) { _, _ in
      syncActiveEditorSelection()
      setupRevisionHistory()
    }
    .sheet(isPresented: $isShortcutHelpPresented) {
      MarkdownShortcutHelpPanel()
    }
    .sheet(isPresented: $isRevisionHistoryPresented) {
      MarkdownRevisionHistoryPanel(
        revisions: revisionHistory,
        currentIndex: revisionCursor,
        onRestore: { index in
          restoreRevision(at: index)
          if index >= 0, index < revisionHistory.count {
            let revision = revisionHistory[index]
            let indexText = "#\(revisionHistory.count - index)"
            selectionActionMessage = "已恢复到会话快照 \(indexText)（\(revision.label ?? "会话快照")）。"
          } else {
            selectionActionMessage = "已恢复到会话快照。"
          }
          isRevisionHistoryPresented = false
        },
        onResetToCurrent: {
          resetRevisionHistoryToCurrent()
          isRevisionHistoryPresented = false
        }
      )
    }
    .onDisappear {
      store.clearActiveEditorSelection(for: draft.id)
    }
  }

  private var editorSurface: some View {
    Group {
      switch store.editorDisplayMode {
      case .edit:
        markdownEditor
      case .preview:
        MarkdownPreviewPane(draft: draft, profile: store.profile(for: draft))
      case .split:
        HSplitView {
          markdownEditor
            .frame(minWidth: 320)
          MarkdownPreviewPane(draft: draft, profile: store.profile(for: draft))
            .frame(minWidth: 320)
        }
      }
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var markdownEditor: some View {
    VStack(spacing: 0) {
      MacMarkdownFormattingToolbar(
        characterCount: characterCount,
        wordCount: wordCount,
        lineCount: lineCount,
        readingMinutes: readingMinutes,
        onApplyHeading: applyHeading,
        onWrapSelection: { prefix, suffix, placeholder in
          wrapSelection(prefix: prefix, suffix: suffix, placeholder: placeholder)
        },
        onPrefixCurrentLine: prefixCurrentLine,
        onInsertCodeBlock: insertCodeBlock,
        onInsertTable: insertTable,
        onInsertHorizontalRule: insertHorizontalRule,
        onInsertLink: insertLink,
        onInsertImage: {
          insertImageReferences(ImageSelectionPanel.chooseImages())
        }
      )
      Divider()

      ZStack {
        Color(nsColor: .textBackgroundColor)

        MacMarkdownTextView(
          text: $draft.bodyMarkdown,
          selectedRange: $selectedRange
        ) { urls in
          insertImageReferences(urls)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if draft.bodyMarkdown.trimmedForPublishing.isEmpty {
          Text("Markdown 正文")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
      .padding(14)
  }

  private var canShowSelectionActions: Bool {
    SelectionActionBarPresentation.shouldShow(
      hasSelectedText: hasSelectedText,
      isSelectionAIActionRunning: isSelectionAIActionRunning,
      selectionActionMessage: selectionActionMessage
    )
  }

  private var characterCount: Int {
    (draft.bodyMarkdown as NSString).length
  }

  private var wordCount: Int {
    let sanitized = draft.bodyMarkdown
      .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
      .filter { !$0.isEmpty }
    return sanitized.count
  }

  private var lineCount: Int {
    let trimmed = draft.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? 0 : draft.bodyMarkdown.components(separatedBy: "\n").count
  }

  private var readingMinutes: Int {
    guard wordCount > 0 else { return 0 }
    return Int(ceil(Double(wordCount) / 250.0))
  }

  private var canUndoRevision: Bool {
    revisionCursor > 0
  }

  private var canRedoRevision: Bool {
    revisionCursor >= 0 && revisionCursor < revisionHistory.count - 1
  }

  private func setupRevisionHistory() {
    let selection = clamped(selectedRange, length: (draft.bodyMarkdown as NSString).length)
    selectedRange = selection
    revisionHistory.removeAll()
    revisionHistory.append(currentRevisionSnapshot(label: "本次会话初始快照"))
    revisionCursor = 0
    isRestoringRevision = false
  }

  private func appendRevisionIfNeeded() {
    if isRestoringRevision {
      isRestoringRevision = false
      return
    }

    let latest = currentRevisionSnapshot(label: nil)
    if revisionHistory.last?.body == latest.body {
      return
    }

    if revisionCursor < revisionHistory.count - 1 {
      revisionHistory = Array(revisionHistory.prefix(revisionCursor + 1))
    }

    revisionHistory.append(latest)
    revisionCursor = revisionHistory.count - 1

    if revisionHistory.count > maxRevisionHistoryCount {
      let removeCount = revisionHistory.count - maxRevisionHistoryCount
      revisionHistory.removeFirst(removeCount)
      revisionCursor -= removeCount
      if revisionCursor < 0 {
        revisionCursor = 0
      }
    }
  }

  private func currentRevisionSnapshot(label: String?) -> MarkdownEditorRevisionSnapshot {
    MarkdownEditorRevisionSnapshot(
      id: UUID(),
      createdAt: Date(),
      label: label,
      body: draft.bodyMarkdown,
      selectedRange: selectedRange,
      characterCount: characterCount,
      wordCount: wordCount,
      lineCount: lineCount
    )
  }

  private func undoRevision() {
    guard canUndoRevision else {
      return
    }
    applyRevision(at: revisionCursor - 1)
  }

  private func redoRevision() {
    guard canRedoRevision else {
      return
    }
    applyRevision(at: revisionCursor + 1)
  }

  private func restoreRevision(at index: Int) {
    guard index >= 0, index < revisionHistory.count else {
      return
    }

    isRestoringRevision = true
    let snapshot = revisionHistory[index]
    var restored = draft
    restored.bodyMarkdown = snapshot.body
    let clampedRange = clamped(snapshot.selectedRange, length: (snapshot.body as NSString).length)
    selectedRange = clampedRange
    draft = restored
    revisionCursor = index
  }

  private func applyRevision(at index: Int) {
    let currentCursor = revisionCursor
    restoreRevision(at: index)
    let direction = index < currentCursor ? "回退" : (index > currentCursor ? "前进" : "")
    if direction.isEmpty {
      selectionActionMessage = "已恢复到当前会话快照。"
    } else {
      selectionActionMessage = "已\(direction)会话快照。"
    }
  }

  private func resetRevisionHistoryToCurrent() {
    guard revisionHistory.indices.contains(revisionCursor) else {
      setupRevisionHistory()
      return
    }

    let current = revisionHistory[revisionCursor]
    revisionHistory.removeAll()
    revisionHistory.append(current)
    revisionCursor = 0
    selectionActionMessage = "会话历史已清空，仅保留当前内存快照。"
  }

  private var hasSelectedText: Bool {
    !selectedText(in: draft.bodyMarkdown).trimmedForPublishing.isEmpty
  }

  private var latestAssistantMessageForCurrentDraft: AIPublishingChatMessage? {
    guard store.ai.chatDraftID == draft.id else {
      return nil
    }
    return store.ai.chatMessages.last { $0.role == .assistant }
  }

  private var isSelectionAIActionRunning: Bool {
    activeSelectionAIAction != nil || store.ai.isActionRunning
  }

  private var isAIEnabledForDraft: Bool {
    let profile = store.publishing.profile(for: draft)
    return !profile.aiProviderConfig.requiresAPIKey || store.ai.tokenAvailability.hasToken
  }

  private func articleAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      draft: draft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  private func selectionAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      selectedText: selectedText(in: draft.bodyMarkdown),
      draft: draft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  private func activeAIActionForAvailability(fallback kind: AIPublishingActionKind) -> AIPublishingActionKind? {
    activeSelectionAIAction ?? (store.ai.isActionRunning ? kind : nil)
  }

  private var selectionAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.selectionActions
  }

  private var writingAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.writingActions
  }

  private var publishingAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.publishingActions
  }

  private var distributionAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.distributionActions
  }

  private var maintenanceAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.maintenanceActions
  }

  private var additionalSelectionAIActionMenuItems: [AIPublishingActionMenuItem] {
    selectionAIActionMenuItems.filter { $0.kind != .rewriteSelection }
  }

  private func insertImageReferences(_ urls: [URL]) {
    let imageURLs = urls.filter(ImageFileSupport.isSupportedImageURL)
    guard !imageURLs.isEmpty else { return }

    var updated = draft
    var markdownBlocks: [String] = []
    for url in imageURLs {
      let selectedAlt = selectedText(in: updated.bodyMarkdown).trimmedForPublishing
      var attachment = store.makeAttachment(from: url, draft: updated)
      if !selectedAlt.isEmpty {
        attachment.altText = selectedAlt
      }
      updated.attachments.append(attachment)
      markdownBlocks.append("![\(attachment.altText)](\(attachment.relativePublishPath))")
    }

    draft = replacingSelection(in: updated, with: markdownBlocks.joined(separator: "\n"))
    store.refreshImageWorkbenchReport()
  }

  private var commandActions: MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draft.id,
      canRewriteSelection: !selectedText(in: draft.bodyMarkdown).trimmedForPublishing.isEmpty,
      canUseFindReplace: canUseFindReplace,
      canUndoRevision: canUndoRevision,
      canRedoRevision: canRedoRevision,
      showFindReplace: showFindReplace,
      showKeyboardShortcuts: {
        isShortcutHelpPresented = true
      },
      showRevisionHistory: {
        isRevisionHistoryPresented = true
      },
      findNext: findNext,
      replaceCurrentOrNext: replaceCurrentOrNext,
      replaceAll: replaceAll,
      insertImages: {
        insertImageReferences(ImageSelectionPanel.chooseImages())
      },
      undoRevision: undoRevision,
      redoRevision: redoRevision,
      runPreflight: runPreflightForCurrentDraft,
      rewriteSelection: rewriteSelectedText,
      openAIAssistant: showAIContextInspector,
      copyAIPrompt: pasteAIPromptToClipboard
    )
  }

  private var canUseFindReplace: Bool {
    !findQuery.isEmpty
  }

  private func showFindReplace() {
    let selected = selectedText(in: draft.bodyMarkdown).trimmedForPublishing
    if !selected.isEmpty, !selected.contains("\n") {
      findQuery = selected
    }
    isFindReplacePresented = true
    findReplaceMessage = findQuery.isEmpty ? "输入查找内容。" : ""
  }

  private func findNext() {
    isFindReplacePresented = true
    guard canUseFindReplace else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    guard let result = findReplaceService.findNext(
      in: draft.bodyMarkdown,
      query: findQuery,
      selectedRange: selectedRange,
      caseSensitive: isFindCaseSensitive
    ) else {
      findReplaceMessage = "没有找到匹配。"
      return
    }

    selectedRange = result.range
    findReplaceMessage = result.didWrap ? "已从开头继续查找。" : "已找到匹配。"
  }

  private func replaceCurrentOrNext() {
    isFindReplacePresented = true
    guard canUseFindReplace else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    let mutation = findReplaceService.replaceCurrentOrNext(
      in: draft.bodyMarkdown,
      query: findQuery,
      replacement: replacementText,
      selectedRange: selectedRange,
      caseSensitive: isFindCaseSensitive
    )

    guard mutation.replacementCount > 0 else {
      findReplaceMessage = "没有找到可替换内容。"
      return
    }

    var updated = draft
    updated.bodyMarkdown = mutation.text
    draft = updated
    selectedRange = mutation.selectedRange
    findReplaceMessage = "已替换 1 处。"
  }

  private func replaceAll() {
    isFindReplacePresented = true
    guard canUseFindReplace else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    let mutation = findReplaceService.replaceAll(
      in: draft.bodyMarkdown,
      query: findQuery,
      replacement: replacementText,
      caseSensitive: isFindCaseSensitive
    )

    guard mutation.replacementCount > 0 else {
      findReplaceMessage = "没有找到可替换内容。"
      return
    }

    var updated = draft
    updated.bodyMarkdown = mutation.text
    draft = updated
    selectedRange = mutation.selectedRange
    findReplaceMessage = "已替换 \(mutation.replacementCount) 处。"
  }

  private func replacingSelection(in draft: ArticleDraft, with markdown: String) -> ArticleDraft {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let needsLeadingBreak = range.location > 0 && !source.substring(to: range.location).hasSuffix("\n")
    let needsTrailingBreak = range.location + range.length < source.length
      && !source.substring(from: range.location + range.length).hasPrefix("\n")
    let insertion = "\(needsLeadingBreak ? "\n" : "")\(markdown)\(needsTrailingBreak ? "\n" : "")"
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: insertion)
    selectedRange = NSRange(location: range.location + (insertion as NSString).length, length: 0)
    return updated
  }

  private func replacingRawSelection(in draft: ArticleDraft, with text: String) -> ArticleDraft {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: text)
    selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
    return updated
  }

  private func applyHeading(level: Int) {
    let marker = String(repeating: "#", count: min(max(level, 1), 6))
    replaceCurrentLines { line in
      let stripped = line.replacingOccurrences(
        of: #"^#{1,6}\s+"#,
        with: "",
        options: .regularExpression
      )
      return "\(marker) \(stripped.nilIfEmpty ?? "标题")"
    }
  }

  private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let selected = range.length > 0 ? source.substring(with: range) : placeholder
    let replacement = prefix + selected + suffix

    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    draft = updated

    let prefixLength = (prefix as NSString).length
    selectedRange = NSRange(location: range.location + prefixLength, length: (selected as NSString).length)
  }

  private func prefixCurrentLine(_ prefix: String) {
    replaceCurrentLines { line in
      line.hasPrefix(prefix) ? line : prefix + line
    }
  }

  private func replaceCurrentLines(_ transform: (String) -> String) {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let effectiveRange = NSRange(location: range.location, length: max(range.length, 0))
    let lineRange = source.lineRange(for: effectiveRange)
    let lineText = source.substring(with: lineRange)
    let lines = lineText.components(separatedBy: "\n")
    let transformed = lines.enumerated().map { index, line in
      if index == lines.count - 1, line.isEmpty {
        return line
      }
      return transform(line)
    }
    .joined(separator: "\n")

    updated.bodyMarkdown = source.replacingCharacters(in: lineRange, with: transformed)
    draft = updated
    selectedRange = NSRange(
      location: min(range.location, (updated.bodyMarkdown as NSString).length),
      length: range.length
    )
  }

  private func insertCodeBlock() {
    let selected = selectedText(in: draft.bodyMarkdown).trimmedForPublishing
    let body = selected.isEmpty ? "code" : selected
    draft = replacingSelection(in: draft, with: "```\n\(body)\n```")
  }

  private func insertTable() {
    let table = """
    | 列 1 | 列 2 |
    | --- | --- |
    | 内容 | 内容 |
    """
    draft = replacingSelection(in: draft, with: table)
  }

  private func insertHorizontalRule() {
    draft = replacingSelection(in: draft, with: "---")
  }

  private func insertLink() {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let selected = range.length > 0 ? source.substring(with: range) : "链接文本"
    let url = "https://"
    let replacement = "[\(selected)](\(url))"

    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    draft = updated

    let urlLocation = range.location
      + ("[\(selected)](" as NSString).length
    selectedRange = NSRange(location: urlLocation, length: (url as NSString).length)
  }

  private func selectedText(in text: String) -> String {
    let source = text as NSString
    let range = clamped(selectedRange, length: source.length)
    guard range.length > 0 else { return "" }
    return source.substring(with: range)
  }

  private func moveSelectionToDocumentEndIfNeeded() {
    let bodyLength = (draft.bodyMarkdown as NSString).length
    if selectedRange.location > bodyLength || selectedRange.length > 0 {
      selectedRange = NSRange(location: bodyLength, length: 0)
    }
  }

  private func editingRange(in source: NSString) -> NSRange {
    let range = clamped(selectedRange, length: source.length)
    if range.length > 0 {
      return range
    }
    return NSRange(location: source.length, length: 0)
  }

  private func syncActiveEditorSelection() {
    let source = draft.bodyMarkdown as NSString
    let range = clamped(selectedRange, length: source.length)
    let selectedText = range.length > 0 ? source.substring(with: range) : ""
    store.updateActiveEditorSelection(
      draftID: draft.id,
      selectedRange: range,
      selectedText: selectedText,
      bodyUTF16Count: source.length
    )
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private func pasteAIPromptToClipboard() {
    ClipboardWriter.copy(
      store.publishingAIPrompt(for: draft),
      successMessage: "已复制 AI Prompt。"
    ) { store.setPublishActionMessage($0) }
  }

  private func applyEditorFocusRequest() {
    guard let request = store.editorFocusRequest, request.draftID == draft.id else {
      return
    }

    guard request.field == nil || request.field == "body" else {
      selectionActionMessage = "问题在 \(request.field ?? "元数据") 字段，右侧可直接处理。"
      return
    }

    let text = draft.bodyMarkdown as NSString
    if let query = request.query?.trimmedForPublishing, !query.isEmpty {
      let range = text.range(of: query, options: [.caseInsensitive])
      if range.location != NSNotFound {
        selectedRange = range
        selectionActionMessage = "已定位到正文匹配内容。"
        return
      }
    }

    selectedRange = NSRange(location: 0, length: 0)
    selectionActionMessage = "已定位到正文。"
  }

  private func runPreflightForCurrentDraft() {
    store.focusDraft(draft.id, section: .contentHealth)
  }

  private func rewriteSelectedText() {
    performSelectionAIAction(.rewriteSelection)
  }

  private func performSelectionAIAction(_ kind: AIPublishingActionKind) {
    let rawSelectedText = selectedText(in: draft.bodyMarkdown)
    let promptSelectedText = rawSelectedText.trimmedForPublishing
    let availability = selectionAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.displayName)：\(availability.unavailableReason ?? "需要更多上下文")"
      return
    }

    activeSelectionAIAction = kind
    selectionActionMessage = "\(kind.displayName)处理中..."
    let previewRange = clamped(selectedRange, length: (draft.bodyMarkdown as NSString).length)
    selectionEditPreview = nil
    Task {
      let result = await store.ai.performAction(kind, draft: draft, selectedText: promptSelectedText)
      await MainActor.run {
        if let result {
          selectionEditPreview = AIPublishingSelectionEditPreview(
            kind: result.kind,
            range: previewRange,
            originalText: rawSelectedText,
            replacementText: result.content,
            application: selectionEditApplication(for: result.kind),
            providerName: result.providerName,
            model: result.model
          )
          selectionActionMessage = result.kind.displayName + "预览已生成。"
        } else {
          selectionActionMessage = kind.displayName + "失败。"
        }
        activeSelectionAIAction = nil
      }
    }
  }

  private func performArticleAIAction(_ kind: AIPublishingActionKind) {
    let availability = articleAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.displayName)：\(availability.unavailableReason ?? "需要更多文章内容")"
      return
    }

    activeSelectionAIAction = kind
    selectionActionMessage = "\(kind.displayName)处理中..."
    let previewRange = articleInsertionRange(for: kind)
    selectionEditPreview = nil
    Task {
      let result = await store.ai.performAction(kind, draft: draft)
      await MainActor.run {
        if let result {
          if result.kind.producesMetadataSuggestion, store.ai.metadataSuggestion != nil {
            selectionActionMessage = result.kind.displayName + "已生成，可在元数据建议中应用。"
          } else {
            selectionEditPreview = AIPublishingSelectionEditPreview(
              kind: result.kind,
              range: previewRange,
              originalText: "",
              replacementText: result.content,
              application: .insertAtRange,
              providerName: result.providerName,
              model: result.model
            )
            selectionActionMessage = result.kind.displayName + "预览已生成。"
          }
        } else {
          selectionActionMessage = kind.displayName + "失败。"
        }
        activeSelectionAIAction = nil
      }
    }
  }

  private func articleInsertionRange(for kind: AIPublishingActionKind) -> NSRange {
    let bodyLength = (draft.bodyMarkdown as NSString).length
    switch kind {
    case .continueArticle, .draftArticleFAQ, .draftTroubleshootingSection, .draftReferencesSection:
      return NSRange(location: bodyLength, length: 0)
    case .draftOpening, .draftArticleTLDR:
      return NSRange(location: 0, length: 0)
    default:
      let location = min(max(selectedRange.location, 0), bodyLength)
      return NSRange(location: location, length: 0)
    }
  }

  private func selectionEditApplication(for kind: AIPublishingActionKind) -> AIPublishingSelectionEditApplication {
    switch kind {
    case .continueAfterSelection, .explainSelection:
      return .insertAfterRange
    default:
      return .replaceRange
    }
  }

  private func checkSelectedPublicRisk() {
    let selectedText = selectedText(in: draft.bodyMarkdown).trimmedForPublishing
    guard !selectedText.isEmpty else {
      return
    }

    var probeDraft = draft
    probeDraft.bodyMarkdown = selectedText
    let summary = PublicRiskSummary(issues: PublicRiskScanner().scan(draft: probeDraft))
    let content: String
    if summary.isClear {
      content = "选中文本未命中密钥、私钥、内网地址或本机路径规则。"
      selectionActionMessage = "选区未发现公开风险。"
    } else {
      let issueLines = summary.issues.map {
        "- \($0.severity.displayName)：\($0.title) - \($0.message)"
      }
      content = "选中文本公开风险：\n\(issueLines.joined(separator: "\n"))"
      selectionActionMessage = "选区有 \(summary.issueCount) 项公开风险。"
    }
    store.ai.setActionResult(AIPublishingActionResult(kind: .privacyReview, content: content))
    store.ai.setActionMessage(selectionActionMessage)
  }

  private func applyLatestAIReplyToSelection() {
    guard let message = latestAssistantMessageForCurrentDraft else {
      selectionActionMessage = "当前文章还没有可应用的 AI 回复。"
      return
    }

    let range = clamped(selectedRange, length: (draft.bodyMarkdown as NSString).length)
    guard range.length > 0 else {
      selectionActionMessage = "请先选择要替换的正文。"
      return
    }

    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: draft,
      mode: .replaceSelection,
      selectionRange: range
    ) else {
      selectionActionMessage = "AI 回复为空或选区无效。"
      return
    }

    let replacementLength = (message.content.trimmedForPublishing as NSString).length
    draft = result.draft
    selectedRange = NSRange(location: range.location + replacementLength, length: 0)
    selectionActionMessage = result.action.statusMessage
  }

  private func showAIContextInspector() {
    store.ai.openChatWorkspace(for: draft.id)
  }

  private func applySelectionEditPreview(_ preview: AIPublishingSelectionEditPreview) {
    do {
      let originalLength = (draft.bodyMarkdown as NSString).length
      let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)
      let updatedLength = (updated.bodyMarkdown as NSString).length
      let insertedLength = max(0, updatedLength - originalLength)
      let newSelectionLocation: Int
      switch preview.application {
      case .replaceRange:
        newSelectionLocation = preview.range.location + (preview.trimmedReplacementText as NSString).length
      case .insertAfterRange:
        newSelectionLocation = preview.range.location + preview.range.length + insertedLength
      case .insertAtRange:
        newSelectionLocation = preview.range.location + insertedLength
      }
      draft = updated
      selectedRange = NSRange(location: newSelectionLocation, length: 0)
      selectionEditPreview = nil
      selectionActionMessage = "\(preview.kind.displayName)已应用。"
    } catch {
      selectionActionMessage = error.localizedDescription
    }
  }

  private func discardSelectionEditPreview() {
    selectionEditPreview = nil
    selectionActionMessage = "已丢弃 AI 预览。"
  }
}
