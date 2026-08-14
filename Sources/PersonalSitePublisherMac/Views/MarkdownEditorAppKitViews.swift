import AppKit
import PublishingWorkbenchCore

final class MarkdownEditorScrollView: NSScrollView {
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
    let textContainerInset = NSSize(width: horizontalInset, height: 16)
    if textView.textContainerInset != textContainerInset {
      textView.textContainerInset = textContainerInset
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

    let documentSize = NSSize(
      width: contentWidth,
      height: max(contentHeight, textHeight, 1)
    )
    if textView.frame.size != documentSize {
      textView.setFrameSize(documentSize)
    }
  }
}
final class DroppableMarkdownTextView: NSTextView {
  var fileDropTargetChangedHandler: ((Bool) -> Void)?
  var fileDropHandler: (([URL], NSRange) -> Void)?
  var knowledgeMarkdownDropHandler: ((String, NSRange, KnowledgeCitation?) -> Void)?
  var smartPasteHandler: ((NSTextView, any MarkdownPasteboardSource) -> Bool)?
  var pasteboardProvider: () -> any MarkdownPasteboardSource = { NSPasteboard.general }
  var fileDropImageURLsProvider: (NSPasteboard) -> [URL] = {
    MarkdownPasteboardReader.imageFileURLs(from: $0)
  }
  var knowledgeMarkdownProvider: (NSPasteboard) -> String? = { pasteboard in
    guard let data = pasteboard.data(
      forType: KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType
    ) else {
      return nil
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).nilIfEmpty
  }
  var knowledgeCitationProvider: (NSPasteboard) -> KnowledgeCitation? = {
    KnowledgeArticleInsertionService.citation(from: $0)
  }
  var markdownFormattingHandler: ((NSTextView, MarkdownFormattingCommand) -> Bool)?
  var markdownLineEditingHandler: ((NSTextView, MarkdownLineEditingCommand) -> Bool)?
  var markdownTableContextProvider: ((NSTextView) -> MarkdownTableEditingContext?)?
  var markdownTableEditingHandler: ((NSTextView, MarkdownTableEditingCommand) -> Bool)?
  var slashCommandKeyHandler: ((MarkdownSlashCommandKey) -> Bool)?
  var typingFeedbackHandler: (() -> Void)?
  var ghostTextAcceptHandler: (() -> Bool)?
  var ghostTextDismissHandler: (() -> Bool)?
  private var isFileDropTargeted = false

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    registerForDraggedTypes([
      .fileURL,
      KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType,
      KnowledgeArticleInsertionService.knowledgeCitationPasteboardType
    ])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([
      .fileURL,
      KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType,
      KnowledgeArticleInsertionService.knowledgeCitationPasteboardType
    ])
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
    if let slashCommandKey = MarkdownSlashCommandKey.from(
      keyCode: event.keyCode,
      modifiers: event.modifierFlags
    ), slashCommandKeyHandler?(slashCommandKey) == true {
      return
    }

    // Keyboard line operations: Move, Duplicate, Delete, Comment
    if event.keyCode == 126 { // Up arrow
      if modifiers == .option {
        if markdownLineEditingHandler?(self, .moveUp) == true { return }
      } else if modifiers == [.shift, .option] {
        if markdownLineEditingHandler?(self, .duplicateAbove) == true { return }
      }
    } else if event.keyCode == 125 { // Down arrow
      if modifiers == .option {
        if markdownLineEditingHandler?(self, .moveDown) == true { return }
      } else if modifiers == [.shift, .option] {
        if markdownLineEditingHandler?(self, .duplicateBelow) == true { return }
      }
    } else if event.keyCode == 40 { // 'K' key
      if modifiers == [.command, .shift] {
        if markdownLineEditingHandler?(self, .deleteLine) == true { return }
      }
    } else if event.keyCode == 44 || event.characters == "/" { // '/' key
      if modifiers == .command {
        if markdownLineEditingHandler?(self, .toggleComment) == true { return }
      }
    }

    if event.keyCode == 48 { // Tab key
      if modifiers.isEmpty, ghostTextAcceptHandler?() == true {
        return
      }
      if modifiers.contains(.control) {
        if modifiers.contains(.shift) {
          window?.selectPreviousKeyView(self)
        } else {
          window?.selectNextKeyView(self)
        }
        return
      }
    } else if event.keyCode == 53 { // Esc key
      if modifiers.isEmpty, ghostTextDismissHandler?() == true {
        return
      }
    }

    let typingEvent = MarkdownTypingFeedbackPolicy.event(
      keyCode: event.keyCode,
      characters: event.characters,
      modifiers: event.modifierFlags
    )
    if typingEvent == .insertedText {
      typingFeedbackHandler?()
    }
    super.keyDown(with: event)
  }

  override func paste(_ sender: Any?) {
    guard smartPasteHandler?(self, pasteboardProvider()) == true else {
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
      || knowledgeMarkdown(from: sender.draggingPasteboard) != nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { setFileDropTargeted(false) }
    let urls = imageFileURLs(from: sender.draggingPasteboard)
    if !urls.isEmpty {
      let dropRange = insertionRange(for: sender)
      setSelectedRange(dropRange)
      fileDropHandler?(urls, dropRange)
      return true
    }

    guard let markdown = knowledgeMarkdown(from: sender.draggingPasteboard) else {
      return false
    }
    let dropRange = insertionRange(for: sender)
    setSelectedRange(dropRange)
    knowledgeMarkdownDropHandler?(
      markdown,
      dropRange,
      knowledgeCitationProvider(sender.draggingPasteboard)
    )
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
    let acceptsKnowledgeMarkdown = knowledgeMarkdown(from: sender.draggingPasteboard) != nil
    let acceptsDrop = acceptsImages || acceptsKnowledgeMarkdown
    setFileDropTargeted(acceptsDrop)
    return acceptsDrop ? .copy : []
  }

  private func setFileDropTargeted(_ isTargeted: Bool) {
    guard isFileDropTargeted != isTargeted else { return }
    isFileDropTargeted = isTargeted
    fileDropTargetChangedHandler?(isTargeted)
  }

  private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    fileDropImageURLsProvider(pasteboard)
  }

  private func knowledgeMarkdown(from pasteboard: NSPasteboard) -> String? {
    knowledgeMarkdownProvider(pasteboard)
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
