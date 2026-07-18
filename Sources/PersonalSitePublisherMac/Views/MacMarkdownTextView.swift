import AppKit
import OSLog
import PublishingWorkbenchCore
import SwiftUI

struct MarkdownTextEditRequest: Equatable {
  let id: UUID
  let expectedText: String
  let edit: MarkdownSmartEdit

  init(expectedText: String, edit: MarkdownSmartEdit) {
    id = UUID()
    self.expectedText = expectedText
    self.edit = edit
  }
}

struct MarkdownTextFocusRequest: Equatable {
  let id: UUID
  let selectedRange: NSRange
}

private struct MarkdownSyntaxHighlightComputation: Sendable {
  let text: String
  let plan: MarkdownSyntaxHighlightPlan
  let snapshot: MarkdownSyntaxHighlightSnapshot
  let applicationSnapshots: [MarkdownSyntaxHighlightSnapshot]
}

struct MacMarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  var bodyMarkdown: String
  var bodyUTF16Offset: Int
  @Binding var selectedRange: NSRange
  @Binding var isFrontMatterSelection: Bool
  var comfortConfiguration: MarkdownEditorComfortConfiguration
  var diagnostics: [MarkdownInlineDiagnostic]
  var editRequest: MarkdownTextEditRequest?
  var focusRequest: MarkdownTextFocusRequest?
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var onStatisticsChanged: (MarkdownEditorStatistics) -> Void
  var onFileDropTargetChanged: (Bool) -> Void
  var onPasteMessage: (String) -> Void
  var onEditRequestHandled: (UUID) -> Void
  var onScrollProgressChanged: (Double) -> Void
  var onDroppedFiles: ([URL]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: $selectedRange,
      isFrontMatterSelection: $isFrontMatterSelection,
      comfortConfiguration: comfortConfiguration,
      diagnostics: diagnostics,
      onStatisticsChanged: onStatisticsChanged,
      onPasteMessage: onPasteMessage,
      onScrollProgressChanged: onScrollProgressChanged,
      onDroppedFiles: onDroppedFiles
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MarkdownEditorScrollView()
    let editorBackgroundColor = WorkbenchWritingSurface.nsColor(
      usesWarmPaper: comfortConfiguration.warmPaperBackgroundEnabled
    )
    scrollView.preferredBodyWidth = CGFloat(comfortConfiguration.bodyWidth)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = editorBackgroundColor

    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    let textContainer = NSTextContainer(
      containerSize: NSSize(
        width: max(scrollView.contentSize.width, 1),
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false

    let textView = DroppableMarkdownTextView(frame: .zero, textContainer: textContainer)
    precondition(textView.layoutManager != nil, "Markdown editor requires a complete TextKit stack")
    Self.configureAccessibility(for: textView)
    textView.delegate = context.coordinator
    textView.fileDropTargetChangedHandler = onFileDropTargetChanged
    textView.fileDropHandler = { urls, dropRange in
      context.coordinator.handleDroppedFiles(urls, at: dropRange)
    }
    textView.smartPasteHandler = { textView, pasteboard in
      context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
    }
    textView.markdownFormattingHandler = { textView, command in
      context.coordinator.handleFormatting(command, in: textView)
    }
    textView.markdownTableContextProvider = { textView in
      context.coordinator.tableContext(in: textView)
    }
    textView.markdownTableEditingHandler = { textView, command in
      context.coordinator.handleTableEditing(command, in: textView)
    }
    textView.string = text
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = true
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = comfortConfiguration.spellCheckEnabled
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.textColor = NSColor.labelColor
    textView.insertionPointColor = NSColor.controlAccentColor
    textView.backgroundColor = editorBackgroundColor
    textView.drawsBackground = true
    context.coordinator.applyCachedSyntaxAppearance(in: textView)
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.frame = NSRect(
      origin: .zero,
      size: NSSize(width: max(scrollView.contentSize.width, 1), height: max(scrollView.contentSize.height, 1))
    )
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [NSView.AutoresizingMask.width]
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false

    scrollView.documentView = textView
    context.coordinator.observeScrolling(in: scrollView)
    context.coordinator.scheduleFullStatistics(for: bodyMarkdown)
    context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    context.coordinator.updateDiagnostics(diagnostics, in: textView, force: true)
    context.coordinator.updateCurrentParagraphHighlight(in: textView, force: true)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    Self.configureAccessibility(for: textView)
    textView.isEditable = true
    textView.isSelectable = true
    context.coordinator.updateDocumentContext(
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset
    )
    context.coordinator.applyComfortConfiguration(
      comfortConfiguration,
      in: textView
    )
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.fileDropTargetChangedHandler = onFileDropTargetChanged
      droppableTextView.smartPasteHandler = { textView, pasteboard in
        context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
      }
      droppableTextView.markdownFormattingHandler = { textView, command in
        context.coordinator.handleFormatting(command, in: textView)
      }
      droppableTextView.markdownTableContextProvider = { textView in
        context.coordinator.tableContext(in: textView)
      }
      droppableTextView.markdownTableEditingHandler = { textView, command in
        context.coordinator.handleTableEditing(command, in: textView)
      }
    }

    let didReplaceText = textView.string != text
    if didReplaceText {
      let currentDocumentRange = textView.selectedRange()
      textView.string = text
      (nsView as? MarkdownEditorScrollView)?.invalidateDocumentHeight(immediately: true)
      let replacementRange = isFrontMatterSelection
        ? clamped(currentDocumentRange, length: (text as NSString).length)
        : documentRange(
          forBodyRange: selectedRange,
          bodyUTF16Offset: bodyUTF16Offset,
          documentLength: (text as NSString).length
        )
      textView.setSelectedRange(replacementRange)
      context.coordinator.invalidateHighlightedTextCache()
      context.coordinator.scheduleFullStatistics(for: bodyMarkdown)
      context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    }

    if !isFrontMatterSelection {
      let range = documentRange(
        forBodyRange: selectedRange,
        bodyUTF16Offset: bodyUTF16Offset,
        documentLength: (textView.string as NSString).length
      )
      if textView.selectedRange() != range {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
      }
    }
    context.coordinator.updateDiagnostics(
      diagnostics,
      in: textView,
      force: didReplaceText
    )
    context.coordinator.updateCurrentParagraphHighlight(
      in: textView,
      force: didReplaceText
    )

    context.coordinator.refreshCachedTypingAttributes(in: textView)
    if let handledRequestID = context.coordinator.handle(editRequest, in: textView) {
      DispatchQueue.main.async {
        onEditRequestHandled(handledRequestID)
      }
    }
    context.coordinator.requestKeyboardFocus(focusRequest, in: textView)
    context.coordinator.applySynchronizedScroll(scrollSyncUpdate, in: nsView)
    context.coordinator.applyRestoredScroll(scrollRestorationUpdate, in: nsView)
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    Self.clamped(range, length: length)
  }

  private func documentRange(
    forBodyRange range: NSRange,
    bodyUTF16Offset: Int,
    documentLength: Int
  ) -> NSRange {
    let bodyLength = max(0, documentLength - bodyUTF16Offset)
    let clampedBodyRange = Self.clamped(range, length: bodyLength)
    return NSRange(
      location: bodyUTF16Offset + clampedBodyRange.location,
      length: clampedBodyRange.length
    )
  }

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private static func configureAccessibility(for textView: NSTextView) {
    textView.setAccessibilityLabel(String(localized: "Markdown 文档编辑器"))
    textView.setAccessibilityHelp(
      String(localized: "编辑当前文章的 Front Matter 与 Markdown 正文；Control-Tab 移到下一个控件")
    )
    textView.setAccessibilityIdentifier("markdown-document-editor")
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var isFrontMatterSelection: Bool
    private var bodyMarkdown: String
    private var bodyUTF16Offset: Int
    let onStatisticsChanged: (MarkdownEditorStatistics) -> Void
    let onPasteMessage: (String) -> Void
    let onScrollProgressChanged: (Double) -> Void
    let onDroppedFiles: ([URL]) -> Void
    private weak var textView: NSTextView?
    private let syntaxHighlightDebouncer = MarkdownSyntaxHighlightDebouncer()
    private var syntaxAttributeApplicationTask: Task<Void, Never>?
    private var syntaxAttributeApplicationGeneration: UInt64 = 0
    private var highlightedTextCache: String?
    private var pendingSyntaxHighlightPlan: MarkdownSyntaxHighlightPlan?
    private var syntaxCodeBlockRanges: [NSRange]?
    private let syntaxHighlightParser = MarkdownSyntaxHighlightParser()
    private let syntaxHighlightSignposter = OSSignposter(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    private let syntaxHighlightLogger = Logger(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    private var hasLoggedSyntaxTelemetryActivation = false
    private var statisticsTask: Task<Void, Never>?
    private var statisticsGeneration = 0
    private var statisticsText: String?
    private var statistics = MarkdownEditorStatistics.empty
    private var pendingTextEdit: MarkdownTextEdit?
    private var lastAppliedEditRequestID: UUID?
    private var pendingFocusRequest: MarkdownTextFocusRequest?
    private var lastAppliedFocusRequestID: UUID?
    private var focusRequestTask: Task<Void, Never>?
    private var comfortConfiguration: MarkdownEditorComfortConfiguration
    private var syntaxHighlightPalette: MarkdownTextViewSyntaxPalette
    private var diagnostics: [MarkdownInlineDiagnostic]
    private var appliedParagraphHighlightRange: NSRange?
    private var appliedDiagnosticOverlays: [MarkdownEditorDiagnosticOverlay] = []
    private let scrollSyncBridge: MarkdownScrollViewSyncBridge
    private let smartEditingService = MarkdownSmartEditingService()
    private let smartPasteService = MarkdownSmartPasteService()
    private let richTextPasteService = MarkdownRichTextPasteService()
    private let formattingService = MarkdownFormattingService()
    private let tableEditingService = MarkdownTableEditingService()
    private let pastedImageFileStore = PastedImageFileStore()
    private let statisticsDelay: TimeInterval = 0.18

    init(
      text: Binding<String>,
      bodyMarkdown: String,
      bodyUTF16Offset: Int,
      selectedRange: Binding<NSRange>,
      isFrontMatterSelection: Binding<Bool>,
      comfortConfiguration: MarkdownEditorComfortConfiguration,
      diagnostics: [MarkdownInlineDiagnostic],
      onStatisticsChanged: @escaping (MarkdownEditorStatistics) -> Void,
      onPasteMessage: @escaping (String) -> Void,
      onScrollProgressChanged: @escaping (Double) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void
    ) {
      _text = text
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
      _selectedRange = selectedRange
      _isFrontMatterSelection = isFrontMatterSelection
      self.comfortConfiguration = comfortConfiguration
      syntaxHighlightPalette = MarkdownTextViewSyntaxPalette(
        configuration: comfortConfiguration
      )
      self.diagnostics = diagnostics
      self.onStatisticsChanged = onStatisticsChanged
      self.onPasteMessage = onPasteMessage
      self.onScrollProgressChanged = onScrollProgressChanged
      self.onDroppedFiles = onDroppedFiles
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .editor,
        onProgressChanged: onScrollProgressChanged
      )
    }

    func updateDocumentContext(bodyMarkdown: String, bodyUTF16Offset: Int) {
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
    }

    func handleDroppedFiles(_ urls: [URL], at documentRange: NSRange) {
      guard documentRange.location >= bodyUTF16Offset else { return }
      selectedRange = bodyRange(from: documentRange)
      isFrontMatterSelection = false
      onDroppedFiles(urls)
    }

    private func documentRange(from bodyRange: NSRange) -> NSRange {
      NSRange(
        location: bodyUTF16Offset + bodyRange.location,
        length: bodyRange.length
      )
    }

    private func bodyRange(from documentRange: NSRange) -> NSRange {
      let bodyLength = (bodyMarkdown as NSString).length
      let location = min(
        max(documentRange.location - bodyUTF16Offset, 0),
        bodyLength
      )
      let maxLength = max(0, bodyLength - location)
      return NSRange(location: location, length: min(documentRange.length, maxLength))
    }

    private func updateSelectionBinding(from documentRange: NSRange) {
      if documentRange.location < bodyUTF16Offset {
        isFrontMatterSelection = true
        selectedRange = NSRange(location: 0, length: 0)
      } else {
        isFrontMatterSelection = false
        selectedRange = bodyRange(from: documentRange)
      }
    }

    private struct DocumentParts {
      let bodyMarkdown: String
      let bodyUTF16Offset: Int
    }

    private static func documentParts(in source: String) -> DocumentParts? {
      let normalized = source
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      let lines = normalized.components(separatedBy: "\n")
      guard let delimiter = lines.first?.trimmedForPublishing,
            delimiter == "---" || delimiter == "+++",
            let closingIndex = lines.dropFirst().firstIndex(where: {
              $0.trimmedForPublishing == delimiter
            }) else {
        return nil
      }

      let frontMatter = lines[...closingIndex].joined(separator: "\n")
      let sourceText = normalized as NSString
      var bodyOffset = (frontMatter as NSString).length
      var skippedNewlines = 0
      while bodyOffset < sourceText.length, skippedNewlines < 2,
            sourceText.character(at: bodyOffset) == 10 {
        bodyOffset += 1
        skippedNewlines += 1
      }
      return DocumentParts(
        bodyMarkdown: sourceText.substring(from: bodyOffset),
        bodyUTF16Offset: bodyOffset
      )
    }

    func applyComfortConfiguration(
      _ configuration: MarkdownEditorComfortConfiguration,
      in textView: NSTextView
    ) {
      guard configuration != comfortConfiguration else { return }
      let shouldRebuildSyntaxPalette = !syntaxHighlightPalette.matches(configuration)
      comfortConfiguration = configuration
      if shouldRebuildSyntaxPalette {
        syntaxHighlightPalette = MarkdownTextViewSyntaxPalette(configuration: configuration)
        applyCachedSyntaxAppearance(in: textView)
      }
      textView.isContinuousSpellCheckingEnabled = configuration.spellCheckEnabled
      let editorBackgroundColor = WorkbenchWritingSurface.nsColor(
        usesWarmPaper: configuration.warmPaperBackgroundEnabled
      )
      textView.backgroundColor = editorBackgroundColor
      textView.enclosingScrollView?.backgroundColor = editorBackgroundColor
      if let scrollView = textView.enclosingScrollView as? MarkdownEditorScrollView {
        scrollView.preferredBodyWidth = CGFloat(configuration.bodyWidth)
      }
      if shouldRebuildSyntaxPalette {
        invalidateHighlightedTextCache()
        scheduleMarkdownSyntaxHighlighting(for: textView, text: textView.string)
      }
      updateCurrentParagraphHighlight(in: textView)
    }

    func applyCachedSyntaxAppearance(in textView: NSTextView) {
      textView.font = syntaxHighlightPalette.baseFont
      refreshCachedTypingAttributes(in: textView)
    }

    func refreshCachedTypingAttributes(in textView: NSTextView) {
      textView.typingAttributes = syntaxHighlightPalette.defaultAttributes
    }

    func updateDiagnostics(
      _ diagnostics: [MarkdownInlineDiagnostic],
      in textView: NSTextView,
      force: Bool = false
    ) {
      self.diagnostics = diagnostics
      updateDiagnosticOverlays(in: textView, force: force)
    }

    deinit {
      syntaxAttributeApplicationTask?.cancel()
      statisticsTask?.cancel()
      focusRequestTask?.cancel()
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      pendingTextEdit = MarkdownTextEdit(
        previousText: textView.string,
        replacedRange: affectedCharRange
      )
      return true
    }

    func handlePaste(
      in textView: NSTextView,
      pasteboard: NSPasteboard
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return false }
      let imageURLs = MarkdownPasteboardReader.imageFileURLs(from: pasteboard)
      if !imageURLs.isEmpty {
        updateSelectionBinding(from: textView.selectedRange())
        onDroppedFiles(imageURLs)
        return true
      }

      if let pngData = MarkdownPasteboardReader.pngData(from: pasteboard) {
        do {
          let imageURL = try pastedImageFileStore.storePNG(pngData)
          updateSelectionBinding(from: textView.selectedRange())
          onDroppedFiles([imageURL])
        } catch {
          onPasteMessage("粘贴图片失败：\(error.localizedDescription)")
          NSSound.beep()
        }
        return true
      }

      if let pastedText = pasteboard.string(forType: .string),
         let edit = smartPasteService.linkEdit(
           in: textView.string,
           selectedRange: textView.selectedRange(),
           pastedText: pastedText
         ) {
        apply(edit, in: textView)
        return true
      }

      guard let richContent = MarkdownPasteboardReader.richTextContent(from: pasteboard),
            let conversion = richTextPasteService.conversion(
              fromHTML: richContent.html,
              baseURL: richContent.baseURL
            ),
            MarkdownPasteboardReader.shouldPreferRichConversion(
              conversion.markdown,
              over: pasteboard.string(forType: .string)
            ),
            let edit = richTextPasteService.edit(
              in: textView.string,
              selectedRange: textView.selectedRange(),
              conversion: conversion
            ) else {
        return false
      }

      apply(edit, in: textView)
      if conversion.removedTrackingParameterCount > 0 {
        onPasteMessage(
          "已将富文本转换为 Markdown，并移除 \(conversion.removedTrackingParameterCount) 个跟踪参数。"
        )
      } else {
        onPasteMessage("已将富文本转换为 Markdown。")
      }
      return true
    }

    func handleFormatting(
      _ command: MarkdownFormattingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        NSSound.beep()
        return true
      }
      guard let edit = formattingService.edit(
        in: textView.string,
        selectedRange: textView.selectedRange(),
        command: command
      ) else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    func tableContext(in textView: NSTextView) -> MarkdownTableEditingContext? {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return nil }
      return tableEditingService.context(
        in: textView.string,
        selectedRange: textView.selectedRange()
      )
    }

    func handleTableEditing(
      _ command: MarkdownTableEditingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return false }
      guard let edit = tableEditingService.edit(
        in: textView.string,
        selectedRange: textView.selectedRange(),
        command: command
      ) else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    private func apply(_ edit: MarkdownSmartEdit, in textView: NSTextView) {
      if edit.changesText {
        textView.insertText(edit.replacement, replacementRange: edit.replacedRange)
      }
      textView.setSelectedRange(edit.selectedRange)
      updateSelectionBinding(from: edit.selectedRange)
    }

    @discardableResult
    func handle(_ request: MarkdownTextEditRequest?, in textView: NSTextView) -> UUID? {
      guard let request,
            request.id != lastAppliedEditRequestID else {
        return nil
      }

      lastAppliedEditRequestID = request.id
      guard bodyMarkdown == request.expectedText else {
        return request.id
      }

      let textLength = (bodyMarkdown as NSString).length
      guard request.edit.replacedRange.location >= 0,
            NSMaxRange(request.edit.replacedRange) <= textLength else {
        return request.id
      }

      let documentEdit = MarkdownSmartEdit(
        replacedRange: documentRange(from: request.edit.replacedRange),
        replacement: request.edit.replacement,
        selectedRange: documentRange(from: request.edit.selectedRange)
      )
      apply(documentEdit, in: textView)
      return request.id
    }

    func requestKeyboardFocus(
      _ request: MarkdownTextFocusRequest?,
      in textView: NSTextView
    ) {
      guard let request else {
        pendingFocusRequest = nil
        focusRequestTask?.cancel()
        focusRequestTask = nil
        return
      }
      guard request.id != lastAppliedFocusRequestID else { return }
      guard pendingFocusRequest != request || focusRequestTask == nil else { return }

      pendingFocusRequest = request
      focusRequestTask?.cancel()
      focusRequestTask = Task { @MainActor [weak self, weak textView] in
        let retryDelays = [0, 60, 160, 320]
        for delay in retryDelays {
          if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
          }
          guard !Task.isCancelled,
                let self,
                let textView,
                self.pendingFocusRequest?.id == request.id else {
            return
          }
          guard let window = textView.window,
                window.attachedSheet == nil else {
            continue
          }

          let bodyRange = MacMarkdownTextView.clamped(
            request.selectedRange,
            length: (self.bodyMarkdown as NSString).length
          )
          let range = self.documentRange(from: bodyRange)
          textView.setSelectedRange(range)
          textView.scrollRangeToVisible(range)
          let didFocus = window.firstResponder === textView
            || window.makeFirstResponder(textView)
          guard didFocus else { continue }

          self.selectedRange = bodyRange
          self.isFrontMatterSelection = false
          self.lastAppliedFocusRequestID = request.id
          self.pendingFocusRequest = nil
          self.focusRequestTask = nil
          NSAccessibility.post(
            element: textView,
            notification: .focusedUIElementChanged
          )
          return
        }

        guard self?.pendingFocusRequest?.id == request.id else { return }
        self?.focusRequestTask = nil
      }
    }

    func observeScrolling(in scrollView: NSScrollView) {
      scrollSyncBridge.observe(scrollView)
    }

    func applySynchronizedScroll(
      _ update: MarkdownScrollSyncUpdate?,
      in scrollView: NSScrollView,
      allowDeferredRetry: Bool = true
    ) {
      scrollSyncBridge.apply(update, allowDeferredRetry: allowDeferredRetry)
    }

    func applyRestoredScroll(
      _ update: MarkdownScrollSyncUpdate?,
      in scrollView: NSScrollView
    ) {
      scrollSyncBridge.restore(update)
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      let updatedText = textView.string
      let syntaxHighlightPlan: MarkdownSyntaxHighlightPlan
      if let pendingTextEdit {
        syntaxHighlightPlan = MarkdownSyntaxHighlightRangeService.plan(
          accumulating: pendingSyntaxHighlightPlan,
          previousText: pendingTextEdit.previousText,
          currentText: updatedText,
          replacedRange: pendingTextEdit.replacedRange,
          knownCodeBlockRanges: syntaxCodeBlockRanges
        )
      } else {
        syntaxHighlightPlan = .fullDocument(for: updatedText)
      }
      pendingSyntaxHighlightPlan = syntaxHighlightPlan
      syntaxCodeBlockRanges = syntaxHighlightPlan.codeBlockRanges
      if let parts = Self.documentParts(in: updatedText) {
        bodyMarkdown = parts.bodyMarkdown
        bodyUTF16Offset = parts.bodyUTF16Offset
      }
      text = updatedText
      updateSelectionBinding(from: textView.selectedRange())
      scheduleFullStatistics(for: bodyMarkdown)
      scheduleMarkdownSyntaxHighlighting(
        for: textView,
        text: updatedText,
        plan: syntaxHighlightPlan
      )
      updateCurrentParagraphHighlight(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      updateSelectionBinding(from: textView.selectedRange())
      updateCurrentParagraphHighlight(in: textView)
      centerSelectionIfNeeded(in: textView)
    }

    func textView(
      _ textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        return false
      }
      let edit: MarkdownSmartEdit?
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        edit = smartEditingService.newlineEdit(
          in: textView.string,
          selectedRange: textView.selectedRange()
        )
      case #selector(NSResponder.insertTab(_:)):
        if handleTableEditing(.navigateForward, in: textView) {
          return true
        }
        edit = smartEditingService.indentationEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          direction: .indent
        )
      case #selector(NSResponder.insertBacktab(_:)):
        if handleTableEditing(.navigateBackward, in: textView) {
          return true
        }
        edit = smartEditingService.indentationEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          direction: .outdent
        )
      default:
        return false
      }

      guard let edit else { return false }
      apply(edit, in: textView)
      return true
    }

    func invalidateHighlightedTextCache() {
      highlightedTextCache = nil
      pendingSyntaxHighlightPlan = nil
      syntaxCodeBlockRanges = nil
      syntaxHighlightDebouncer.cancel()
      cancelPendingSyntaxAttributeApplication()
    }

    func scheduleFullStatistics(for text: String) {
      statisticsTask?.cancel()
      statisticsGeneration += 1
      let generation = statisticsGeneration
      let delay = statisticsDelay
      statisticsTask = Task.detached(priority: .userInitiated) { [weak self, text] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        let updatedStatistics = MarkdownEditorStatistics.make(for: text)
        await self?.applyFullStatistics(
          updatedStatistics,
          for: text,
          generation: generation
        )
      }
    }

    func scheduleMarkdownSyntaxHighlighting(
      for textView: NSTextView,
      text: String,
      plan: MarkdownSyntaxHighlightPlan? = nil
    ) {
      cancelPendingSyntaxAttributeApplication()
      guard highlightedTextCache != text else { return }

      self.textView = textView
      let requestedPlan = plan ?? .fullDocument(for: text)
      pendingSyntaxHighlightPlan = requestedPlan
      syntaxCodeBlockRanges = requestedPlan.codeBlockRanges
      let syntaxHighlightParser = self.syntaxHighlightParser
      let delay = MarkdownSyntaxHighlightSchedulingPolicy.delay(
        for: requestedPlan,
        documentUTF16Length: (text as NSString).length
      )
      let priorityRange = selectionSyntaxHighlightRange(
        in: text,
        selectedRange: textView.selectedRange(),
        snapshotRange: requestedPlan.range
      )
      syntaxHighlightDebouncer.schedule(
        delay: delay,
        operation: { [text] () async -> MarkdownSyntaxHighlightComputation? in
          let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
            in: text,
            plan: requestedPlan
          )
          guard !Task.isCancelled else { return nil }
          guard let snapshot = await syntaxHighlightParser.snapshot(
            in: text,
            range: resolvedPlan.range
          ) else {
            return nil
          }
          guard !Task.isCancelled else { return nil }
          let applicationSnapshots = MarkdownSyntaxHighlightApplicationPlanner
            .applicationSnapshots(
              for: snapshot,
              prioritizing: priorityRange
            )
          return MarkdownSyntaxHighlightComputation(
            text: text,
            plan: resolvedPlan,
            snapshot: snapshot,
            applicationSnapshots: applicationSnapshots
          )
        },
        onValue: { [weak self] computation in
          self?.applyMarkdownSyntaxHighlighting(
            text: computation.text,
            plan: computation.plan,
            snapshot: computation.snapshot,
            applicationSnapshots: computation.applicationSnapshots
          )
        }
      )
    }

    private func applyFullStatistics(
      _ updatedStatistics: MarkdownEditorStatistics,
      for text: String,
      generation: Int
    ) {
      guard statisticsGeneration == generation else { return }
      statistics = updatedStatistics
      statisticsText = text
      statisticsTask = nil
      onStatisticsChanged(updatedStatistics)
    }

    func applyMarkdownSyntaxHighlighting(
      text: String,
      plan: MarkdownSyntaxHighlightPlan,
      snapshot: MarkdownSyntaxHighlightSnapshot,
      applicationSnapshots: [MarkdownSyntaxHighlightSnapshot]
    ) {
      guard highlightedTextCache != text else { return }
      guard let textView else { return }
      guard textView.string == text else { return }
      guard snapshot.range == plan.range else { return }

      let currentPriorityRange = visibleSyntaxHighlightRange(
        in: textView,
        snapshotRange: snapshot.range
      )
      let prioritizedApplicationSnapshots = MarkdownSyntaxHighlightApplicationPlanner
        .prioritizing(
          applicationSnapshots,
          around: currentPriorityRange
        )
      cancelPendingSyntaxAttributeApplication()
      syntaxAttributeApplicationGeneration &+= 1
      let generation = syntaxAttributeApplicationGeneration
      syntaxAttributeApplicationTask = Task { @MainActor [weak self] in
        await self?.applyMarkdownSyntaxHighlighting(
          text: text,
          plan: plan,
          snapshot: snapshot,
          applicationSnapshots: prioritizedApplicationSnapshots,
          generation: generation
        )
      }
    }

    private func applyMarkdownSyntaxHighlighting(
      text: String,
      plan: MarkdownSyntaxHighlightPlan,
      snapshot: MarkdownSyntaxHighlightSnapshot,
      applicationSnapshots: [MarkdownSyntaxHighlightSnapshot],
      generation: UInt64
    ) async {
      guard syntaxAttributeApplicationGeneration == generation,
            !Task.isCancelled,
            let textView,
            textView.string == text else {
        return
      }

      let selectedRange = textView.selectedRange()
      guard let textStorage = textView.textStorage else { return }
      let signpostID = syntaxHighlightSignposter.makeSignpostID()
      let intervalState = syntaxHighlightSignposter.beginInterval(
        "ApplyAttributes",
        id: signpostID,
        "rangeLength: \(snapshot.range.length, privacy: .public), runCount: \(snapshot.runs.count, privacy: .public), chunkCount: \(applicationSnapshots.count, privacy: .public)"
      )
      var appliedChunkCount = 0
      defer {
        syntaxHighlightSignposter.endInterval(
          "ApplyAttributes",
          intervalState,
          "textStorageLength: \(textStorage.length, privacy: .public), completedChunks: \(appliedChunkCount, privacy: .public)"
        )
      }

      for (index, applicationSnapshot) in applicationSnapshots.enumerated() {
        guard syntaxAttributeApplicationGeneration == generation,
              !Task.isCancelled,
              textView.string == text,
              textStorage.length == (text as NSString).length else {
          return
        }
        textStorage.beginEditing()
        MarkdownSyntaxHighlightAttributeApplier.apply(
          applicationSnapshot,
          to: textStorage,
          defaultAttributes: syntaxHighlightPalette.defaultAttributes,
          styleAttributes: syntaxHighlightPalette.styleAttributes
        )
        textStorage.endEditing()
        appliedChunkCount += 1
        if index < applicationSnapshots.count - 1 {
          await Task.yield()
        }
      }

      guard syntaxAttributeApplicationGeneration == generation,
            !Task.isCancelled,
            textView.string == text else {
        return
      }
      if !hasLoggedSyntaxTelemetryActivation {
        syntaxHighlightLogger.info(
          "Syntax telemetry active: documentLength=\(textStorage.length, privacy: .public), rangeLength=\(snapshot.range.length, privacy: .public), runCount=\(snapshot.runs.count, privacy: .public), chunkCount=\(applicationSnapshots.count, privacy: .public)"
        )
        hasLoggedSyntaxTelemetryActivation = true
      }
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      textView.setSelectedRange(Self.clamped(selectedRange, length: (text as NSString).length))
      refreshCachedTypingAttributes(in: textView)
      updateCurrentParagraphHighlight(in: textView, force: true)
      updateDiagnosticOverlays(in: textView, force: true)
      highlightedTextCache = text
      syntaxCodeBlockRanges = plan.codeBlockRanges
      pendingSyntaxHighlightPlan = nil
      syntaxAttributeApplicationTask = nil
    }

    private func cancelPendingSyntaxAttributeApplication() {
      syntaxAttributeApplicationTask?.cancel()
      syntaxAttributeApplicationTask = nil
      syntaxAttributeApplicationGeneration &+= 1
    }

    private func visibleSyntaxHighlightRange(
      in textView: NSTextView,
      snapshotRange: NSRange
    ) -> NSRange? {
      guard let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer else {
        return nil
      }
      let inset = textView.textContainerInset
      let textContainerVisibleRect = textView.visibleRect.offsetBy(
        dx: -inset.width,
        dy: -inset.height
      )
      let glyphRange = layoutManager.glyphRange(
        forBoundingRect: textContainerVisibleRect,
        in: textContainer
      )
      let characterRange = layoutManager.characterRange(
        forGlyphRange: glyphRange,
        actualGlyphRange: nil
      )
      let intersection = NSIntersectionRange(snapshotRange, characterRange)
      return intersection.length > 0 ? intersection : nil
    }

    private func selectionSyntaxHighlightRange(
      in text: String,
      selectedRange: NSRange,
      snapshotRange: NSRange
    ) -> NSRange? {
      let source = text as NSString
      let selection = Self.clamped(selectedRange, length: source.length)
      let lineRange = source.lineRange(for: selection)
      let intersection = NSIntersectionRange(snapshotRange, lineRange)
      return intersection.length > 0 ? intersection : nil
    }

    func updateCurrentParagraphHighlight(
      in textView: NSTextView,
      force: Bool = false
    ) {
      guard let layoutManager = textView.layoutManager else { return }
      let length = (textView.string as NSString).length
      let paragraphRange = MarkdownEditorOverlayService.currentParagraphRange(
        in: textView.string,
        selectedRange: textView.selectedRange(),
        isEnabled: comfortConfiguration.currentParagraphHighlightEnabled
      )
      guard force || paragraphRange != appliedParagraphHighlightRange else { return }

      if let appliedParagraphHighlightRange,
         let removableRange = MarkdownEditorOverlayService.clampedNonEmptyRange(
           appliedParagraphHighlightRange,
           length: length
         ) {
        layoutManager.removeTemporaryAttribute(
          .backgroundColor,
          forCharacterRange: removableRange
        )
      }
      if let paragraphRange {
        layoutManager.addTemporaryAttribute(
          .backgroundColor,
          value: NSColor.controlAccentColor.withAlphaComponent(0.07),
          forCharacterRange: paragraphRange
        )
      }
      appliedParagraphHighlightRange = paragraphRange
    }

    private func updateDiagnosticOverlays(
      in textView: NSTextView,
      force: Bool = false
    ) {
      guard let layoutManager = textView.layoutManager else { return }
      let documentDiagnostics = diagnostics.map { diagnostic in
        var updated = diagnostic
        updated.range.location += bodyUTF16Offset
        return updated
      }
      let overlays = MarkdownEditorOverlayService.diagnosticOverlays(
        in: textView.string,
        diagnostics: documentDiagnostics
      )
      guard force || overlays != appliedDiagnosticOverlays else { return }

      let length = (textView.string as NSString).length
      for overlay in appliedDiagnosticOverlays {
        guard let removableRange = MarkdownEditorOverlayService.clampedNonEmptyRange(
          overlay.range,
          length: length
        ) else { continue }
        layoutManager.removeTemporaryAttribute(
          .underlineStyle,
          forCharacterRange: removableRange
        )
        layoutManager.removeTemporaryAttribute(
          .underlineColor,
          forCharacterRange: removableRange
        )
      }

      let underlineStyle = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
      for overlay in overlays {
        let color: NSColor = overlay.severity == .error ? .systemRed : .systemOrange
        layoutManager.addTemporaryAttributes(
          [
            .underlineStyle: underlineStyle,
            .underlineColor: color,
          ],
          forCharacterRange: overlay.range
        )
      }
      appliedDiagnosticOverlays = overlays
    }

    private func centerSelectionIfNeeded(in textView: NSTextView) {
      guard comfortConfiguration.typewriterModeEnabled,
            let scrollView = textView.enclosingScrollView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer else { return }
      let length = (textView.string as NSString).length
      guard length > 0 else { return }
      let location = min(textView.selectedRange().location, length - 1)
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: NSRange(location: location, length: 1),
        actualCharacterRange: nil
      )
      let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      let clipView = scrollView.contentView
      let documentHeight = textView.bounds.height
      let targetY = rect.midY + textView.textContainerInset.height - clipView.bounds.height / 2
      let maximumY = max(0, documentHeight - clipView.bounds.height)
      clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: min(max(0, targetY), maximumY)))
      scrollView.reflectScrolledClipView(clipView)
    }

    private func updateStatistics(afterEditing updatedText: String) {
      defer { pendingTextEdit = nil }
      guard let pendingTextEdit,
            let previousStatisticsText = statisticsText,
            previousStatisticsText == pendingTextEdit.previousText else {
        scheduleFullStatistics(for: updatedText)
        return
      }

      let insertedLength = max(
        0,
        (updatedText as NSString).length - (previousStatisticsText as NSString).length + pendingTextEdit.replacedRange.length
      )
      let insertedRange = NSRange(location: pendingTextEdit.replacedRange.location, length: insertedLength)
      statistics = statistics.applying(
        replacing: pendingTextEdit.replacedRange,
        in: previousStatisticsText,
        with: insertedRange,
        in: updatedText
      )
      statisticsText = updatedText
      scheduleStatisticsDelivery()
    }

    private func scheduleStatisticsDelivery() {
      statisticsTask?.cancel()
      statisticsGeneration += 1
      let generation = statisticsGeneration
      let delay = statisticsDelay
      statisticsTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self, self.statisticsGeneration == generation else { return }
        self.statisticsTask = nil
        self.onStatisticsChanged(self.statistics)
      }
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
      let location = min(max(range.location, 0), length)
      let maxLength = max(0, length - location)
      return NSRange(location: location, length: min(range.length, maxLength))
    }
  }
}

