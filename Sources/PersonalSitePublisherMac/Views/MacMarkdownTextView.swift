import AppKit
import SwiftUI

struct MacMarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var selectedRange: NSRange
  var onDroppedFiles: ([URL]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, selectedRange: $selectedRange, onDroppedFiles: onDroppedFiles)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MarkdownEditorScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = NSColor.textBackgroundColor

    let textView = DroppableMarkdownTextView(frame: .zero, textContainer: nil)
    textView.delegate = context.coordinator
    textView.fileDropHandler = { urls, dropRange in
      context.coordinator.selectedRange = dropRange
      context.coordinator.onDroppedFiles(urls)
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
    context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    textView.isEditable = true
    textView.isSelectable = true

    if textView.string != text {
      let currentRange = textView.selectedRange()
      textView.string = text
      textView.setSelectedRange(clamped(currentRange, length: (text as NSString).length))
      context.coordinator.invalidateHighlightedTextCache()
      context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    }

    let range = clamped(selectedRange, length: (textView.string as NSString).length)
    if textView.selectedRange() != range {
      textView.setSelectedRange(range)
      textView.scrollRangeToVisible(range)
    }

    textView.typingAttributes = MarkdownTextViewSyntaxHighlighter.defaultAttributes
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    Self.clamped(range, length: length)
  }

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    let onDroppedFiles: ([URL]) -> Void
    private var highlightWorkItem: DispatchWorkItem?
    private var highlightGeneration = 0
    private var highlightedTextCache: String?
    private let syntaxHighlightDelay: TimeInterval = 0.12

    init(
      text: Binding<String>,
      selectedRange: Binding<NSRange>,
      onDroppedFiles: @escaping ([URL]) -> Void
    ) {
      _text = text
      _selectedRange = selectedRange
      self.onDroppedFiles = onDroppedFiles
    }

    deinit {
      highlightWorkItem?.cancel()
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
      selectedRange = textView.selectedRange()
      scheduleMarkdownSyntaxHighlighting(for: textView, text: textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      selectedRange = textView.selectedRange()
    }

    func invalidateHighlightedTextCache() {
      highlightedTextCache = nil
      highlightWorkItem?.cancel()
      highlightWorkItem = nil
      highlightGeneration += 1
    }

    func scheduleMarkdownSyntaxHighlighting(for textView: NSTextView, text: String) {
      guard highlightedTextCache != text else { return }

      highlightWorkItem?.cancel()
      highlightGeneration += 1
      let generation = highlightGeneration
      let workItem = DispatchWorkItem { [weak self, weak textView] in
        // Regex matching and attributed-string construction are intentionally
        // off the main thread. Only the final text-storage replacement needs
        // AppKit's main-thread affinity.
        guard let highlighted = MarkdownTextViewSyntaxHighlighter.highlightedString(for: text) else {
          return
        }
        DispatchQueue.main.async { [weak self, weak textView] in
          guard let self, let textView else { return }
          guard self.highlightGeneration == generation else { return }
          guard textView.string == text else { return }
          self.applyMarkdownSyntaxHighlighting(to: textView, text: text, highlighted: highlighted)
        }
      }
      highlightWorkItem = workItem
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + syntaxHighlightDelay,
        execute: workItem
      )
    }

    func applyMarkdownSyntaxHighlighting(
      to textView: NSTextView,
      text: String,
      highlighted: NSAttributedString
    ) {
      guard highlightedTextCache != text else { return }
      guard textView.string == text else { return }

      let selectedRange = textView.selectedRange()
      textView.textStorage?.setAttributedString(highlighted)
      textView.setSelectedRange(Self.clamped(selectedRange, length: (text as NSString).length))
      textView.typingAttributes = MarkdownTextViewSyntaxHighlighter.defaultAttributes
      highlightedTextCache = text
      if highlightWorkItem?.isCancelled == false {
        highlightWorkItem = nil
      }
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
      MacMarkdownTextView.clamped(range, length: length)
    }
  }
}

private final class MarkdownEditorScrollView: NSScrollView {
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    if let documentView {
      window?.makeFirstResponder(documentView)
    }
    super.mouseDown(with: event)
  }

  override func layout() {
    super.layout()
    guard let textView = documentView as? NSTextView else { return }

    let contentHeight = contentSize.height
    let textHeight = textView.layoutManager.map { layoutManager in
      guard let textContainer = textView.textContainer else { return contentHeight }
      layoutManager.ensureLayout(for: textContainer)
      return layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
    } ?? contentHeight

    textView.frame.size = NSSize(
      width: max(contentSize.width, 1),
      height: max(contentHeight, textHeight, 1)
    )
    textView.textContainer?.containerSize = NSSize(
      width: max(contentSize.width, 1),
      height: CGFloat.greatestFiniteMagnitude
    )
  }
}

private final class DroppableMarkdownTextView: NSTextView {
  var fileDropHandler: (([URL], NSRange) -> Void)?

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(from: sender.draggingPasteboard)
    guard !urls.isEmpty else { return false }
    let dropRange = insertionRange(for: sender)
    setSelectedRange(dropRange)
    fileDropHandler?(urls, dropRange)
    return true
  }

  private func insertionRange(for sender: NSDraggingInfo) -> NSRange {
    let location = convert(sender.draggingLocation, from: nil)
    let insertionIndex = characterIndexForInsertion(at: location)
    let maxLength = (string as NSString).length
    return NSRange(location: min(max(insertionIndex, 0), maxLength), length: 0)
  }

  private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
      .compactMap { ($0 as? URL)?.standardizedFileURL }
      ?? []
  }
}

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

  static func highlightedString(for value: String) -> NSAttributedString? {
    let attributed = NSMutableAttributedString(string: value)
    attributed.setAttributes(defaultAttributes, range: NSRange(location: 0, length: attributed.length))
    let codeBlockRanges = ranges(for: codeBlockRegex, in: attributed.string)

    apply(
      headingRegex,
      to: attributed,
      attributes: [
        .foregroundColor: NSColor.systemPurple,
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
        .foregroundColor: NSColor.systemGreen
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
        .foregroundColor: NSColor.systemOrange
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
