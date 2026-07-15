import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  @ObservedObject private var publishingState: WorkbenchPublishingFeatureFacade
  @ObservedObject private var aiState: WorkbenchAIFeatureFacade
  @ObservedObject private var persistenceState: WorkbenchPersistenceFeatureFacade
  @State private var editorBody: String
  @State private var editorStatistics = MarkdownEditorStatistics.empty
  @State private var selectedRange = NSRange(location: 0, length: 0)
  @State private var isImageDropTargeted = false
  @State private var activeSelectionAIAction: AIPublishingActionKind?
  @State private var isFindReplacePresented = false
  @State private var findQuery = ""
  @State private var replacementText = ""
  @State private var isFindCaseSensitive = false
  @State private var findReplaceMessage = ""
  @State private var selectionActionMessage = ""
  @State private var selectionEditPreview: AIPublishingSelectionEditPreview?
  @State private var isShortcutHelpPresented = false
  @State private var editorBodyRevision: UInt64
  private let findReplaceService = MarkdownFindReplaceService()

  init(draft: Binding<ArticleDraft>, store: WorkbenchStore) {
    _draft = draft
    let buffer = store.draftBodyEditorBuffer(for: draft.wrappedValue.id)
    _editorBody = State(initialValue: buffer.bodyMarkdown)
    _editorBodyRevision = State(initialValue: buffer.revision)
    self.store = store
    _publishingState = ObservedObject(wrappedValue: store.publishing)
    _aiState = ObservedObject(wrappedValue: store.ai)
    _persistenceState = ObservedObject(wrappedValue: store.persistenceStatus)
  }

  var body: some View {
    VStack(spacing: 0) {
      MacMarkdownEditorToolbar(
        title: $draft.title,
        markdownPath: store.profile(for: draft).markdownPath(for: draft),
        lastSaveStatus: persistenceState.lastSaveStatus,
        hasUnsavedChanges: persistenceState.hasUnsavedChanges,
        editorDisplayMode: publishingState.editorDisplayMode,
        isSelectionAIActionRunning: isSelectionAIActionRunning,
        onSetEditorDisplayMode: { store.setEditorDisplayMode($0) },
        onShowFindReplace: showFindReplace,
        onShowShortcutHelp: {
          isShortcutHelpPresented = true
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
            activeSelectionActionName: activeSelectionAIAction?.localizedDisplayName,
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
      syncEditorBodyFromStore()
      syncActiveEditorSelection()
    }
    .onChange(of: publishingState.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { _, _ in
      syncActiveEditorSelection()
    }
    .onChange(of: editorBody) { previousBody, _ in
      syncActiveEditorSelection()
      stageEditorBody(replacingBaseBody: previousBody)
    }
    .onChange(of: draft.bodyMarkdown) { _, _ in
      syncEditorBodyFromStore()
    }
    .onChange(of: editorBufferRevision) { _, _ in
      syncEditorBodyFromStore()
    }
    .onChange(of: draft.id) { oldDraftID, _ in
      store.flushDraftBodyEditorBuffer(for: oldDraftID)
      syncEditorBodyFromStore()
      syncActiveEditorSelection()
    }
    .sheet(isPresented: $isShortcutHelpPresented) {
      MarkdownShortcutHelpPanel()
    }
    .onDisappear {
      store.flushDraftBodyEditorBuffer(for: draft.id)
      store.clearActiveEditorSelection(for: draft.id)
    }
  }

  private var editorSurface: some View {
    Group {
      switch publishingState.editorDisplayMode {
      case .edit:
        markdownEditor
      case .preview:
        MarkdownPreviewPane(draft: previewDraft, profile: store.profile(for: draft))
      case .split:
        HSplitView {
          markdownEditor
            .frame(minWidth: 320)
          MarkdownPreviewPane(draft: previewDraft, profile: store.profile(for: draft))
            .frame(minWidth: 320)
        }
      }
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var previewDraft: ArticleDraft {
    var updated = draft
    updated.bodyMarkdown = editorBody
    return updated
  }

  private var editorBufferRevision: UInt64 {
    publishingState.draftBodyEditorBuffer(for: draft.id).revision
  }

  private func stageEditorBody(replacingBaseBody baseBodyMarkdown: String) {
    guard let result = store.stageDraftBody(
      editorBody,
      for: draft.id,
      baseRevision: editorBodyRevision,
      replacingBaseBody: baseBodyMarkdown
    ) else {
      return
    }

    editorBodyRevision = result.buffer.revision
    guard !result.wasAccepted else { return }

    editorBody = result.buffer.bodyMarkdown
    selectionActionMessage = "另一窗口已更新正文，刚才的陈旧修改未写入；已同步到最新版本。"
  }

  private func syncEditorBodyFromStore() {
    let buffer = publishingState.draftBodyEditorBuffer(for: draft.id)
    guard buffer.revision != editorBodyRevision else { return }
    editorBody = buffer.bodyMarkdown
    editorBodyRevision = buffer.revision
  }

  private func applyDraftUpdate(_ updated: ArticleDraft) {
    guard let result = store.replaceDraftBody(
      updated.bodyMarkdown,
      for: updated.id,
      expectedRevision: editorBodyRevision
    ) else { return }
    editorBody = result.buffer.bodyMarkdown
    editorBodyRevision = result.buffer.revision
    guard result.wasAccepted else {
      selectionActionMessage = "另一窗口已更新正文，刚才的编辑命令未应用；已同步到最新版本。"
      return
    }
    draft = updated
  }

  private var markdownEditor: some View {
    VStack(spacing: 0) {
      MacMarkdownFormattingToolbar(
        characterCount: editorStatistics.characterCount,
        wordCount: editorStatistics.wordCount,
        lineCount: editorStatistics.lineCount,
        readingMinutes: editorStatistics.readingMinutes,
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
          text: $editorBody,
          selectedRange: $selectedRange,
          onStatisticsChanged: { editorStatistics = $0 },
          onFileDropTargetChanged: { isImageDropTargeted = $0 }
        ) { urls in
          insertImageReferences(urls)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if editorBody.trimmedForPublishing.isEmpty {
          Text("Markdown 正文")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }

        if isImageDropTargeted {
          ZStack {
            Color.accentColor.opacity(0.10)
            VStack(spacing: 8) {
              Image(systemName: "photo.badge.plus")
                .font(.system(size: 30, weight: .semibold))
              Text("拖入图片到当前文章")
                .font(.headline)
            }
            .foregroundStyle(.tint)
          }
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
              .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          .transition(.opacity)
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

  private var hasSelectedText: Bool {
    !selectedText(in: editorBody).trimmedForPublishing.isEmpty
  }

  private var latestAssistantMessageForCurrentDraft: AIPublishingChatMessage? {
    guard aiState.chatDraftID == draft.id else {
      return nil
    }
    return aiState.chatMessages.last { $0.role == .assistant }
  }

  private var isSelectionAIActionRunning: Bool {
    activeSelectionAIAction != nil || aiState.isActionRunning
  }

  private var isAIEnabledForDraft: Bool {
    let profile = store.publishing.profile(for: draft)
    return !profile.aiProviderConfig.requiresAPIKey || aiState.tokenAvailability.hasToken
  }

  private func articleAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      draft: previewDraft,
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
      selectedText: selectedText(in: editorBody),
      draft: previewDraft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  private func activeAIActionForAvailability(fallback kind: AIPublishingActionKind) -> AIPublishingActionKind? {
    activeSelectionAIAction ?? (aiState.isActionRunning ? kind : nil)
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
    let imageURLs = ImageFileSupport.supportedImageURLs(in: urls)
    guard !imageURLs.isEmpty else {
      selectionActionMessage = "没有可插入的图片文件。"
      return
    }

    var updated = previewDraft
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

    applyDraftUpdate(replacingSelection(in: updated, with: markdownBlocks.joined(separator: "\n")))
    store.scheduleImageWorkbenchCachesRefresh(for: updated)
    selectionActionMessage = "已在光标位置插入 \(imageURLs.count) 张图片。"
  }

  private var commandActions: MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draft.id,
      canRewriteSelection: !selectedText(in: editorBody).trimmedForPublishing.isEmpty,
      canUseFindReplace: canUseFindReplace,
      showFindReplace: showFindReplace,
      showKeyboardShortcuts: {
        isShortcutHelpPresented = true
      },
      findNext: findNext,
      replaceCurrentOrNext: replaceCurrentOrNext,
      replaceAll: replaceAll,
      insertImages: {
        insertImageReferences(ImageSelectionPanel.chooseImages())
      },
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
    let selected = selectedText(in: editorBody).trimmedForPublishing
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
      in: editorBody,
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
      in: editorBody,
      query: findQuery,
      replacement: replacementText,
      selectedRange: selectedRange,
      caseSensitive: isFindCaseSensitive
    )

    guard mutation.replacementCount > 0 else {
      findReplaceMessage = "没有找到可替换内容。"
      return
    }

    var updated = previewDraft
    updated.bodyMarkdown = mutation.text
    applyDraftUpdate(updated)
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
      in: editorBody,
      query: findQuery,
      replacement: replacementText,
      caseSensitive: isFindCaseSensitive
    )

    guard mutation.replacementCount > 0 else {
      findReplaceMessage = "没有找到可替换内容。"
      return
    }

    var updated = previewDraft
    updated.bodyMarkdown = mutation.text
    applyDraftUpdate(updated)
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
    var updated = previewDraft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let selected = range.length > 0 ? source.substring(with: range) : placeholder
    let replacement = prefix + selected + suffix

    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    applyDraftUpdate(updated)

    let prefixLength = (prefix as NSString).length
    selectedRange = NSRange(location: range.location + prefixLength, length: (selected as NSString).length)
  }

  private func prefixCurrentLine(_ prefix: String) {
    replaceCurrentLines { line in
      line.hasPrefix(prefix) ? line : prefix + line
    }
  }

  private func replaceCurrentLines(_ transform: (String) -> String) {
    var updated = previewDraft
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
    applyDraftUpdate(updated)
    selectedRange = NSRange(
      location: min(range.location, (updated.bodyMarkdown as NSString).length),
      length: range.length
    )
  }

  private func insertCodeBlock() {
    let selected = selectedText(in: editorBody).trimmedForPublishing
    let body = selected.isEmpty ? "code" : selected
    applyDraftUpdate(replacingSelection(in: previewDraft, with: "```\n\(body)\n```"))
  }

  private func insertTable() {
    let table = """
    | 列 1 | 列 2 |
    | --- | --- |
    | 内容 | 内容 |
    """
    applyDraftUpdate(replacingSelection(in: previewDraft, with: table))
  }

  private func insertHorizontalRule() {
    applyDraftUpdate(replacingSelection(in: previewDraft, with: "---"))
  }

  private func insertLink() {
    var updated = previewDraft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let selected = range.length > 0 ? source.substring(with: range) : "链接文本"
    let url = "https://"
    let replacement = "[\(selected)](\(url))"

    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    applyDraftUpdate(updated)

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
    let bodyLength = (editorBody as NSString).length
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

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private func pasteAIPromptToClipboard() {
    ClipboardWriter.copy(
      store.publishingAIPrompt(for: previewDraft),
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

    let text = editorBody as NSString
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
    _ = store.focusDraft(draft.id, section: .contentHealth)
  }

  private func rewriteSelectedText() {
    performSelectionAIAction(.rewriteSelection)
  }

  private func performSelectionAIAction(_ kind: AIPublishingActionKind) {
    let rawSelectedText = selectedText(in: editorBody)
    let promptSelectedText = rawSelectedText.trimmedForPublishing
    let availability = selectionAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多上下文")"
      return
    }

    activeSelectionAIAction = kind
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    let previewRange = clamped(selectedRange, length: (editorBody as NSString).length)
    selectionEditPreview = nil
    Task {
      let result = await aiState.performAction(kind, draft: previewDraft, selectedText: promptSelectedText)
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
          selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
        } else {
          selectionActionMessage = kind.localizedDisplayName + "失败。"
        }
        activeSelectionAIAction = nil
      }
    }
  }

  private func performArticleAIAction(_ kind: AIPublishingActionKind) {
    let availability = articleAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多文章内容")"
      return
    }

    activeSelectionAIAction = kind
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    let previewRange = articleInsertionRange(for: kind)
    selectionEditPreview = nil
    Task {
      let result = await aiState.performAction(kind, draft: previewDraft)
      await MainActor.run {
        if let result {
          if result.kind.producesMetadataSuggestion, aiState.metadataSuggestion != nil {
            selectionActionMessage = result.kind.localizedDisplayName + "已生成，可在元数据建议中应用。"
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
            selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
          }
        } else {
          selectionActionMessage = kind.localizedDisplayName + "失败。"
        }
        activeSelectionAIAction = nil
      }
    }
  }

  private func articleInsertionRange(for kind: AIPublishingActionKind) -> NSRange {
    let bodyLength = (editorBody as NSString).length
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
    let selectedText = selectedText(in: editorBody).trimmedForPublishing
    guard !selectedText.isEmpty else {
      return
    }

    var probeDraft = previewDraft
    probeDraft.bodyMarkdown = selectedText
    let summary = PublicRiskSummary(issues: PublicRiskScanner().scan(draft: probeDraft))
    let content: String
    if summary.isClear {
      content = "选中文本未命中密钥、私钥、内网地址或本机路径规则。"
      selectionActionMessage = "选区未发现公开风险。"
    } else {
      let issueLines = summary.issues.map {
        "- \($0.severity.localizedDisplayName)：\($0.title) - \($0.message)"
      }
      content = "选中文本公开风险：\n\(issueLines.joined(separator: "\n"))"
      selectionActionMessage = "选区有 \(summary.issueCount) 项公开风险。"
    }
    aiState.setActionResult(AIPublishingActionResult(kind: .privacyReview, content: content))
    aiState.setActionMessage(selectionActionMessage)
  }

  private func applyLatestAIReplyToSelection() {
    guard let message = latestAssistantMessageForCurrentDraft else {
      selectionActionMessage = "当前文章还没有可应用的 AI 回复。"
      return
    }

    let range = clamped(selectedRange, length: (editorBody as NSString).length)
    guard range.length > 0 else {
      selectionActionMessage = "请先选择要替换的正文。"
      return
    }

    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: previewDraft,
      mode: .replaceSelection,
      selectionRange: range
    ) else {
      selectionActionMessage = "AI 回复为空或选区无效。"
      return
    }

    let replacementLength = (message.content.trimmedForPublishing as NSString).length
    applyDraftUpdate(result.draft)
    selectedRange = NSRange(location: range.location + replacementLength, length: 0)
    selectionActionMessage = result.action.statusMessage
  }

  private func showAIContextInspector() {
    aiState.openChatWorkspace(for: draft.id)
  }

  private func applySelectionEditPreview(_ preview: AIPublishingSelectionEditPreview) {
    do {
      let originalLength = (editorBody as NSString).length
      let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: previewDraft)
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
      applyDraftUpdate(updated)
      selectedRange = NSRange(location: newSelectionLocation, length: 0)
      selectionEditPreview = nil
      selectionActionMessage = "\(preview.kind.localizedDisplayName)已应用。"
    } catch {
      selectionActionMessage = error.localizedDescription
    }
  }

  private func discardSelectionEditPreview() {
    selectionEditPreview = nil
    selectionActionMessage = "已丢弃 AI 预览。"
  }
}
