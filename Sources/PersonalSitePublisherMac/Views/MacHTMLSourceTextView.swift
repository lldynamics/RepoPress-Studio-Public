import AppKit
import SwiftUI

struct HTMLSourceFindRequest: Equatable {
  enum Action {
    case show
    case next
    case previous
  }

  var id = UUID()
  var action: Action
}

/// A narrow AppKit bridge for editing repository HTML and template source.
///
/// SwiftUI owns the source text and find-request identity. AppKit owns the
/// native text system, undo manager, find bar, syntax colors, and line ruler.
struct MacHTMLSourceTextView: NSViewRepresentable {
  @Binding var text: String
  var isEditable = true
  var findRequest: HTMLSourceFindRequest? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.contentView.postsBoundsChangedNotifications = true

    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    let textContainer = NSTextContainer(
      containerSize: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false
    textContainer.lineFragmentPadding = 0
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)

    let textView = NSTextView(frame: .zero, textContainer: textContainer)
    configure(textView)
    textView.delegate = context.coordinator
    textView.string = text
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    scrollView.documentView = textView

    let lineNumberRuler = MacHTMLSourceLineNumberRulerView(
      scrollView: scrollView,
      textView: textView
    )
    scrollView.verticalRulerView = lineNumberRuler
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    context.coordinator.lineNumberRuler = lineNumberRuler

    MacHTMLSourceSyntaxHighlighter.apply(to: textView)
    context.coordinator.handleFindRequest(findRequest, in: textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.text = $text
    configure(textView)

    if textView.string != text {
      let selectedRange = clamped(
        textView.selectedRange(),
        length: (text as NSString).length
      )
      context.coordinator.isApplyingExternalText = true
      textView.string = text
      textView.setSelectedRange(selectedRange)
      context.coordinator.isApplyingExternalText = false
      context.coordinator.refreshPresentation(in: textView)
    }

    context.coordinator.handleFindRequest(findRequest, in: textView)
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    (scrollView.documentView as? NSTextView)?.delegate = nil
    coordinator.cancelPendingFindRequest()
    coordinator.cancelPendingPresentationRefresh()
  }

  private func configure(_ textView: NSTextView) {
    let sourceFont = NSFont.monospacedSystemFont(
      ofSize: 15,
      weight: .regular
    )
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.font = sourceFont
    textView.textColor = .labelColor
    textView.insertionPointColor = .controlAccentColor
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = [.width]
    textView.typingAttributes = [
      .font: sourceFont,
      .foregroundColor: NSColor.labelColor,
    ]
    textView.setAccessibilityLabel(String(localized: "HTML 源码编辑器"))
    textView.setAccessibilityIdentifier("html-source-editor")
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    return NSRange(
      location: location,
      length: min(max(range.length, 0), length - location)
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var isApplyingExternalText = false
    fileprivate weak var lineNumberRuler: MacHTMLSourceLineNumberRulerView?
    private var lastHandledFindRequest: UUID?
    private var pendingFindTask: Task<Void, Never>?
    private var pendingPresentationTask: Task<Void, Never>?
    private var pendingEditedRange: NSRange?
    private var presentationGeneration = 0

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingExternalText,
            let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
      let editedRange = pendingEditedRange ?? NSRange(
        location: textView.selectedRange().location,
        length: 1
      )
      pendingEditedRange = nil
      schedulePresentationRefresh(in: textView, editedRange: editedRange)
    }

    func refreshPresentation(in textView: NSTextView) {
      MacHTMLSourceSyntaxHighlighter.apply(to: textView)
      lineNumberRuler?.rebuildLineStarts()
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      let replacementLength = ((replacementString ?? "") as NSString).length
      let changedRange = NSRange(
        location: affectedCharRange.location,
        length: max(1, replacementLength)
      )
      pendingEditedRange = pendingEditedRange.map {
        NSUnionRange($0, changedRange)
      } ?? changedRange
      return true
    }

    func handleFindRequest(_ request: HTMLSourceFindRequest?, in textView: NSTextView) {
      guard let request, request.id != lastHandledFindRequest else { return }
      lastHandledFindRequest = request.id
      pendingFindTask?.cancel()
      pendingFindTask = Task { @MainActor [weak textView] in
        await Task.yield()
        guard !Task.isCancelled, let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        switch request.action {
        case .show:
          sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        case .next:
          sender.tag = NSTextFinder.Action.nextMatch.rawValue
        case .previous:
          sender.tag = NSTextFinder.Action.previousMatch.rawValue
        }
        textView.performFindPanelAction(sender)
      }
    }

    func cancelPendingFindRequest() {
      pendingFindTask?.cancel()
      pendingFindTask = nil
    }

    func cancelPendingPresentationRefresh() {
      presentationGeneration += 1
      pendingPresentationTask?.cancel()
      pendingPresentationTask = nil
    }

    private func schedulePresentationRefresh(in textView: NSTextView, editedRange: NSRange) {
      pendingPresentationTask?.cancel()
      presentationGeneration += 1
      let generation = presentationGeneration
      pendingPresentationTask = Task { @MainActor [weak self, weak textView] in
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, let self, let textView else { return }
        MacHTMLSourceSyntaxHighlighter.apply(to: textView, around: editedRange)
        let source = textView.string
        let lineStarts = await Task.detached(priority: .utility) {
          MacHTMLSourceLineNumberRulerView.lineStarts(for: source)
        }.value
        guard !Task.isCancelled, self.presentationGeneration == generation else { return }
        self.lineNumberRuler?.applyLineStarts(lineStarts)
      }
    }
  }
}