private final class MarkdownEditorScrollView: NSScrollView {
  private var cachedLayoutWidth: CGFloat = 0
  private var cachedTextHeight: CGFloat?
  private var heightInvalidationWorkItem: DispatchWorkItem?
  var preferredBodyWidth = CGFloat(MarkdownEditorComfortConfiguration.defaultBodyWidth) {
    didSet {
      guard abs(oldValue - preferredBodyWidth) > 0.5 else { return }
      cachedLayoutWidth = 0
      invalidateDocumentHeight(immediately: true)
    }
  }

  override var acceptsFirstResponder: Bool { false }

  func invalidateDocumentHeight(immediately: Bool = false) {
    heightInvalidationWorkItem?.cancel()
    if immediately {
      cachedTextHeight = nil
      needsLayout = true
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.cachedTextHeight = nil
      self.needsLayout = true
    }
    heightInvalidationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: workItem)
  }

  override func layout() {
    super.layout()
    guard let textView = documentView as? NSTextView else { return }

    let contentHeight = contentSize.height
    let contentWidth = max(contentSize.width, 1)
    let availableBodyWidth = max(contentWidth - 32, 1)
    let bodyWidth = min(preferredBodyWidth, availableBodyWidth)
    let horizontalInset: CGFloat = 16
    let layoutWidth = bodyWidth
    let widthChanged = abs(cachedLayoutWidth - layoutWidth) > 0.5
    if widthChanged {
      textView.textContainer?.containerSize = NSSize(
        width: layoutWidth,
        height: CGFloat.greatestFiniteMagnitude
      )
      cachedTextHeight = nil
      cachedLayoutWidth = layoutWidth
    }
    textView.textContainerInset = NSSize(width: horizontalInset, height: 16)
    let textHeight = textView.layoutManager.map { layoutManager in
      guard let textContainer = textView.textContainer else { return contentHeight }
      if let cachedTextHeight {
        return cachedTextHeight
      }
      layoutManager.ensureLayout(for: textContainer)
      let measuredHeight = layoutManager.usedRect(for: textContainer).height
        + textView.textContainerInset.height * 2
      cachedTextHeight = measuredHeight
      return measuredHeight
    } ?? contentHeight

    textView.frame.size = NSSize(
      width: contentWidth,
      height: max(contentHeight, textHeight, 1)
    )
  }
}

