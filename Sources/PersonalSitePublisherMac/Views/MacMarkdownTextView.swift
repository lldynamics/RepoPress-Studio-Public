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

    let didReceiveChangedText = context.coordinator.updateRepresentedText(text)
    let didReplaceText = didReceiveChangedText && textView.string != text
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
    private var representedText: String
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
      representedText = text.wrappedValue
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

    func updateRepresentedText(_ text: String) -> Bool {
      guard representedText != text else { return false }
      representedText = text
      return true
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
      representedText = updatedText
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
      performTypewriterScrollIfNeeded(in: textView)
      updateCurrentParagraphHighlight(in: textView)
      centerSelectionIfNeeded(in: textView)
    }

    func performTypewriterScrollIfNeeded(in textView: NSTextView) {
      guard comfortConfiguration.typewriterModeEnabled,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let clipView = textView.enclosingScrollView?.contentView else { return }

      let selectedRange = textView.selectedRange()
      let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
      let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

      let targetY = lineRect.midY - (clipView.bounds.height / 2.2)
      let clampedY = max(0, min(targetY, textView.bounds.height - clipView.bounds.height))

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.10
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
      }
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
      let bodyUTF16Offset = self.bodyUTF16Offset
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
          guard let parsedSnapshot = await syntaxHighlightParser.snapshot(
            in: text,
            range: resolvedPlan.range
          ) else {
            return nil
          }
          let snapshot = MarkdownSyntaxHighlightSnapshot(
            range: parsedSnapshot.range,
            runs: parsedSnapshot.runs.filter { run in
              run.style != .html || run.range.location >= bodyUTF16Offset
            }
          )
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
