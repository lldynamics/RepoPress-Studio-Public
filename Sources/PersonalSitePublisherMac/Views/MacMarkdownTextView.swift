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
  let isAnimated: Bool

  init(id: UUID, selectedRange: NSRange, isAnimated: Bool = false) {
    self.id = id
    self.selectedRange = selectedRange
    self.isAnimated = isAnimated
  }
}

struct MarkdownSyntaxHighlightComputation: Sendable {
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
  var ghostText: String
  var ssgSnippets: [MarkdownSnippet]
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var onStatisticsChanged: (MarkdownEditorStatistics) -> Void
  var onFileDropTargetChanged: (Bool) -> Void
  var onPasteMessage: (String) -> Void
  var onEditRequestHandled: (UUID) -> Void
  var onGhostTextAccepted: (String) -> Void
  var onGhostTextDismissed: () -> Void
  var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
  var onSlashCommandKey: (MarkdownSlashCommandKey) -> Bool = { _ in false }
  var onTypingFeedback: () -> Void = {}
  var onScrollProgressChanged: (Double) -> Void
  var onDroppedFiles: ([URL]) -> Void
  var onDroppedMarkdown: (String, NSRange, KnowledgeCitation?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: $selectedRange,
      isFrontMatterSelection: $isFrontMatterSelection,
      comfortConfiguration: comfortConfiguration,
      diagnostics: diagnostics,
      ghostText: ghostText,
      ssgSnippets: ssgSnippets,
      onStatisticsChanged: onStatisticsChanged,
      onPasteMessage: onPasteMessage,
      onGhostTextAccepted: onGhostTextAccepted,
      onGhostTextDismissed: onGhostTextDismissed,
      onSSGSnippetShortcut: onSSGSnippetShortcut,
      onScrollProgressChanged: onScrollProgressChanged,
      onDroppedFiles: onDroppedFiles,
      onDroppedMarkdown: onDroppedMarkdown
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
    textView.fileDropTargetChangedHandler = onFileDropTargetChanged
    textView.fileDropHandler = { urls, dropRange in
      context.coordinator.handleDroppedFiles(urls, at: dropRange)
    }
    textView.knowledgeMarkdownDropHandler = { markdown, dropRange, citation in
      context.coordinator.handleDroppedMarkdown(markdown, at: dropRange, citation: citation)
    }
    textView.smartPasteHandler = { textView, pasteboard in
      context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
    }
    textView.markdownFormattingHandler = { textView, command in
      context.coordinator.handleFormatting(command, in: textView)
    }
    textView.markdownLineEditingHandler = { textView, command in
      context.coordinator.handleLineEditing(command, in: textView)
    }
    textView.markdownTableContextProvider = { textView in
      context.coordinator.tableContext(in: textView)
    }
    textView.markdownTableEditingHandler = { textView, command in
      context.coordinator.handleTableEditing(command, in: textView)
    }
    textView.slashCommandKeyHandler = onSlashCommandKey
    textView.typingFeedbackHandler = onTypingFeedback
    textView.string = text
    let initialSelection =
      isFrontMatterSelection
      ? Self.clamped(selectedRange, length: (text as NSString).length)
      : documentRange(
        forBodyRange: selectedRange,
        bodyUTF16Offset: bodyUTF16Offset,
        documentLength: (text as NSString).length
      )
    textView.setSelectedRange(initialSelection)
    // Install the delegate only after the represented text and selection are
    // synchronized. AppKit emits selection callbacks while assigning the
    // initial string; writing those values back into @Published bindings from
    // makeNSView would publish during SwiftUI's current update transaction.
    textView.delegate = context.coordinator
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
      size: NSSize(
        width: max(scrollView.contentSize.width, 1), height: max(scrollView.contentSize.height, 1))
    )
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [NSView.AutoresizingMask.width]
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false