private final class DroppableMarkdownTextView: NSTextView {
  var fileDropTargetChangedHandler: ((Bool) -> Void)?
  var fileDropHandler: (([URL], NSRange) -> Void)?
  var smartPasteHandler: ((NSTextView, NSPasteboard) -> Bool)?
  var markdownFormattingHandler: ((NSTextView, MarkdownFormattingCommand) -> Bool)?
  var markdownTableContextProvider: ((NSTextView) -> MarkdownTableEditingContext?)?
  var markdownTableEditingHandler: ((NSTextView, MarkdownTableEditingCommand) -> Bool)?
  private var isFileDropTargeted = false

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override var acceptsFirstResponder: Bool { true }

  override var canBecomeKeyView: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    if window?.firstResponder !== self {
      window?.makeFirstResponder(self)
    }
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 48, modifiers.contains(.control) {
      if modifiers.contains(.shift) {
        window?.selectPreviousKeyView(self)
      } else {
        window?.selectNextKeyView(self)
      }
      return
    }
    super.keyDown(with: event)
  }

  override func paste(_ sender: Any?) {
    guard smartPasteHandler?(self, .general) == true else {
      super.paste(sender)
      return
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let context = markdownTableContextProvider?(self) else {
      return super.menu(for: event)
    }

    let menu = super.menu(for: event) ?? NSMenu()
    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
      menu.addItem(.separator())
    }

    let tableMenu = NSMenu(title: String(localized: "Markdown 表格"))
    tableMenu.autoenablesItems = false
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "格式化表格"),
      action: #selector(formatMarkdownTable(_:))
    ))
    tableMenu.addItem(.separator())
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "在上方插入行"),
      action: #selector(insertMarkdownTableRowAbove(_:))
    ))
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "在下方插入行"),
      action: #selector(insertMarkdownTableRowBelow(_:))
    ))
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "删除当前行"),
      action: #selector(deleteMarkdownTableRow(_:)),
      isEnabled: context.canDeleteRow
    ))
    tableMenu.addItem(.separator())
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "在左侧插入列"),
      action: #selector(insertMarkdownTableColumnBefore(_:))
    ))
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "在右侧插入列"),
      action: #selector(insertMarkdownTableColumnAfter(_:))
    ))
    tableMenu.addItem(tableMenuItem(
      title: String(localized: "删除当前列"),
      action: #selector(deleteMarkdownTableColumn(_:)),
      isEnabled: context.canDeleteColumn
    ))

    let tableMenuItem = NSMenuItem(
      title: String(localized: "Markdown 表格"),
      action: nil,
      keyEquivalent: ""
    )
    tableMenuItem.submenu = tableMenu
    menu.addItem(tableMenuItem)
    return menu
  }

  private func tableMenuItem(
    title: String,
    action: Selector,
    isEnabled: Bool = true
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: action,
      keyEquivalent: ""
    )
    item.target = self
    item.isEnabled = isEnabled
    return item
  }

  @objc(formatMarkdownTable:)
  private func formatMarkdownTable(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .format)
  }

  @objc(insertMarkdownTableRowAbove:)
  private func insertMarkdownTableRowAbove(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertRowAbove)
  }

  @objc(insertMarkdownTableRowBelow:)
  private func insertMarkdownTableRowBelow(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertRowBelow)
  }

  @objc(deleteMarkdownTableRow:)
  private func deleteMarkdownTableRow(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .deleteRow)
  }

  @objc(insertMarkdownTableColumnBefore:)
  private func insertMarkdownTableColumnBefore(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertColumnBefore)
  }

  @objc(insertMarkdownTableColumnAfter:)
  private func insertMarkdownTableColumnAfter(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertColumnAfter)
  }

  @objc(deleteMarkdownTableColumn:)
  private func deleteMarkdownTableColumn(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .deleteColumn)
  }

  @objc(applyMarkdownBold:)
  private func applyMarkdownBold(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .bold)
  }

  @objc(applyMarkdownItalic:)
  private func applyMarkdownItalic(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .italic)
  }

  @objc(applyMarkdownLink:)
  private func applyMarkdownLink(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .link)
  }

  @objc(applyMarkdownHeading1:)
  private func applyMarkdownHeading1(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 1))
  }

  @objc(applyMarkdownHeading2:)
  private func applyMarkdownHeading2(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 2))
  }

  @objc(applyMarkdownHeading3:)
  private func applyMarkdownHeading3(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 3))
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateFileDropTarget(using: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateFileDropTarget(using: sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    setFileDropTargeted(false)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !imageFileURLs(from: sender.draggingPasteboard).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { setFileDropTargeted(false) }
    let urls = imageFileURLs(from: sender.draggingPasteboard)
    guard !urls.isEmpty else { return false }
    let dropRange = insertionRange(for: sender)
    setSelectedRange(dropRange)
    fileDropHandler?(urls, dropRange)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    setFileDropTargeted(false)
  }

  private func insertionRange(for sender: NSDraggingInfo) -> NSRange {
    let location = convert(sender.draggingLocation, from: nil)
    let insertionIndex = characterIndexForInsertion(at: location)
    let maxLength = (string as NSString).length
    return NSRange(location: min(max(insertionIndex, 0), maxLength), length: 0)
  }

  private func updateFileDropTarget(using sender: NSDraggingInfo) -> NSDragOperation {
    let acceptsImages = !imageFileURLs(from: sender.draggingPasteboard).isEmpty
    setFileDropTargeted(acceptsImages)
    return acceptsImages ? .copy : []
  }

  private func setFileDropTargeted(_ isTargeted: Bool) {
    guard isFileDropTargeted != isTargeted else { return }
    isFileDropTargeted = isTargeted
    fileDropTargetChangedHandler?(isTargeted)
  }

  private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    MarkdownPasteboardReader.imageFileURLs(from: pasteboard)
  }
}

