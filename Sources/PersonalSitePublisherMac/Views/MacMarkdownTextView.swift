import AppKit
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

struct MacMarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var selectedRange: NSRange
  var editRequest: MarkdownTextEditRequest?
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var onStatisticsChanged: (MarkdownEditorStatistics) -> Void
  var onFileDropTargetChanged: (Bool) -> Void
  var onPasteMessage: (String) -> Void
  var onEditRequestHandled: (UUID) -> Void
  var onScrollProgressChanged: (Double) -> Void
  var onDroppedFiles: ([URL]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      selectedRange: $selectedRange,
      onStatisticsChanged: onStatisticsChanged,
      onPasteMessage: onPasteMessage,
      onScrollProgressChanged: onScrollProgressChanged,
      onDroppedFiles: onDroppedFiles
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MarkdownEditorScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = NSColor.textBackgroundColor

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
    textContainer.widthTracksTextView = true
    textContainer.heightTracksTextView = false

    let textView = DroppableMarkdownTextView(frame: .zero, textContainer: textContainer)
    precondition(textView.layoutManager != nil, "Markdown editor requires a complete TextKit stack")
    textView.delegate = context.coordinator
    textView.fileDropTargetChangedHandler = onFileDropTargetChanged
    textView.fileDropHandler = { urls, dropRange in
      context.coordinator.selectedRange = dropRange
      context.coordinator.onDroppedFiles(urls)
    }
    textView.smartPasteHandler = { textView, pasteboard in
      context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
    }
    textView.markdownFormattingHandler = { textView, command in
      context.coordinator.handleFormatting(command, in: textView)
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
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.font = MarkdownTextViewSyntaxHighlighter.baseFont
    textView.textColor = NSColor.labelColor
    textView.insertionPointColor = NSColor.controlAccentColor
    textView.backgroundColor = NSColor.textBackgroundColor
    textView.drawsBackground = true
    textView.typingAttributes = MarkdownTextViewSyntaxHighlighter.defaultAttributes
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
    textView.textContainer?.widthTracksTextView = true

    scrollView.documentView = textView
    context.coordinator.observeScrolling(in: scrollView)
    context.coordinator.scheduleFullStatistics(for: text)
    context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    textView.isEditable = true
    textView.isSelectable = true
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.fileDropTargetChangedHandler = onFileDropTargetChanged
      droppableTextView.smartPasteHandler = { textView, pasteboard in
        context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
      }
      droppableTextView.markdownFormattingHandler = { textView, command in
        context.coordinator.handleFormatting(command, in: textView)
      }
    }

    if textView.string != text {
      let currentRange = textView.selectedRange()
      textView.string = text
      (nsView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      textView.setSelectedRange(clamped(currentRange, length: (text as NSString).length))
      context.coordinator.invalidateHighlightedTextCache()
      context.coordinator.scheduleFullStatistics(for: text)
      context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    }

    let range = clamped(selectedRange, length: (textView.string as NSString).length)
    if textView.selectedRange() != range {
      textView.setSelectedRange(range)
      textView.scrollRangeToVisible(range)
    }

    textView.typingAttributes = MarkdownTextViewSyntaxHighlighter.defaultAttributes
    if let handledRequestID = context.coordinator.handle(editRequest, in: textView) {
      DispatchQueue.main.async {
        onEditRequestHandled(handledRequestID)
      }
    }
    context.coordinator.applySynchronizedScroll(scrollSyncUpdate, in: nsView)
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    Self.clamped(range, length: length)
  }

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    let onStatisticsChanged: (MarkdownEditorStatistics) -> Void
    let onPasteMessage: (String) -> Void
    let onScrollProgressChanged: (Double) -> Void
    let onDroppedFiles: ([URL]) -> Void
    private weak var textView: NSTextView?
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var highlightedTextCache: String?
    private let syntaxHighlightDelay: TimeInterval = 0.12
    private var statisticsTask: Task<Void, Never>?
    private var statisticsGeneration = 0
    private var statisticsText: String?
    private var statistics = MarkdownEditorStatistics.empty
    private var pendingTextEdit: MarkdownTextEdit?
    private var lastAppliedEditRequestID: UUID?
    private let scrollSyncBridge: MarkdownScrollViewSyncBridge
    private let smartEditingService = MarkdownSmartEditingService()
    private let smartPasteService = MarkdownSmartPasteService()
    private let formattingService = MarkdownFormattingService()
    private let pastedImageFileStore = PastedImageFileStore()
    private let statisticsDelay: TimeInterval = 0.18

    init(
      text: Binding<String>,
      selectedRange: Binding<NSRange>,
      onStatisticsChanged: @escaping (MarkdownEditorStatistics) -> Void,
      onPasteMessage: @escaping (String) -> Void,
      onScrollProgressChanged: @escaping (Double) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void
    ) {
      _text = text
      _selectedRange = selectedRange
      self.onStatisticsChanged = onStatisticsChanged
      self.onPasteMessage = onPasteMessage
      self.onScrollProgressChanged = onScrollProgressChanged
      self.onDroppedFiles = onDroppedFiles
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .editor,
        onProgressChanged: onScrollProgressChanged
      )
    }

    deinit {
      highlightTask?.cancel()
      statisticsTask?.cancel()
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
      let imageURLs = MarkdownPasteboardReader.imageFileURLs(from: pasteboard)
      if !imageURLs.isEmpty {
        selectedRange = textView.selectedRange()
        onDroppedFiles(imageURLs)
        return true
      }

      if let pngData = MarkdownPasteboardReader.pngData(from: pasteboard) {
        do {
          let imageURL = try pastedImageFileStore.storePNG(pngData)
          selectedRange = textView.selectedRange()
          onDroppedFiles([imageURL])
        } catch {
          onPasteMessage("粘贴图片失败：\(error.localizedDescription)")
          NSSound.beep()
        }
        return true
      }

      guard let pastedText = pasteboard.string(forType: .string),
            let edit = smartPasteService.linkEdit(
              in: textView.string,
              selectedRange: textView.selectedRange(),
              pastedText: pastedText
            ) else {
        return false
      }

      apply(edit, in: textView)
      return true
    }

    func handleFormatting(
      _ command: MarkdownFormattingCommand,
      in textView: NSTextView
    ) -> Bool {
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

    private func apply(_ edit: MarkdownSmartEdit, in textView: NSTextView) {
      if edit.changesText {
        textView.insertText(edit.replacement, replacementRange: edit.replacedRange)
      }
      textView.setSelectedRange(edit.selectedRange)
      selectedRange = edit.selectedRange
    }

    @discardableResult
    func handle(_ request: MarkdownTextEditRequest?, in textView: NSTextView) -> UUID? {
      guard let request,
            request.id != lastAppliedEditRequestID else {
        return nil
      }

      lastAppliedEditRequestID = request.id
      guard textView.string == request.expectedText else {
        return request.id
      }

      let textLength = (textView.string as NSString).length
      guard request.edit.replacedRange.location >= 0,
            NSMaxRange(request.edit.replacedRange) <= textLength else {
        return request.id
      }

      apply(request.edit, in: textView)
      return request.id
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

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      let updatedText = textView.string
      updateStatistics(afterEditing: updatedText)
      text = updatedText
      selectedRange = textView.selectedRange()
      scheduleMarkdownSyntaxHighlighting(for: textView, text: updatedText)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      selectedRange = textView.selectedRange()
    }

    func textView(
      _ textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      let edit: MarkdownSmartEdit?
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        edit = smartEditingService.newlineEdit(
          in: textView.string,
          selectedRange: textView.selectedRange()
        )
      case #selector(NSResponder.insertTab(_:)):
        edit = smartEditingService.indentationEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          direction: .indent
        )
      case #selector(NSResponder.insertBacktab(_:)):
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
      highlightTask?.cancel()
      highlightTask = nil
      highlightGeneration += 1
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

    func scheduleMarkdownSyntaxHighlighting(for textView: NSTextView, text: String) {
      guard highlightedTextCache != text else { return }

      self.textView = textView
      highlightTask?.cancel()
      highlightGeneration += 1
      let generation = highlightGeneration
      let previousText = highlightedTextCache
      let delay = syntaxHighlightDelay
      highlightTask = Task.detached(priority: .userInitiated) { [weak self, text] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        let plan = MarkdownSyntaxHighlightPlan(previousText: previousText, currentText: text)
        await self?.applyMarkdownSyntaxHighlighting(
          text: text,
          range: plan.range,
          generation: generation
        )
      }
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
      range: NSRange,
      generation: Int
    ) {
      guard highlightGeneration == generation else { return }
      guard highlightedTextCache != text else { return }
      guard let textView else { return }
      guard textView.string == text else { return }
      guard let highlighted = MarkdownTextViewSyntaxHighlighter.highlightedString(for: text, range: range) else {
        return
      }

      let selectedRange = textView.selectedRange()
      guard let textStorage = textView.textStorage else { return }
      textStorage.beginEditing()
      textStorage.setAttributes(MarkdownTextViewSyntaxHighlighter.defaultAttributes, range: range)
      highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) { attributes, localRange, _ in
        textStorage.addAttributes(
          attributes,
          range: NSRange(location: range.location + localRange.location, length: localRange.length)
        )
      }
      textStorage.endEditing()
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      textView.setSelectedRange(Self.clamped(selectedRange, length: (text as NSString).length))
      textView.typingAttributes = MarkdownTextViewSyntaxHighlighter.defaultAttributes
      highlightedTextCache = text
      highlightTask = nil
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

  override var acceptsFirstResponder: Bool { false }

  func invalidateDocumentHeight() {
    cachedTextHeight = nil
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let textView = documentView as? NSTextView else { return }

    let contentHeight = contentSize.height
    let contentWidth = max(contentSize.width, 1)
    let widthChanged = abs(cachedLayoutWidth - contentWidth) > 0.5
    if widthChanged {
      textView.textContainer?.containerSize = NSSize(
        width: contentWidth,
        height: CGFloat.greatestFiniteMagnitude
      )
      cachedTextHeight = nil
      cachedLayoutWidth = contentWidth
    }
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

  override func paste(_ sender: Any?) {
    guard smartPasteHandler?(self, .general) == true else {
      super.paste(sender)
      return
    }
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
}

struct MarkdownEditorStatistics: Equatable, Sendable {
  let characterCount: Int
  let wordCount: Int
  let lineCount: Int
  private let lineBreakCount: Int
  private let nonWhitespaceCharacterCount: Int

  static let empty = MarkdownEditorStatistics(
    characterCount: 0,
    wordCount: 0,
    lineCount: 0,
    lineBreakCount: 0,
    nonWhitespaceCharacterCount: 0
  )

  var readingMinutes: Int {
    guard wordCount > 0 else { return 0 }
    return Int(ceil(Double(wordCount) / 250.0))
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
    return MarkdownEditorStatistics(
      characterCount: characterCount,
      wordCount: wordCount(in: text),
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
    let updatedWordCount = max(
      0,
      wordCount - Self.wordCount(in: previous.substring(with: previousWordRange))
        + Self.wordCount(in: updated.substring(with: updatedWordRange))
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
      wordCount: updatedWordCount,
      lineCount: updatedNonWhitespaceCount == 0 ? 0 : updatedLineBreakCount + 1,
      lineBreakCount: updatedLineBreakCount,
      nonWhitespaceCharacterCount: updatedNonWhitespaceCount
    )
  }

  private static let wordSeparators = CharacterSet.whitespacesAndNewlines
    .union(.punctuationCharacters)
    .union(.symbols)

  private static func wordCount(in text: String) -> Int {
    text.components(separatedBy: wordSeparators).filter { !$0.isEmpty }.count
  }

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

private struct MarkdownSyntaxHighlightPlan {
  let range: NSRange

  init(previousText: String?, currentText: String) {
    let current = currentText as NSString
    guard let previousText else {
      range = NSRange(location: 0, length: current.length)
      return
    }

    let previous = previousText as NSString
    let change = Self.changedRanges(previous: previous, current: current)
    guard !Self.touchesCodeFence(change.previousRange, in: previous)
            && !Self.touchesCodeFence(change.currentRange, in: current) else {
      range = NSRange(location: 0, length: current.length)
      return
    }

    var expanded = current.lineRange(for: change.currentRange)
    for codeBlockRange in Self.codeBlockRanges(in: current) {
      if NSIntersectionRange(expanded, codeBlockRange).length > 0 {
        expanded = NSUnionRange(expanded, codeBlockRange)
      }
    }
    range = expanded
  }

  private static func changedRanges(previous: NSString, current: NSString) -> (previousRange: NSRange, currentRange: NSRange) {
    let sharedLength = min(previous.length, current.length)
    var prefix = 0
    while prefix < sharedLength, previous.character(at: prefix) == current.character(at: prefix) {
      prefix += 1
    }

    var suffix = 0
    while suffix < sharedLength - prefix,
          previous.character(at: previous.length - suffix - 1) == current.character(at: current.length - suffix - 1) {
      suffix += 1
    }
    return (
      NSRange(location: prefix, length: previous.length - prefix - suffix),
      NSRange(location: prefix, length: current.length - prefix - suffix)
    )
  }

  private static func touchesCodeFence(_ range: NSRange, in text: NSString) -> Bool {
    guard range.location <= text.length, NSMaxRange(range) <= text.length else { return true }
    let lineRange = text.lineRange(for: range)
    return text.substring(with: lineRange).contains("```")
  }

  private static func codeBlockRanges(in text: NSString) -> [NSRange] {
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: text.length)

    while searchRange.length > 0 {
      let openingRange = text.range(of: "```", options: [], range: searchRange)
      guard openingRange.location != NSNotFound else { break }
      let contentStart = NSMaxRange(openingRange)
      let remainingRange = NSRange(location: contentStart, length: text.length - contentStart)
      let closingRange = text.range(of: "```", options: [], range: remainingRange)
      guard closingRange.location != NSNotFound else {
        ranges.append(NSRange(location: openingRange.location, length: text.length - openingRange.location))
        break
      }
      let rangeEnd = NSMaxRange(closingRange)
      ranges.append(NSRange(location: openingRange.location, length: rangeEnd - openingRange.location))
      searchRange = NSRange(location: rangeEnd, length: text.length - rangeEnd)
    }

    return ranges
  }
}

@MainActor
private enum MarkdownTextViewSyntaxHighlighter {
  static let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
  static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .medium)
  static let defaultAttributes: [NSAttributedString.Key: Any] = {
    var paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 18
    return [
      .font: baseFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
  }()

  private static let headingRegex = compilePattern("^(#{1,6})\\s+.*$", options: .anchorsMatchLines)
  private static let boldRegex = compilePattern("\\*\\*[^\\n\\*]+\\*\\*")
  private static let italicRegex = compilePattern("(?<!\\*)\\*(?!\\*)([^\\n\\*]+?)\\*(?!\\*)")
  private static let inlineCodeRegex = compilePattern("`[^`\\n]+`")
  private static let listRegex = compilePattern("^\\s*(?:[-*+]|\\d+\\.)\\s+.*$", options: .anchorsMatchLines)
  private static let quoteRegex = compilePattern("^> .*+$", options: .anchorsMatchLines)
  private static let linkRegex = compilePattern(#"\[[^\]]+\]\([^)]+\)"#)
  private static let codeBlockRegex = compilePattern("```[\\s\\S]*?```")

  static func highlightedString(for value: String, range: NSRange? = nil) -> NSAttributedString? {
    let fullRange = NSRange(location: 0, length: (value as NSString).length)
    let requestedRange = range ?? fullRange
    guard requestedRange.location >= 0, NSMaxRange(requestedRange) <= fullRange.length else {
      return nil
    }
    let substring = (value as NSString).substring(with: requestedRange)
    return highlightedSubstring(substring)
  }

  static func codeBlockRanges(in value: String) -> [NSRange] {
    ranges(for: codeBlockRegex, in: value)
  }

  private static func highlightedSubstring(_ value: String) -> NSAttributedString? {
    let attributed = NSMutableAttributedString(string: value)
    attributed.setAttributes(defaultAttributes, range: NSRange(location: 0, length: attributed.length))
    let codeBlockRanges = ranges(for: codeBlockRegex, in: attributed.string)

    apply(
      headingRegex,
      to: attributed,
      attributes: [
        .foregroundColor: WorkbenchThemeNSColor.primary,
        .font: NSFont.boldSystemFont(ofSize: 14)
      ],
      excluding: codeBlockRanges
    )

    apply(
      codeBlockRegex,
      to: attributed,
      attributes: [
        .font: codeFont,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.18)
      ]
    )

    apply(
      linkRegex,
      to: attributed,
      attributes: [
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.linkColor
      ],
      excluding: codeBlockRanges
    )

    apply(
      listRegex,
      to: attributed,
      attributes: [
        .foregroundColor: WorkbenchThemeNSColor.success
      ],
      excluding: codeBlockRanges
    )

    apply(
      quoteRegex,
      to: attributed,
      attributes: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.08)
      ],
      excluding: codeBlockRanges
    )

    apply(
      boldRegex,
      to: attributed,
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: 14)
      ],
      excluding: codeBlockRanges
    )

    apply(
      italicRegex,
      to: attributed,
      attributes: [
        .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
      ],
      excluding: codeBlockRanges
    )

    apply(
      inlineCodeRegex,
      to: attributed,
      attributes: [
        .font: codeFont,
        .foregroundColor: WorkbenchThemeNSColor.warning
      ],
      excluding: codeBlockRanges
    )

    return attributed
  }

  private static func ranges(for regex: NSRegularExpression?, in text: String) -> [NSRange] {
    guard let regex else { return [] }
    var result: [NSRange] = []
    regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
      guard let match else { return }
      result.append(match.range)
    }
    return result
  }

  private static func apply(
    _ regex: NSRegularExpression?,
    to attributed: NSMutableAttributedString,
    attributes: [NSAttributedString.Key: Any],
    excluding excludedRanges: [NSRange] = []
  ) {
    guard let regex else { return }
    regex.enumerateMatches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length)) { match, _, _ in
      guard let match else { return }
      let overlap = excludedRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
      guard !overlap else { return }
      attributed.addAttributes(attributes, range: match.range)
    }
  }

  private static func compilePattern(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: options)
  }
}