    context.coordinator.installGhostTextOverlay(on: textView)
    scrollView.documentView = textView
    context.coordinator.observeScrolling(in: scrollView)
    context.coordinator.scheduleFullStatistics(for: bodyMarkdown)
    context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    context.coordinator.updateDiagnostics(diagnostics, in: textView, force: true)
    context.coordinator.updateCurrentParagraphHighlight(in: textView, force: true)
    context.coordinator.updateGhostText(ghostText, in: textView)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    textView.isEditable = true
    textView.isSelectable = true
    context.coordinator.updateDocumentContext(
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset
    )
    context.coordinator.ssgSnippets = ssgSnippets
    context.coordinator.onGhostTextAccepted = onGhostTextAccepted
    context.coordinator.onGhostTextDismissed = onGhostTextDismissed
    context.coordinator.onSSGSnippetShortcut = onSSGSnippetShortcut
    context.coordinator.applyComfortConfiguration(
      comfortConfiguration,
      in: textView
    )
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.fileDropTargetChangedHandler = onFileDropTargetChanged
      droppableTextView.knowledgeMarkdownDropHandler = { markdown, dropRange, citation in
        context.coordinator.handleDroppedMarkdown(markdown, at: dropRange, citation: citation)
      }
      droppableTextView.smartPasteHandler = { textView, pasteboard in
        context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
      }
      droppableTextView.markdownFormattingHandler = { textView, command in
        context.coordinator.handleFormatting(command, in: textView)
      }
      droppableTextView.markdownLineEditingHandler = { textView, command in
        context.coordinator.handleLineEditing(command, in: textView)
      }
      droppableTextView.markdownTableContextProvider = { textView in
        context.coordinator.tableContext(in: textView)
      }
      droppableTextView.markdownTableEditingHandler = { textView, command in
        context.coordinator.handleTableEditing(command, in: textView)
      }
      droppableTextView.slashCommandKeyHandler = onSlashCommandKey
      droppableTextView.typingFeedbackHandler = onTypingFeedback
      droppableTextView.ghostTextAcceptHandler = {
        guard !context.coordinator.ghostText.isEmpty else { return false }
        context.coordinator.onGhostTextAccepted(context.coordinator.ghostText)
        return true
      }
      droppableTextView.ghostTextDismissHandler = {
        guard !context.coordinator.ghostText.isEmpty else { return false }
        context.coordinator.onGhostTextDismissed()
        return true
      }
    }

    let didReceiveChangedText = context.coordinator.updateRepresentedText(text)
    let didReplaceText = didReceiveChangedText && textView.string != text
    if didReplaceText {
      let currentDocumentRange = textView.selectedRange()
      textView.string = text
      (nsView as? MarkdownEditorScrollView)?.invalidateDocumentHeight(immediately: true)
      let replacementRange =
        isFrontMatterSelection
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
      let shouldAnimateFocus =
        focusRequest?.isAnimated == true
        && focusRequest?.selectedRange == selectedRange
      if textView.selectedRange() != range {
        textView.setSelectedRange(range)
        if !shouldAnimateFocus {
          textView.scrollRangeToVisible(range)
        }
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
    context.coordinator.updateGhostText(ghostText, in: textView)
    if let handledRequestID = context.coordinator.handle(editRequest, in: textView) {
      DispatchQueue.main.async {
        onEditRequestHandled(handledRequestID)
      }
    }
    context.coordinator.requestKeyboardFocus(focusRequest, in: textView)
    context.coordinator.applySynchronizedScroll(scrollSyncUpdate, in: nsView)
    context.coordinator.applyRestoredScroll(scrollRestorationUpdate, in: nsView)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var isFrontMatterSelection: Bool
    var bodyMarkdown: String
    var bodyUTF16Offset: Int
    var representedText: String
    let onStatisticsChanged: (MarkdownEditorStatistics) -> Void
    let onPasteMessage: (String) -> Void
    var onGhostTextAccepted: (String) -> Void
    var onGhostTextDismissed: () -> Void
    var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
    let onScrollProgressChanged: (Double) -> Void
    let onDroppedFiles: ([URL]) -> Void
    let onDroppedMarkdown: (String, NSRange, KnowledgeCitation?) -> Void
    weak var textView: NSTextView?
    let syntaxHighlightDebouncer = MarkdownSyntaxHighlightDebouncer()
    var syntaxAttributeApplicationTask: Task<Void, Never>?
    var syntaxAttributeApplicationGeneration: UInt64 = 0
    var highlightedTextCache: String?
    var pendingSyntaxHighlightPlan: MarkdownSyntaxHighlightPlan?
    var syntaxCodeBlockRanges: [NSRange]?
    let syntaxHighlightParser = MarkdownSyntaxHighlightParser()
    let syntaxHighlightSignposter = OSSignposter(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    let syntaxHighlightLogger = Logger(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    var hasLoggedSyntaxTelemetryActivation = false
    var statisticsTask: Task<Void, Never>?
    var statisticsGeneration = 0
    var statisticsText: String?
    var statistics = MarkdownEditorStatistics.empty
    var pendingTextEdit: MarkdownTextEdit?
    var lastAppliedEditRequestID: UUID?
    var pendingFocusRequest: MarkdownTextFocusRequest?
    var lastAppliedFocusRequestID: UUID?
    var focusRequestTask: Task<Void, Never>?
    var ghostText = ""
    var ssgSnippets: [MarkdownSnippet]
    weak var ghostTextOverlayView: MarkdownGhostTextOverlayView?
    var comfortConfiguration: MarkdownEditorComfortConfiguration
    var syntaxHighlightPalette: MarkdownTextViewSyntaxPalette
    var diagnostics: [MarkdownInlineDiagnostic]
    var appliedParagraphHighlightRange: NSRange?
    var appliedDiagnosticOverlays: [MarkdownEditorDiagnosticOverlay] = []
    let scrollSyncBridge: MarkdownScrollViewSyncBridge
    let smartEditingService = MarkdownSmartEditingService()
    let smartPasteService = MarkdownSmartPasteService()
    let richTextPasteService = MarkdownRichTextPasteService()
    let formattingService = MarkdownFormattingService()
    let advancedEditingService = MarkdownAdvancedEditingService()
    let tableEditingService = MarkdownTableEditingService()
    let pastedImageFileStore = PastedImageFileStore()
    let statisticsDelay: TimeInterval = 0.18
    var isApplyingAutomaticPairing = false

    init(
      text: Binding<String>,
      bodyMarkdown: String,
      bodyUTF16Offset: Int,
      selectedRange: Binding<NSRange>,
      isFrontMatterSelection: Binding<Bool>,
      comfortConfiguration: MarkdownEditorComfortConfiguration,
      diagnostics: [MarkdownInlineDiagnostic],
      ghostText: String,
      ssgSnippets: [MarkdownSnippet],
      onStatisticsChanged: @escaping (MarkdownEditorStatistics) -> Void,
      onPasteMessage: @escaping (String) -> Void,
      onGhostTextAccepted: @escaping (String) -> Void,
      onGhostTextDismissed: @escaping () -> Void,
      onSSGSnippetShortcut: @escaping (MarkdownCompletionCandidate) -> Void,
      onScrollProgressChanged: @escaping (Double) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void,
      onDroppedMarkdown: @escaping (String, NSRange, KnowledgeCitation?) -> Void
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
      self.onGhostTextAccepted = onGhostTextAccepted
      self.onGhostTextDismissed = onGhostTextDismissed
      self.onSSGSnippetShortcut = onSSGSnippetShortcut
      self.onScrollProgressChanged = onScrollProgressChanged
      self.onDroppedFiles = onDroppedFiles
      self.onDroppedMarkdown = onDroppedMarkdown
      self.ghostText = ghostText
      self.ssgSnippets = ssgSnippets
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .editor,
        onProgressChanged: onScrollProgressChanged
      )
    }

    convenience init(
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
      self.init(
        text: text,
        bodyMarkdown: bodyMarkdown,
        bodyUTF16Offset: bodyUTF16Offset,
        selectedRange: selectedRange,
        isFrontMatterSelection: isFrontMatterSelection,
        comfortConfiguration: comfortConfiguration,
        diagnostics: diagnostics,
        ghostText: "",
        ssgSnippets: [],
        onStatisticsChanged: onStatisticsChanged,
        onPasteMessage: onPasteMessage,
        onGhostTextAccepted: { _ in },
        onGhostTextDismissed: {},
        onSSGSnippetShortcut: { _ in },
        onScrollProgressChanged: onScrollProgressChanged,
        onDroppedFiles: onDroppedFiles,
        onDroppedMarkdown: { _, _, _ in }
      )
    }

    func updateDocumentContext(bodyMarkdown: String, bodyUTF16Offset: Int) {
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
    }

    func installGhostTextOverlay(on textView: NSTextView) {
      let overlay = MarkdownGhostTextOverlayView(frame: textView.bounds)
      overlay.autoresizingMask = [.width, .height]
      overlay.textView = textView
      overlay.isHidden = ghostText.isEmpty
      overlay.setAccessibilityLabel("AI 预测续写")
      overlay.setAccessibilityHelp("按 Tab 采纳预测内容，按 Escape 忽略预测内容")
      overlay.setAccessibilityValue(ghostText)
      textView.addSubview(overlay)
      ghostTextOverlayView = overlay
    }

    func updateGhostText(_ text: String, in textView: NSTextView) {
      let didChange = ghostText != text
      ghostText = text
      if ghostTextOverlayView == nil {
        installGhostTextOverlay(on: textView)
      }
      guard let overlay = ghostTextOverlayView else { return }
      overlay.textView = textView
      if didChange {
        overlay.ghostText = text
        overlay.setAccessibilityValue(text)
      }
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

    func handleDroppedMarkdown(
      _ markdown: String,
      at documentRange: NSRange,
      citation: KnowledgeCitation?
    ) {
      guard documentRange.location >= bodyUTF16Offset else { return }
      let range = bodyRange(from: documentRange)
      selectedRange = range
      isFrontMatterSelection = false
      onDroppedMarkdown(markdown, range, citation)
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
        if !isFrontMatterSelection {
          isFrontMatterSelection = true
        }
        let nextRange = NSRange(location: 0, length: 0)
        if !NSEqualRanges(selectedRange, nextRange) {
          selectedRange = nextRange
        }
      } else {
        if isFrontMatterSelection {
          isFrontMatterSelection = false
        }
        let nextRange = bodyRange(from: documentRange)
        if !NSEqualRanges(selectedRange, nextRange) {
          selectedRange = nextRange
        }
      }
    }

    private struct DocumentParts {
      let bodyMarkdown: String
      let bodyUTF16Offset: Int
    }

    private static func documentParts(in source: String) -> DocumentParts? {
      let sourceText = source as NSString
      guard sourceText.length > 0 else { return nil }

      var firstLineStart = 0
      var firstLineEnd = 0
      var firstContentsEnd = 0
      sourceText.getLineStart(
        &firstLineStart,
        end: &firstLineEnd,
        contentsEnd: &firstContentsEnd,
        for: NSRange(location: 0, length: 0)
      )
      let delimiter = sourceText.substring(
        with: NSRange(location: firstLineStart, length: firstContentsEnd - firstLineStart)
      ).trimmedForPublishing
      guard delimiter == "---" || delimiter == "+++" else { return nil }

      var location = firstLineEnd
      while location < sourceText.length {
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        sourceText.getLineStart(
          &lineStart,
          end: &lineEnd,
          contentsEnd: &contentsEnd,
          for: NSRange(location: location, length: 0)
        )
        let line = sourceText.substring(
          with: NSRange(location: lineStart, length: contentsEnd - lineStart)
        )
        guard line.trimmedForPublishing == delimiter else {
          location = max(lineEnd, location + 1)
          continue
        }

        var bodyOffset = lineEnd
        if bodyOffset < sourceText.length {
          var nextLineStart = 0
          var nextLineEnd = 0
          var nextContentsEnd = 0
          sourceText.getLineStart(
            &nextLineStart,
            end: &nextLineEnd,
            contentsEnd: &nextContentsEnd,
            for: NSRange(location: bodyOffset, length: 0)
          )
          if nextContentsEnd == nextLineStart {
            bodyOffset = nextLineEnd
          }
        }
        return DocumentParts(
          bodyMarkdown: sourceText.substring(from: bodyOffset),
          bodyUTF16Offset: bodyOffset
        )
      }
      return nil
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
      let desiredAttributes = syntaxHighlightPalette.defaultAttributes
      guard !(textView.typingAttributes as NSDictionary).isEqual(to: desiredAttributes) else {
        return
      }
      textView.typingAttributes = desiredAttributes
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
      if !isApplyingAutomaticPairing,
        comfortConfiguration.automaticPairingEnabled,
        !textView.hasMarkedText(),
        let replacementString,
        !replacementString.isEmpty,
        affectedCharRange.location >= bodyUTF16Offset,
        let pairingEdit = automaticPairingEdit(
          in: textView,
          affectedDocumentRange: affectedCharRange,
          typedText: replacementString
        )
      {
        isApplyingAutomaticPairing = true
        defer { isApplyingAutomaticPairing = false }
        apply(pairingEdit, in: textView)
        return false
      }
      pendingTextEdit = MarkdownTextEdit(
        previousText: textView.string,
        replacedRange: affectedCharRange
      )
      return true
    }

    private func automaticPairingEdit(
      in textView: NSTextView,
      affectedDocumentRange: NSRange,
      typedText: String
    ) -> MarkdownSmartEdit? {
      guard
        typedText.utf16.count <= 3,
        !typedText.contains(where: \.isNewline)
      else {
        return nil
      }
      let document = textView.string as NSString
      guard
        bodyUTF16Offset <= document.length,
        NSMaxRange(affectedDocumentRange) <= document.length
      else {
        return nil
      }
      let body = document.substring(from: bodyUTF16Offset)
      let bodyRange = NSRange(
        location: affectedDocumentRange.location - bodyUTF16Offset,
        length: affectedDocumentRange.length
      )

      if typedText == "\"" || typedText == "'",
        bodyRange.length == 0,
        bodyRange.location > 0
      {
        let bodySource = body as NSString
        let previous = bodySource.substring(
          with: NSRange(location: bodyRange.location - 1, length: 1)
        )
        if previous.unicodeScalars.allSatisfy(
          CharacterSet.alphanumerics.contains
        ) {
          return nil
        }
      }

      guard
        let bodyEdit = advancedEditingService.pairingEdit(
          in: body,
          selectedRange: bodyRange,
          typedText: typedText
        )
      else {
        return nil
      }
      return MarkdownSmartEdit(
        replacedRange: NSRange(
          location: bodyUTF16Offset + bodyEdit.replacedRange.location,
          length: bodyEdit.replacedRange.length
        ),
        replacement: bodyEdit.replacement,
        selectedRange: NSRange(
          location: bodyUTF16Offset + bodyEdit.selectedRange.location,
          length: bodyEdit.selectedRange.length
        )
      )
    }

    func handlePaste(
      in textView: NSTextView,
      pasteboard: any MarkdownPasteboardSource
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
        )
      {
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
        )
      else {
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
      guard
        let edit = formattingService.edit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    func handleLineEditing(
      _ command: MarkdownLineEditingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        NSSound.beep()
        return true
      }
      guard
        let edit = advancedEditingService.lineEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
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
      guard
        let edit = tableEditingService.edit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
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
        request.id != lastAppliedEditRequestID
      else {
        return nil
      }

      lastAppliedEditRequestID = request.id
      guard bodyMarkdown == request.expectedText else {
        return request.id
      }

      let textLength = (bodyMarkdown as NSString).length
      guard request.edit.replacedRange.location >= 0,
        NSMaxRange(request.edit.replacedRange) <= textLength
      else {
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
            self.pendingFocusRequest?.id == request.id
          else {
            return
          }
          guard let window = textView.window,
            window.attachedSheet == nil
          else {
            continue
          }

          let bodyRange = MacMarkdownTextView.clamped(
            request.selectedRange,
            length: (self.bodyMarkdown as NSString).length
          )
          let range = self.documentRange(from: bodyRange)
          textView.setSelectedRange(range)
          self.scrollToRange(
            range,
            in: textView,
            animated: request.isAnimated
          )
          let didFocus =
            window.firstResponder === textView
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

    func scrollToRange(
      _ range: NSRange,
      in textView: NSTextView,
      animated: Bool
    ) {
      guard animated,
        let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer,
        let clipView = textView.enclosingScrollView?.contentView
      else {
        textView.scrollRangeToVisible(range)
        return
      }

      layoutManager.ensureLayout(for: textContainer)
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: range,
        actualCharacterRange: nil
      )
      let targetRect = layoutManager.boundingRect(
        forGlyphRange: glyphRange,
        in: textContainer
      )
      let targetY = targetRect.minY - 24
      let maximumY = max(0, textView.bounds.height - clipView.bounds.height)
      let clampedY = min(max(0, targetY), maximumY)

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.24
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        clipView.animator().setBoundsOrigin(
          NSPoint(x: clipView.bounds.origin.x, y: clampedY)
        )
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
      let updatedSource = updatedText as NSString
      if let pendingTextEdit,
        pendingTextEdit.replacedRange.location >= bodyUTF16Offset,
        bodyUTF16Offset <= updatedSource.length
      {
        bodyMarkdown = updatedSource.substring(from: bodyUTF16Offset)
      } else if let parts = Self.documentParts(in: updatedText) {
        bodyMarkdown = parts.bodyMarkdown
        bodyUTF16Offset = parts.bodyUTF16Offset
      } else {
        bodyMarkdown = updatedText
        bodyUTF16Offset = 0
      }
      representedText = updatedText
      text = updatedText
      let documentSelection = textView.selectedRange()
      updateSelectionBinding(from: documentSelection)
      if documentSelection.location >= bodyUTF16Offset,
        documentSelection.length == 0,
        let shortcutCandidate = MarkdownCursorCompletionService().automaticShortcutCandidate(
          in: bodyMarkdown,
          selectedRange: bodyRange(from: documentSelection),
          snippets: ssgSnippets
        )
      {
        onSSGSnippetShortcut(shortcutCandidate)
      }
      updateGhostText(ghostText, in: textView)
      updateStatistics(afterEditing: bodyMarkdown)
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
      updateGhostText(ghostText, in: textView)
      performTypewriterScrollIfNeeded(in: textView)
      updateCurrentParagraphHighlight(in: textView)
    }

    func performTypewriterScrollIfNeeded(in textView: NSTextView) {
      guard comfortConfiguration.typewriterModeEnabled,
        let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer,
        let clipView = textView.enclosingScrollView?.contentView
      else { return }

      let selectedRange = textView.selectedRange()
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: selectedRange, actualCharacterRange: nil)
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
      if commandSelector == #selector(NSResponder.insertTab(_:)),
        !ghostText.isEmpty,
        textView.selectedRange().length == 0
      {
        let acceptedText = ghostText
        textView.insertText(acceptedText, replacementRange: textView.selectedRange())
        ghostText = ""
        ghostTextOverlayView?.ghostText = ""
        onGhostTextAccepted(acceptedText)
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)),
        !ghostText.isEmpty
      {
        ghostText = ""
        ghostTextOverlayView?.ghostText = ""
        onGhostTextDismissed()
        return true
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

  }
}