enum MarkdownFormattingResponderBridge {
  @MainActor
  static func perform(_ command: MarkdownFormattingCommand) -> Bool {
    let selectorName: String
    switch command {
    case .bold:
      selectorName = "applyMarkdownBold:"
    case .italic:
      selectorName = "applyMarkdownItalic:"
    case .link:
      selectorName = "applyMarkdownLink:"
    case .heading(let level):
      guard (1 ... 3).contains(level) else { return false }
      selectorName = "applyMarkdownHeading\(level):"
    }
    return NSApp.sendAction(NSSelectorFromString(selectorName), to: nil, from: nil)
  }
}

private enum MarkdownPasteboardReader {
  struct RichTextContent {
    let html: String
    let baseURL: URL?
  }

  static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
      .compactMap { ($0 as? URL)?.standardizedFileURL }
      .filter(\.isFileURL)
      ?? []
    return ImageFileSupport.supportedImageURLs(in: fileURLs)
  }

  static func pngData(from pasteboard: NSPasteboard) -> Data? {
    if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
      return pngData
    }
    guard let image = NSImage(pasteboard: pasteboard),
          let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }

  static func richTextContent(from pasteboard: NSPasteboard) -> RichTextContent? {
    let baseURL = pasteboard.string(forType: .URL).flatMap { value -> URL? in
      guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme) else {
        return nil
      }
      return url
    }

    if let html = pasteboard.string(forType: .html)?.nilIfEmpty {
      return RichTextContent(html: html, baseURL: baseURL)
    }
    if let data = pasteboard.data(forType: .html),
       let html = decodedHTML(data)?.nilIfEmpty {
      return RichTextContent(html: html, baseURL: baseURL)
    }
    if let attributed = attributedString(from: pasteboard, type: .rtf, documentType: .rtf) {
      return RichTextContent(
        html: semanticHTML(from: attributed),
        baseURL: baseURL
      )
    }
    if let attributed = attributedString(from: pasteboard, type: .rtfd, documentType: .rtfd) {
      return RichTextContent(
        html: semanticHTML(from: attributed),
        baseURL: baseURL
      )
    }
    return nil
  }

  static func shouldPreferRichConversion(
    _ markdown: String,
    over plainText: String?
  ) -> Bool {
    guard let plainText else { return true }
    return normalizedPasteComparison(markdown) != normalizedPasteComparison(plainText)
  }

  private static func attributedString(
    from pasteboard: NSPasteboard,
    type: NSPasteboard.PasteboardType,
    documentType: NSAttributedString.DocumentType
  ) -> NSAttributedString? {
    guard let data = pasteboard.data(forType: type), !data.isEmpty else { return nil }
    return try? NSAttributedString(
      data: data,
      options: [.documentType: documentType],
      documentAttributes: nil
    )
  }

  private static func decodedHTML(_ data: Data) -> String? {
    for encoding in [
      String.Encoding.utf8,
      .utf16,
      .unicode,
      .windowsCP1252,
      .isoLatin1,
    ] {
      if let value = String(data: data, encoding: encoding), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func semanticHTML(from attributed: NSAttributedString) -> String {
    let source = attributed.string as NSString
    guard source.length > 0 else { return "" }
    var html = "<article>"
    var cursor = 0
    var openList: RichTextListKind?

    func closeOpenList() {
      if let openList {
        html += openList == .ordered ? "</ol>" : "</ul>"
      }
      openList = nil
    }

    while cursor < source.length {
      let paragraphRange = source.paragraphRange(
        for: NSRange(location: cursor, length: 0)
      )
      var contentRange = paragraphRange
      while contentRange.length > 0,
            source.substring(
              with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)
            ).rangeOfCharacter(from: .newlines) != nil {
        contentRange.length -= 1
      }
      let plainParagraph = source.substring(with: contentRange)
      let list = richTextListKind(
        for: attributed,
        paragraphRange: contentRange,
        plainText: plainParagraph
      )
      let markerLength = listMarkerLength(in: plainParagraph, kind: list)
      let semanticRange = NSRange(
        location: min(NSMaxRange(contentRange), contentRange.location + markerLength),
        length: max(0, contentRange.length - markerLength)
      )
      let inline = semanticInlineHTML(from: attributed, range: semanticRange)

      if let list {
        if openList != list {
          closeOpenList()
          html += list == .ordered ? "<ol>" : "<ul>"
          openList = list
        }
        html += "<li>\(inline)</li>"
      } else {
        closeOpenList()
        let headingLevel = inferredHeadingLevel(in: attributed, range: contentRange)
        if let headingLevel, !inline.isEmpty {
          html += "<h\(headingLevel)>\(inline)</h\(headingLevel)>"
        } else {
          html += "<p>\(inline)</p>"
        }
      }
      cursor = NSMaxRange(paragraphRange)
    }
    closeOpenList()
    html += "</article>"
    return html
  }

  private static func semanticInlineHTML(
    from attributed: NSAttributedString,
    range: NSRange
  ) -> String {
    guard range.length > 0 else { return "" }
    var html = ""
    attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
      var fragment = escapedHTML((attributed.string as NSString).substring(with: runRange))
      guard !fragment.isEmpty else { return }
      let font = attributes[.font] as? NSFont
      let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
      if font?.isFixedPitch == true {
        fragment = "<code>\(fragment)</code>"
      }
      if traits.contains(.boldFontMask) {
        fragment = "<strong>\(fragment)</strong>"
      }
      if traits.contains(.italicFontMask) {
        fragment = "<em>\(fragment)</em>"
      }
      if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
        fragment = "<del>\(fragment)</del>"
      }
      if let linkValue = attributes[.link] {
        let destination = (linkValue as? URL)?.absoluteString
          ?? (linkValue as? String)
        if let destination = destination?.nilIfEmpty {
          fragment = "<a href=\"\(escapedHTMLAttribute(destination))\">\(fragment)</a>"
        }
      }
      html += fragment
    }
    return html
  }

  private static func inferredHeadingLevel(
    in attributed: NSAttributedString,
    range: NSRange
  ) -> Int? {
    guard range.length > 0 else { return nil }
    var maximumSize: CGFloat = 0
    var containsBold = false
    attributed.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
      guard let font = value as? NSFont else { return }
      maximumSize = max(maximumSize, font.pointSize)
      containsBold = containsBold
        || NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }
    if maximumSize >= 24 { return 1 }
    if maximumSize >= 19 { return 2 }
    if maximumSize >= 16, containsBold { return 3 }
    return nil
  }

  private static func richTextListKind(
    for attributed: NSAttributedString,
    paragraphRange: NSRange,
    plainText: String
  ) -> RichTextListKind? {
    if paragraphRange.length > 0,
       let style = attributed.attribute(
         .paragraphStyle,
         at: paragraphRange.location,
         effectiveRange: nil
       ) as? NSParagraphStyle,
       let marker = style.textLists.first?.markerFormat.rawValue.lowercased() {
      return marker.contains("decimal")
        || marker.contains("roman")
        || marker.contains("alpha")
        ? .ordered
        : .unordered
    }
    let trimmed = plainText.trimmingCharacters(in: .whitespaces)
    if trimmed.range(of: #"^\d+[\.)][ \t]+"#, options: .regularExpression) != nil {
      return .ordered
    }
    if trimmed.range(of: #"^[•◦▪‣⁃\-+*][ \t]+"#, options: .regularExpression) != nil {
      return .unordered
    }
    return nil
  }

  private static func listMarkerLength(
    in plainText: String,
    kind: RichTextListKind?
  ) -> Int {
    guard kind != nil else { return 0 }
    let source = plainText as NSString
    let pattern = kind == .ordered
      ? #"^[ \t]*\d+[\.)][ \t]+"#
      : #"^[ \t]*[•◦▪‣⁃\-+*][ \t]+"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: plainText,
            range: NSRange(location: 0, length: source.length)
          ) else {
      return 0
    }
    return match.range.length
  }

  private static func normalizedPasteComparison(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func escapedHTML(_ value: String) -> String {
    escapedHTMLAttribute(value)
  }

  private static func escapedHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private enum RichTextListKind: Equatable {
    case ordered
    case unordered
  }
}