@MainActor
private enum MacHTMLSourceSyntaxHighlighter {
  private static let maximumLiveHighlightLength = 1_000_000
  private static let tagExpression = try? NSRegularExpression(
    pattern: #"</?([A-Za-z][A-Za-z0-9:-]*)(?:\s+(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*)?\s*/?>"#
  )
  private static let attributeExpression = try? NSRegularExpression(
    pattern: #"\s+([A-Za-z_:][A-Za-z0-9_:.\-]*)(?:\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s>]+))?"#
  )
  private static let commentExpression = try? NSRegularExpression(
    pattern: #"<!--[\s\S]*?-->"#
  )
  private static let declarationExpression = try? NSRegularExpression(
    pattern: #"<!DOCTYPE\b[^>]*>|<\?[\s\S]*?\?>"#,
    options: [.caseInsensitive]
  )
  private static let entityExpression = try? NSRegularExpression(
    pattern: #"&(?:#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#
  )
  private static let templateExpression = try? NSRegularExpression(
    pattern: #"\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}|<%[\s\S]*?%>"#
  )

  static func apply(to textView: NSTextView, around editedRange: NSRange? = nil) {
    guard let layoutManager = textView.layoutManager else { return }
    let source = textView.string as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    let highlightRange = editedRange.map {
      expandedHighlightRange(around: $0, source: source)
    } ?? fullRange
    layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlightRange)
    guard source.length > 0, source.length <= maximumLiveHighlightLength else { return }

    if let tagExpression {
      for match in tagExpression.matches(in: source as String, range: highlightRange) {
        addColor(.systemBlue, range: match.range, layoutManager: layoutManager)
        addColor(.systemPurple, range: match.range(at: 1), layoutManager: layoutManager)

        if let attributeExpression {
          for attribute in attributeExpression.matches(
            in: source as String,
            range: match.range
          ) {
            addColor(
              .systemOrange,
              range: attribute.range(at: 1),
              layoutManager: layoutManager
            )
            addColor(
              .systemRed,
              range: attribute.range(at: 2),
              layoutManager: layoutManager
            )
          }
        }
      }
    }

    apply(
      declarationExpression,
      color: .systemBrown,
      source: source,
      range: highlightRange,
      layoutManager: layoutManager
    )
    apply(
      entityExpression,
      color: .systemTeal,
      source: source,
      range: highlightRange,
      layoutManager: layoutManager
    )
    apply(
      templateExpression,
      color: .systemIndigo,
      source: source,
      range: highlightRange,
      layoutManager: layoutManager
    )
    apply(
      commentExpression,
      color: .secondaryLabelColor,
      source: source,
      range: highlightRange,
      layoutManager: layoutManager
    )
  }

  private static func expandedHighlightRange(
    around range: NSRange,
    source: NSString
  ) -> NSRange {
    let safeLocation = min(max(range.location, 0), source.length)
    let safeEnd = min(max(NSMaxRange(range), safeLocation), source.length)
    let contextLength = 2_048
    let start = max(0, safeLocation - contextLength)
    let end = min(source.length, safeEnd + contextLength)
    return NSRange(location: start, length: end - start)
  }

  private static func apply(
    _ expression: NSRegularExpression?,
    color: NSColor,
    source: NSString,
    range: NSRange,
    layoutManager: NSLayoutManager
  ) {
    guard let expression else { return }
    for match in expression.matches(in: source as String, range: range) {
      addColor(color, range: match.range, layoutManager: layoutManager)
    }
  }

  private static func addColor(
    _ color: NSColor,
    range: NSRange,
    layoutManager: NSLayoutManager
  ) {
    guard range.location != NSNotFound, range.length > 0 else { return }
    layoutManager.addTemporaryAttribute(
      .foregroundColor,
      value: color,
      forCharacterRange: range
    )
  }
}