struct MarkdownEditorStatistics: Equatable, Sendable {
  let characterCount: Int
  let hanCharacterCount: Int
  let wordCount: Int
  let lineCount: Int
  private let lineBreakCount: Int
  private let nonWhitespaceCharacterCount: Int

  static let empty = MarkdownEditorStatistics(
    characterCount: 0,
    hanCharacterCount: 0,
    wordCount: 0,
    lineCount: 0,
    lineBreakCount: 0,
    nonWhitespaceCharacterCount: 0
  )

  var writingUnitCount: Int {
    hanCharacterCount + wordCount
  }

  var readingMinutes: Int {
    MarkdownWritingStatistics(
      hanCharacterCount: hanCharacterCount,
      wordCount: wordCount
    ).estimatedReadingMinutes
  }

  static func make(for text: String) -> MarkdownEditorStatistics {
    let string = text as NSString
    let characterCount = string.length
    let lineBreakCount = text.utf16.reduce(into: 0) { count, value in
      if value == 10 { count += 1 }
    }
    let nonWhitespaceCharacterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
    }
    let writingStatistics = MarkdownWritingStatisticsService.statistics(in: text)
    return MarkdownEditorStatistics(
      characterCount: characterCount,
      hanCharacterCount: writingStatistics.hanCharacterCount,
      wordCount: writingStatistics.wordCount,
      lineCount: nonWhitespaceCharacterCount == 0 ? 0 : lineBreakCount + 1,
      lineBreakCount: lineBreakCount,
      nonWhitespaceCharacterCount: nonWhitespaceCharacterCount
    )
  }

  func applying(
    replacing previousRange: NSRange,
    in previousText: String,
    with updatedRange: NSRange,
    in updatedText: String
  ) -> MarkdownEditorStatistics {
    let previous = previousText as NSString
    let updated = updatedText as NSString
    guard previousRange.location >= 0,
          NSMaxRange(previousRange) <= previous.length,
          updatedRange.location >= 0,
          NSMaxRange(updatedRange) <= updated.length,
          characterCount == previous.length else {
      return Self.make(for: updatedText)
    }

    let removedText = previous.substring(with: previousRange)
    let insertedText = updated.substring(with: updatedRange)
    let previousWordRange = Self.wordContextRange(around: previousRange, in: previous)
    let updatedWordRange = Self.wordContextRange(around: updatedRange, in: updated)
    let previousWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: previous.substring(with: previousWordRange)
    )
    let updatedWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: updated.substring(with: updatedWordRange)
    )
    let updatedHanCharacterCount = max(
      0,
      hanCharacterCount - previousWritingStatistics.hanCharacterCount
        + updatedWritingStatistics.hanCharacterCount
    )
    let updatedWordCount = max(
      0,
      wordCount - previousWritingStatistics.wordCount
        + updatedWritingStatistics.wordCount
    )
    let updatedLineBreakCount = max(
      0,
      lineBreakCount - Self.lineBreakCount(in: removedText) + Self.lineBreakCount(in: insertedText)
    )
    let updatedNonWhitespaceCount = max(
      0,
      nonWhitespaceCharacterCount
        - Self.nonWhitespaceCharacterCount(in: removedText)
        + Self.nonWhitespaceCharacterCount(in: insertedText)
    )
    let updatedCharacterCount = updated.length
    return MarkdownEditorStatistics(
      characterCount: updatedCharacterCount,
      hanCharacterCount: updatedHanCharacterCount,
      wordCount: updatedWordCount,
      lineCount: updatedNonWhitespaceCount == 0 ? 0 : updatedLineBreakCount + 1,
      lineBreakCount: updatedLineBreakCount,
      nonWhitespaceCharacterCount: updatedNonWhitespaceCount
    )
  }

  private static let wordSeparators = CharacterSet.whitespacesAndNewlines
    .union(.punctuationCharacters)
    .union(.symbols)

  private static func lineBreakCount(in text: String) -> Int {
    text.utf16.reduce(into: 0) { count, value in
      if value == 10 { count += 1 }
    }
  }

  private static func nonWhitespaceCharacterCount(in text: String) -> Int {
    text.unicodeScalars.reduce(into: 0) { count, scalar in
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
    }
  }

  private static func wordContextRange(around range: NSRange, in text: NSString) -> NSRange {
    var start = min(max(range.location, 0), text.length)
    var end = min(max(NSMaxRange(range), start), text.length)
    while start > 0, !isWordSeparator(text.character(at: start - 1)) {
      start -= 1
    }
    while end < text.length, !isWordSeparator(text.character(at: end)) {
      end += 1
    }
    return NSRange(location: start, length: end - start)
  }

  private static func isWordSeparator(_ value: unichar) -> Bool {
    UnicodeScalar(UInt32(value)).map(wordSeparators.contains) ?? false
  }
}

private struct MarkdownTextEdit {
  let previousText: String
  let replacedRange: NSRange
}

@MainActor
private struct MarkdownTextViewSyntaxPalette {
  let fontSize: Double
  let lineSpacing: Double
  let baseFont: NSFont
  let defaultAttributes: [NSAttributedString.Key: Any]
  let styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]

  init(configuration: MarkdownEditorComfortConfiguration) {
    fontSize = configuration.fontSize
    lineSpacing = configuration.lineSpacing
    let baseFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .regular
    )
    let codeFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .medium
    )
    let emphasizedFont = NSFont.monospacedSystemFont(
      ofSize: CGFloat(configuration.fontSize),
      weight: .semibold
    )
    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = CGFloat(configuration.lineSpacing)

    self.baseFont = baseFont
    defaultAttributes = [
      .font: baseFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
    styleAttributes = [
      .heading: [
        .foregroundColor: WorkbenchThemeNSColor.primary,
        .font: emphasizedFont
      ],
      .codeBlock: [
        .font: codeFont,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.18)
      ],
      .link: [
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor
      ],
      .list: [
        .foregroundColor: WorkbenchThemeNSColor.success
      ],
      .quote: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.08)
      ],
      .bold: [
        .font: emphasizedFont
      ],
      .italic: [
        .font: italicFont
      ],
      .inlineCode: [
        .font: codeFont,
        .foregroundColor: WorkbenchThemeNSColor.warning
      ]
    ]
  }

  func matches(_ configuration: MarkdownEditorComfortConfiguration) -> Bool {
    fontSize == configuration.fontSize && lineSpacing == configuration.lineSpacing
  }
}