@MainActor
private final class MacHTMLSourceLineNumberRulerView: NSRulerView {
  private weak var textView: NSTextView?
  private var lineStarts = [0]
  private let numberFont = NSFont.monospacedDigitSystemFont(
    ofSize: 11,
    weight: .regular
  )

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    setAccessibilityElement(false)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(visibleBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    rebuildLineStarts()
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func rebuildLineStarts() {
    applyLineStarts(Self.lineStarts(for: textView?.string ?? ""))
  }

  func applyLineStarts(_ starts: [Int]) {
    lineStarts = starts
    updateRuleThickness()
    needsDisplay = true
  }

  nonisolated static func lineStarts(for string: String) -> [Int] {
    let source = string as NSString
    var starts = [0]
    var index = 0
    while index < source.length {
      let character = source.character(at: index)
      if character == 13 {
        if index + 1 < source.length, source.character(at: index + 1) == 10 {
          index += 1
        }
        starts.append(index + 1)
      } else if character == 10 {
        starts.append(index + 1)
      }
      index += 1
    }
    return starts
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()

    guard let textView,
          let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else { return }
    layoutManager.ensureLayout(for: textContainer)

    let visibleRange = visibleCharacterRange(
      textView: textView,
      layoutManager: layoutManager,
      textContainer: textContainer
    )
    let textLength = (textView.string as NSString).length
    let firstLine = lineIndex(containing: visibleRange.location)
    let lastLine = min(
      lineStarts.count - 1,
      lineIndex(containing: min(textLength, NSMaxRange(visibleRange))) + 1
    )
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: numberFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraphStyle,
    ]

    if firstLine <= lastLine {
      for lineIndex in firstLine ... lastLine {
        let characterLocation = lineStarts[lineIndex]
        let lineRect = lineFragmentRect(
          at: characterLocation,
          textLength: textLength,
          layoutManager: layoutManager,
          textContainer: textContainer
        )
        let textViewRect = NSRect(
          x: textView.textContainerOrigin.x,
          y: textView.textContainerOrigin.y + lineRect.minY,
          width: max(lineRect.width, 1),
          height: max(lineRect.height, numberFont.pointSize + 4)
        )
        let rulerRect = textView.convert(textViewRect, to: self)
        guard rulerRect.intersects(bounds.insetBy(dx: 0, dy: -20)) else { continue }
        let labelRect = NSRect(
          x: 4,
          y: rulerRect.minY + max(0, (rulerRect.height - numberFont.pointSize - 2) / 2),
          width: max(ruleThickness - 10, 1),
          height: numberFont.pointSize + 4
        )
        String(lineIndex + 1).draw(in: labelRect, withAttributes: attributes)
      }
    }

    NSColor.separatorColor.setFill()
    NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
  }

  @objc
  private func visibleBoundsDidChange(_ notification: Notification) {
    needsDisplay = true
  }

  private func updateRuleThickness() {
    let digitCount = max(2, String(lineStarts.count).count)
    let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
    let desiredThickness = ceil(CGFloat(digitCount) * digitWidth + 16)
    guard abs(ruleThickness - desiredThickness) > 0.5 else { return }
    ruleThickness = desiredThickness
    scrollView?.tile()
  }

  private func visibleCharacterRange(
    textView: NSTextView,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) -> NSRange {
    guard layoutManager.numberOfGlyphs > 0 else {
      return NSRange(location: 0, length: 0)
    }
    var visibleRect = textView.visibleRect
    visibleRect.origin.x -= textView.textContainerOrigin.x
    visibleRect.origin.y -= textView.textContainerOrigin.y
    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: visibleRect,
      in: textContainer
    )
    return layoutManager.characterRange(
      forGlyphRange: glyphRange,
      actualGlyphRange: nil
    )
  }

  private func lineIndex(containing characterLocation: Int) -> Int {
    var lowerBound = 0
    var upperBound = lineStarts.count
    while lowerBound < upperBound {
      let midpoint = (lowerBound + upperBound) / 2
      if lineStarts[midpoint] <= characterLocation {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    return max(0, lowerBound - 1)
  }

  private func lineFragmentRect(
    at characterLocation: Int,
    textLength: Int,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) -> NSRect {
    if characterLocation < textLength, layoutManager.numberOfGlyphs > 0 {
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterLocation)
      return layoutManager.lineFragmentRect(
        forGlyphAt: glyphIndex,
        effectiveRange: nil
      )
    }
    if !layoutManager.extraLineFragmentRect.isEmpty {
      return layoutManager.extraLineFragmentRect
    }
    return NSRect(
      x: 0,
      y: 0,
      width: max(textContainer.containerSize.width, 1),
      height: numberFont.pointSize + 6
    )
  }
}
